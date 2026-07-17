import HeadlessProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private final class ChromiumChildProcess {
    let processIdentifier: Int32
    private let lock = NSLock()
    private var reapedStatus: Int32?

    init(processIdentifier: Int32) {
        self.processIdentifier = processIdentifier
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        if reapedStatus != nil { return false }
        var status: Int32 = 0
        let result = waitpid(processIdentifier, &status, WNOHANG)
        if result == 0 { return true }
        if result == processIdentifier {
            reapedStatus = status
            return false
        }
        return errno != ECHILD && kill(processIdentifier, 0) == 0
    }

    func stop() {
        guard isRunning else { return }
        _ = kill(processIdentifier, SIGTERM)
        let deadline = Date().addingTimeInterval(3)
        while isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if isRunning {
            _ = kill(processIdentifier, SIGKILL)
            while isRunning { Thread.sleep(forTimeInterval: 0.01) }
        }
    }
}

private struct SpawnedChromium {
    let child: ChromiumChildProcess
    let inputDescriptor: Int32
    let outputDescriptor: Int32
}

/// Chromium's DevTools pipe is fixed to child fd 3 (commands) and fd 4
/// (responses). posix_spawn gives those descriptors to Chromium without ever
/// opening a network debugging endpoint.
private func spawnChromium(executable: URL, arguments: [String]) throws -> SpawnedChromium {
    var commandPipe = [Int32](repeating: -1, count: 2)
    var responsePipe = [Int32](repeating: -1, count: 2)
    guard commandPipe.withUnsafeMutableBufferPointer({ pipe($0.baseAddress!) }) == 0 else {
        throw CDPError.invalidResponse("command pipe creation failed")
    }
    guard responsePipe.withUnsafeMutableBufferPointer({ pipe($0.baseAddress!) }) == 0 else {
        commandPipe.forEach { _ = close($0) }
        throw CDPError.invalidResponse("response pipe creation failed")
    }

    var owned = commandPipe + responsePipe
    func closeOwned() {
        for descriptor in owned where descriptor >= 0 { _ = close(descriptor) }
        owned = []
    }

    do {
        // Keep source descriptors away from 0...4 so the dup/close file actions
        // cannot accidentally overwrite another pipe endpoint.
        for index in owned.indices {
            // Keep these temporary source descriptors inheritable. Some
            // posix_spawn implementations preserve FD_CLOEXEC through their
            // internal dup action, while Chromium explicitly rejects fd 3/4
            // when either is marked close-on-exec.
            let moved = fcntl(owned[index], F_DUPFD, 10)
            guard moved >= 0 else { throw CDPError.invalidResponse("pipe descriptor setup failed") }
            _ = close(owned[index])
            owned[index] = moved
        }
        let commandRead = owned[0]
        let commandWrite = owned[1]
        let responseRead = owned[2]
        let responseWrite = owned[3]

        let rawDevNull = open("/dev/null", O_RDWR | O_CLOEXEC)
        guard rawDevNull >= 0 else { throw CDPError.invalidResponse("could not open /dev/null") }
        let devNull = fcntl(rawDevNull, F_DUPFD, 10)
        _ = close(rawDevNull)
        guard devNull >= 0 else { throw CDPError.invalidResponse("could not configure /dev/null") }
        owned.append(devNull)

        let argumentStrings = [executable.path] + arguments
        let environmentStrings = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let keepErrorOutput = ProcessInfo.processInfo.environment["HEADLESS_DEBUG"] == "1"
        var argumentPointers: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { value in
            value.withCString { strdup($0) }
        } + [nil]
        var environmentPointers: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { value in
            value.withCString { strdup($0) }
        } + [nil]
        defer {
            argumentPointers.dropLast().forEach { free($0) }
            environmentPointers.dropLast().forEach { free($0) }
        }

        let pid: pid_t = argumentPointers.withUnsafeMutableBufferPointer { argv in
            environmentPointers.withUnsafeMutableBufferPointer { environment in
                let childPID = fork()
                if childPID == 0 {
                    // Only async-signal-safe POSIX calls occur between fork and
                    // exec. Startup happens before the host creates worker
                    // queues, and exec immediately replaces the child image.
                    guard dup2(commandRead, 3) >= 0,
                          dup2(responseWrite, 4) >= 0,
                          fcntl(3, F_SETFD, 0) >= 0,
                          fcntl(4, F_SETFD, 0) >= 0,
                          dup2(devNull, STDIN_FILENO) >= 0,
                          dup2(devNull, STDOUT_FILENO) >= 0 else {
                        _exit(126)
                    }
                    if !keepErrorOutput, dup2(devNull, STDERR_FILENO) < 0 { _exit(126) }
                    for descriptor in owned { _ = close(descriptor) }
                    execve(argv[0]!, argv.baseAddress!, environment.baseAddress!)
                    _exit(127)
                }
                return childPID
            }
        }
        guard pid > 0 else {
            throw CDPError.invalidResponse("Chromium launch failed: \(String(cString: strerror(errno)))")
        }

        _ = close(commandRead)
        _ = close(responseWrite)
        _ = close(devNull)
        owned = []
        return SpawnedChromium(
            child: ChromiumChildProcess(processIdentifier: pid),
            inputDescriptor: responseRead,
            outputDescriptor: commandWrite
        )
    } catch {
        closeOwned()
        throw error
    }
}

final class ChromiumProcess {
    private let child: ChromiumChildProcess
    let browserConnection: CDPConnection
    let headless: Bool
    var processIdentifier: Int32 { child.processIdentifier }
    private let profileURL: URL
    private let sessionsLock = NSLock()
    private var sessionsByProtocolID: [String: LinuxBrowserSession] = [:]

    init() throws {
        #if os(Linux)
        guard getuid() != 0 else { throw CDPError.rootNotSupported }
        #endif
        try LocalRuntime.preparePrivateDirectory()
        profileURL = LocalRuntime.directoryURL.appendingPathComponent("chromium-profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
        #if os(Linux)
        _ = chmod(profileURL.path, 0o700)
        #endif

        let executable = try ChromiumProcess.resolveExecutable()
        headless = ProcessInfo.processInfo.environment["HEADLESS_HEADLESS"] != "0"
            && ProcessInfo.processInfo.environment["DISPLAY"] == nil
        var arguments = [
            "--remote-debugging-pipe",
            "--user-data-dir=\(profileURL.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-default-apps",
            "--disable-sync",
            "--window-size=1160,760",
            "about:blank",
        ]
        if headless { arguments.insert("--headless=new", at: 0) }
        let spawned = try spawnChromium(executable: executable, arguments: arguments)
        child = spawned.child
        browserConnection = CDPConnection(
            inputDescriptor: spawned.inputDescriptor,
            outputDescriptor: spawned.outputDescriptor
        )
        // Evidence workflows should not silently write unreviewed page
        // downloads into the VM. Captures are written only by ArtifactStore.
        _ = try browserConnection.command("Browser.setDownloadBehavior", parameters: ["behavior": "deny"])
        browserConnection.setEventHandler { [weak self] event in self?.routeEvent(event) }
    }

    deinit { stop() }

    func createSession() throws -> LinuxBrowserSession {
        let response = try browserConnection.command("Target.createTarget", parameters: ["url": "about:blank"])
        guard let targetID = response["targetId"] as? String else {
            throw CDPError.invalidResponse("Target.createTarget did not return targetId")
        }
        let attached = try browserConnection.command("Target.attachToTarget", parameters: [
            "targetId": targetID,
            "flatten": true,
        ])
        guard let sessionID = attached["sessionId"] as? String else {
            throw CDPError.invalidResponse("Target.attachToTarget did not return sessionId")
        }
        let session = try LinuxBrowserSession(targetID: targetID, sessionID: sessionID, connection: browserConnection)
        sessionsLock.lock(); sessionsByProtocolID[sessionID] = session; sessionsLock.unlock()
        return session
    }

    func closeSession(_ session: LinuxBrowserSession) {
        sessionsLock.lock(); sessionsByProtocolID.removeValue(forKey: session.protocolSessionID); sessionsLock.unlock()
        _ = try? browserConnection.command("Target.closeTarget", parameters: ["targetId": session.targetID])
    }

    func stop() {
        browserConnection.close()
        child.stop()
    }

    private func routeEvent(_ event: [String: Any]) {
        let method = event["method"] as? String
        let sessionID = event["sessionId"] as? String
        sessionsLock.lock()
        let session = sessionID.flatMap { sessionsByProtocolID[$0] }
        let allSessions = Array(sessionsByProtocolID.values)
        sessionsLock.unlock()
        if let session {
            session.handleEvent(event)
        } else if method == "Fetch.requestPaused" {
            // Snap Chromium can emit a paused request from an internal target
            // session that is not reported by Target.attachToTarget. Each local
            // session attempts the continuation; only the owning CDP session
            // accepts it, while the others return a harmless ignored error.
            allSessions.forEach { $0.handleEvent(event) }
        }
    }

    private static func resolveExecutable() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        // Prefer the real Debian binary. Its /usr/bin/chromium shell wrapper is
        // useful for humans but may consume or rearrange the fd 3/4 contract
        // required by --remote-debugging-pipe.
        let candidates = [
            environment["HEADLESS_CHROMIUM_EXECUTABLE"],
            "/usr/lib/chromium/chromium",
            "/usr/bin/chromium",
            "/usr/bin/chromium-browser",
            "/usr/bin/google-chrome",
        ]
            .compactMap { $0 }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw CDPError.chromiumNotFound
    }
}

final class LinuxBrowserSession: @unchecked Sendable {
    private struct NetworkMock: Sendable {
        let url: String
        let status: Int
        let body: String
        let contentType: String
    }
    let targetID: String
    private let sessionID: String
    var protocolSessionID: String { sessionID }
    private let connection: CDPConnection
    let diagnostics = QADiagnosticStore()
    private let diagnosticsLock = NSLock()
    private var requestContexts: [String: (method: String?, url: String?, headers: [String: String])] = [:]
    private let recordingLock = NSLock()
    private var recordingPausedUntil = Date.distantPast
    private let navigationLock = NSLock()
    private var mainFrameID: String?
    private var lastSafeURL: String?
    private var navigationRecoveryPending = false
    private let mockLock = NSLock()
    private var networkMocks: [NetworkMock] = []

    init(targetID: String, sessionID: String, connection: CDPConnection) throws {
        self.targetID = targetID
        self.sessionID = sessionID
        self.connection = connection
        _ = try command("Page.enable")
        _ = try command("Runtime.enable")
        _ = try command("Log.enable")
        _ = try command("Network.enable", parameters: [
            "maxTotalBufferSize": 10_000_000,
            "maxResourceBufferSize": 1_000_000,
        ])
        let frameTree = try command("Page.getFrameTree")
        if let tree = frameTree["frameTree"] as? [String: Any],
           let frame = tree["frame"] as? [String: Any] {
            mainFrameID = frame["id"] as? String
        }
    }

    private func command(
        _ method: String,
        parameters: [String: Any] = [:],
        timeoutMilliseconds: Int32 = 125_000
    ) throws -> [String: Any] {
        try connection.command(
            method,
            parameters: parameters,
            sessionID: sessionID,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    private func sendWithoutWaiting(_ method: String, parameters: [String: Any] = [:]) throws {
        try connection.sendWithoutWaiting(method, parameters: parameters, sessionID: sessionID)
    }

    func visit(_ url: URL) throws -> JSONValue {
        navigationLock.lock(); lastSafeURL = url.absoluteString; navigationLock.unlock()
        pauseRecordingCapture()
        _ = try command("Page.navigate", parameters: ["url": url.absoluteString])
        return try wait(parameters: ["settled": .bool(true), "timeoutMs": .number(20_000)])
    }

    func inspect(interactive: Bool, includeText: Bool) throws -> JSONValue {
        try evaluate(
            "return globalThis.__headlessAgent.snapshot(interactive, includeText);",
            input: ["interactive": interactive, "includeText": includeText]
        )
    }

    func click(parameters: [String: JSONValue]) throws -> JSONValue {
        let args = try targetArguments(parameters)
        let result = try evaluate("return globalThis.__headlessAgent.click(args);", input: ["args": args])
        // A click can synchronously begin a cross-document navigation. Let the
        // foreground wait command observe that transition before frame capture
        // resumes, instead of asking Chromium to composite a disappearing page.
        pauseRecordingCapture()
        return result
    }

    func fill(parameters: [String: JSONValue]) throws -> JSONValue {
        var args = try targetArguments(parameters)
        guard let value = parameters["value"]?.stringValue else { throw CDPError.commandFailed("missing value") }
        args["value"] = value
        return try evaluate("return globalThis.__headlessAgent.fill(args);", input: ["args": args])
    }

    func press(parameters: [String: JSONValue]) throws -> JSONValue {
        guard let key = parameters["key"]?.stringValue else { throw CDPError.commandFailed("missing key") }
        return try evaluate("return globalThis.__headlessAgent.press(key);", input: ["key": key])
    }

    func scroll(parameters: [String: JSONValue]) throws -> JSONValue {
        var args: [String: Any] = ["direction": parameters["direction"]?.stringValue ?? "down"]
        if let amount = parameters["amount"]?.numberValue { args["amount"] = amount }
        return try evaluate("return globalThis.__headlessAgent.scroll(args);", input: ["args": args])
    }

    func wait(parameters: [String: JSONValue]) throws -> JSONValue {
        let timeoutMs = min(120_000, max(100, parameters["timeoutMs"]?.numberValue ?? 20_000))
        let expectedURL = parameters["url"]?.stringValue
        let expectedText = parameters["text"]?.stringValue
        let requireSettled = parameters["settled"]?.boolValue ?? false
        let deadline = Date().addingTimeInterval(timeoutMs / 1_000)
        var state: JSONValue = .object([:])
        repeat {
            do {
                state = try evaluate("return globalThis.__headlessAgent.state();")
            } catch let error as CDPError where isTransientNavigationContext(error) && Date() < deadline {
                // A reload can replace the frame between creating the isolated
                // world and evaluating its state. The next short poll uses the
                // new frame instead of turning a normal navigation race into a
                // failed browser command.
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            guard case .object(let object) = state else { throw CDPError.invalidResponse("page state") }
            let urlMatches = expectedURL.map { object["url"]?.stringValue?.contains($0) == true } ?? true
            let textMatches = expectedText.map { object["text"]?.stringValue?.localizedCaseInsensitiveContains($0) == true } ?? true
            let ready = object["readyState"]?.stringValue == "complete"
            let animations = object["runningAnimations"]?.numberValue ?? 0
            let quiet = object["mutationQuietMs"]?.numberValue ?? 0
            if urlMatches && textMatches && (!requireSettled || (ready && animations == 0 && quiet >= 300)) { return state }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        throw CDPError.timedOut
    }

    private func isTransientNavigationContext(_ error: CDPError) -> Bool {
        guard case .commandFailed(let message) = error else { return false }
        return message.localizedCaseInsensitiveContains("Cannot find context")
            || message.localizedCaseInsensitiveContains("Execution context was destroyed")
    }

    func tour(parameters: [String: JSONValue]) throws -> JSONValue {
        let pace = min(5_000, max(100, parameters["pace"]?.numberValue ?? 800))
        return try evaluate(
            "return await globalThis.__headlessAgent.tour(args);",
            input: ["args": ["pace": pace, "fullPage": parameters["fullPage"]?.boolValue ?? true]],
            timeout: 65
        )
    }

    func back() throws -> JSONValue {
        let history = try command("Page.getNavigationHistory")
        let index = (history["currentIndex"] as? NSNumber)?.intValue ?? 0
        guard index > 0, let entries = history["entries"] as? [[String: Any]],
              let entryID = entries[index - 1]["id"] as? NSNumber else {
            throw CDPError.commandFailed("no back history")
        }
        pauseRecordingCapture()
        _ = try command("Page.navigateToHistoryEntry", parameters: ["entryId": entryID])
        return try wait(parameters: ["settled": .bool(true)])
    }

    func reload() throws -> JSONValue {
        pauseRecordingCapture()
        // Chromium's snap build can leave the DevTools pipe waiting forever
        // for Page.reload. Re-navigate to the current safe web URL instead:
        // it preserves the agent-visible reload result while using the same
        // reliable Page.navigate path as `visit`.
        let currentURL = try stateURL()
        return try visit(currentURL)
    }

    func state() throws -> JSONValue { try evaluate("return globalThis.__headlessAgent.state();") }

    private func stateURL() throws -> URL {
        guard case .object(let state) = try state(),
              let rawURL = state["url"]?.stringValue else {
            throw CDPError.invalidResponse("page state did not return a URL")
        }
        return try normalizedWebURL(rawURL)
    }

    func screenshot(
        parameters: [String: JSONValue],
        timeoutMilliseconds: Int32 = 30_000
    ) throws -> Data {
        var capture: [String: Any] = [
            "format": "png", "fromSurface": true, "captureBeyondViewport": false,
        ]
        let hasTarget = parameters["target"] != nil || parameters["role"] != nil || parameters["name"] != nil
        if hasTarget {
            capture["captureBeyondViewport"] = true
            let args = try targetArguments(parameters)
            let rectangle = try evaluate(
                "return globalThis.__headlessAgent.rectangle(args);", input: ["args": args]
            )
            guard case .object(let outer) = rectangle,
                  case .object(let rect)? = outer["document"] else {
                throw CDPError.invalidResponse("element rectangle")
            }
            capture["clip"] = try screenshotClip(rect)
        } else if parameters["fullPage"]?.boolValue == true {
            capture["captureBeyondViewport"] = true
            let metrics = try command("Page.getLayoutMetrics")
            guard let size = (metrics["cssContentSize"] ?? metrics["contentSize"]) as? [String: Any] else {
                throw CDPError.invalidResponse("Page.getLayoutMetrics content size")
            }
            capture["clip"] = try screenshotClip([
                "x": .number(0), "y": .number(0),
                "width": .number((size["width"] as? NSNumber)?.doubleValue ?? 0),
                "height": .number((size["height"] as? NSNumber)?.doubleValue ?? 0),
            ])
        }
        let response = try command(
            "Page.captureScreenshot",
            parameters: capture,
            timeoutMilliseconds: timeoutMilliseconds
        )
        guard let base64 = response["data"] as? String, let data = Data(base64Encoded: base64) else {
            throw CDPError.invalidResponse("Page.captureScreenshot data")
        }
        return data
    }

    func recordingFrame() throws -> Data {
        recordingLock.lock(); let pausedUntil = recordingPausedUntil; recordingLock.unlock()
        guard Date() >= pausedUntil else {
            throw RecordingError.captureFailed("page transition in progress")
        }
        return try screenshot(parameters: [:], timeoutMilliseconds: 2_000)
    }

    func qaReport() throws -> JSONValue {
        _ = try command("Runtime.evaluate", parameters: ["expression": "0", "returnByValue": true])
        return diagnostics.report()
    }

    func console(level: String, limit: Int) -> JSONValue {
        diagnostics.console(level: level, limit: limit)
    }

    func network(failedOnly: Bool, status: Int?, limit: Int) -> JSONValue {
        diagnostics.network(failedOnly: failedOnly, status: status, limit: limit)
    }

    func networkDetail(requestID: String) -> JSONValue {
        diagnostics.networkDetail(requestID: requestID)
    }

    func styles(parameters: [String: JSONValue]) throws -> JSONValue {
        var args = try targetArguments(parameters)
        if case .array(let properties)? = parameters["properties"] {
            args["properties"] = properties.compactMap(\.stringValue)
        }
        return try evaluate("return globalThis.__headlessAgent.styles(args);", input: ["args": args])
    }

    func storage(scope: String, includeValues: Bool) throws -> JSONValue {
        try requireSensitiveDiagnosticsIfNeeded(includeValues)
        return try evaluate(
            "return globalThis.__headlessAgent.storage(args);",
            input: ["args": ["scope": scope, "includeValues": includeValues]]
        )
    }

    func performance() throws -> JSONValue {
        try evaluate("return globalThis.__headlessAgent.performance();")
    }

    func animations() throws -> JSONValue {
        try evaluate("return globalThis.__headlessAgent.animations();")
    }

    func emulateNetwork(parameters: [String: JSONValue]) throws -> JSONValue {
        let offline = parameters["offline"]?.boolValue ?? false
        let latency = parameters["latencyMs"]?.numberValue ?? 0
        let down = parameters["downloadKbps"]?.numberValue ?? -1
        let up = parameters["uploadKbps"]?.numberValue ?? -1
        _ = try command("Network.emulateNetworkConditions", parameters: [
            "offline": offline,
            "latency": latency,
            "downloadThroughput": down < 0 ? -1 : down * 1_024 / 8,
            "uploadThroughput": up < 0 ? -1 : up * 1_024 / 8,
            "connectionType": offline ? "none" : "other",
        ])
        return .object(["offline": .bool(offline), "latencyMs": .number(latency),
                        "downloadKbps": .number(down), "uploadKbps": .number(up),
                        "engine": .string("chromium-cdp")])
    }

    func setNetworkMock(parameters: [String: JSONValue]) throws -> JSONValue {
        guard let rawURL = parameters["url"]?.stringValue,
              let body = parameters["body"]?.stringValue else { throw CDPError.commandFailed("missing mock URL or body") }
        let url = try normalizedWebURL(rawURL).absoluteString
        let status = Int(parameters["status"]?.numberValue ?? 200)
        let contentType = parameters["contentType"]?.stringValue ?? "application/json; charset=utf-8"
        mockLock.lock()
        let hadMocks = !networkMocks.isEmpty
        networkMocks.removeAll { $0.url == url }
        networkMocks.append(NetworkMock(url: url, status: status, body: body, contentType: contentType))
        let patterns: [[String: Any]] = networkMocks.map {
            ["urlPattern": $0.url, "requestStage": "Request"]
        }
        mockLock.unlock()
        // Pause only explicitly mocked URLs. A wildcard pauses the document and
        // every asset as well, so one delayed continuation can make a normal
        // reload appear hung. Reconfigure when the mock set changes.
        if hadMocks { _ = try command("Fetch.disable") }
        _ = try command("Fetch.enable", parameters: ["patterns": patterns])
        return .object(["url": .string(url), "status": .number(Double(status)), "activeMocks": .number(Double(mockCount()))])
    }

    func clearNetworkMocks() throws -> JSONValue {
        mockLock.lock(); let count = networkMocks.count; networkMocks.removeAll(); mockLock.unlock()
        if count > 0 { _ = try command("Fetch.disable") }
        return .object(["cleared": .number(Double(count))])
    }

    func cookies(includeValues: Bool) throws -> JSONValue {
        try requireSensitiveDiagnosticsIfNeeded(includeValues)
        let response = try command("Network.getCookies")
        let rawCookies = response["cookies"] as? [[String: Any]] ?? []
        let cookies: [JSONValue] = rawCookies.prefix(200).map { cookie in
            var item: [String: JSONValue] = [:]
            for key in ["name", "domain", "path", "sameSite", "priority", "sourceScheme"] {
                if let value = cookie[key] as? String { item[key] = .string(String(value.prefix(512))) }
            }
            for key in ["secure", "httpOnly", "session", "partitionKeyOpaque"] {
                if let value = cookie[key] as? Bool { item[key] = .bool(value) }
                else if let value = cookie[key] as? NSNumber { item[key] = .bool(value.boolValue) }
            }
            if let value = cookie["expires"] as? NSNumber { item["expiresAt"] = .number(value.doubleValue) }
            let value = cookie["value"] as? String ?? ""
            if includeValues { item["value"] = .string(String(value.prefix(16_384))) }
            else { item["valueBytes"] = .number(Double(value.utf8.count)) }
            return .object(item)
        }
        return .object([
            "cookies": .array(cookies),
            "returned": .number(Double(cookies.count)),
            "available": .number(Double(rawCookies.count)),
            "truncated": .bool(rawCookies.count > cookies.count),
            "source": .string("chromium-cdp"),
        ])
    }

    func handleEvent(_ event: [String: Any]) {
        guard let method = event["method"] as? String,
              let parameters = event["params"] as? [String: Any] else { return }
        switch method {
        case "Fetch.requestPaused":
            guard let requestID = parameters["requestId"] as? String,
                  let request = parameters["request"] as? [String: Any],
                  let url = request["url"] as? String else { return }
            let mock = matchingMock(url)
            // The CDP reader is currently waiting for the page operation that
            // triggered this event. Send the continuation immediately, without
            // waiting for its own response, or a mocked fetch can deadlock the
            // page operation that is waiting on it.
            if let mock {
                let body = Data(mock.body.utf8).base64EncodedString()
                try? sendWithoutWaiting("Fetch.fulfillRequest", parameters: [
                    "requestId": requestID, "responseCode": mock.status,
                    "responseHeaders": [["name": "content-type", "value": mock.contentType],
                                        ["name": "cache-control", "value": "no-store"]],
                    "body": body,
                ])
            } else {
                try? sendWithoutWaiting("Fetch.continueRequest", parameters: ["requestId": requestID])
            }
        case "Page.frameStartedLoading":
            pauseRecordingCapture()
        case "Page.frameRequestedNavigation":
            pauseRecordingCapture()
            if let frameID = parameters["frameId"] as? String,
               let url = parameters["url"] as? String {
                enforceMainFrameNavigation(frameID: frameID, url: url, committed: false)
            }
        case "Page.frameNavigated":
            pauseRecordingCapture()
            if let frame = parameters["frame"] as? [String: Any],
               frame["parentId"] == nil,
               let frameID = frame["id"] as? String,
               let url = frame["url"] as? String {
                enforceMainFrameNavigation(frameID: frameID, url: url, committed: true)
            }
        case "Runtime.consoleAPICalled":
            let level = parameters["type"] as? String ?? "log"
            let arguments = parameters["args"] as? [[String: Any]] ?? []
            let message = arguments.prefix(20).map { argument in
                if let value = argument["value"] { return String(describing: value) }
                return argument["description"] as? String ?? argument["type"] as? String ?? ""
            }.joined(separator: " ")
            let rawTimestamp = (parameters["timestamp"] as? NSNumber)?.doubleValue
            let timestamp = rawTimestamp.map { $0 > 100_000_000_000 ? $0 / 1_000 : $0 }
                ?? Date().timeIntervalSince1970
            diagnostics.append(kind: "console", level: level, message: message, timestamp: timestamp)
        case "Runtime.exceptionThrown":
            let details = parameters["exceptionDetails"] as? [String: Any] ?? [:]
            let exception = details["exception"] as? [String: Any]
            diagnostics.append(
                kind: "page-error",
                message: exception?["description"] as? String ?? details["text"] as? String ?? "JavaScript exception",
                url: details["url"] as? String
            )
        case "Log.entryAdded":
            let entry = parameters["entry"] as? [String: Any] ?? [:]
            diagnostics.append(kind: "console", level: entry["level"] as? String,
                               message: entry["text"] as? String, url: entry["url"] as? String)
        case "Network.requestWillBeSent":
            guard let requestID = parameters["requestId"] as? String,
                  let request = parameters["request"] as? [String: Any] else { return }
            diagnosticsLock.lock()
            requestContexts[requestID] = (
                request["method"] as? String,
                request["url"] as? String,
                stringHeaders(request["headers"] as? [String: Any])
            )
            diagnosticsLock.unlock()
        case "Network.responseReceived":
            let response = parameters["response"] as? [String: Any] ?? [:]
            let requestID = parameters["requestId"] as? String ?? ""
            diagnosticsLock.lock(); let request = requestContexts[requestID]; diagnosticsLock.unlock()
            diagnostics.append(kind: "response", url: response["url"] as? String,
                               method: request?.method, status: (response["status"] as? NSNumber)?.doubleValue,
                               requestID: requestID, requestHeaders: request?.headers,
                               responseHeaders: stringHeaders(response["headers"] as? [String: Any]), source: "chromium-cdp")
        case "Network.loadingFailed":
            let requestID = parameters["requestId"] as? String ?? ""
            diagnosticsLock.lock(); let request = requestContexts.removeValue(forKey: requestID); diagnosticsLock.unlock()
            diagnostics.append(kind: "request-failed", message: parameters["errorText"] as? String,
                               url: request?.url, method: request?.method, requestID: requestID,
                               requestHeaders: request?.headers, source: "chromium-cdp")
        case "Network.loadingFinished":
            if let requestID = parameters["requestId"] as? String {
                diagnosticsLock.lock(); requestContexts.removeValue(forKey: requestID); diagnosticsLock.unlock()
            }
        default: break
        }
    }

    private func pauseRecordingCapture(for interval: TimeInterval = 0.75) {
        recordingLock.lock()
        recordingPausedUntil = max(recordingPausedUntil, Date().addingTimeInterval(interval))
        recordingLock.unlock()
    }

    private func enforceMainFrameNavigation(frameID: String, url: String, committed: Bool) {
        navigationLock.lock()
        if mainFrameID == nil { mainFrameID = frameID }
        guard mainFrameID == frameID else { navigationLock.unlock(); return }
        if let parsed = URL(string: url), agentMayNavigate(to: parsed) {
            if committed { lastSafeURL = url }
            navigationLock.unlock()
            return
        }
        guard !navigationRecoveryPending else { navigationLock.unlock(); return }
        let recoveryURL = lastSafeURL ?? "about:blank"
        navigationRecoveryPending = true
        navigationLock.unlock()

        diagnostics.append(
            kind: "navigation-blocked",
            message: "Blocked non-web or credential-bearing top-frame navigation",
            url: url
        )
        // Event handlers run while the synchronous CDP reader owns its command
        // lock. Recover on another queue after that response is released.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            _ = try? self.command("Page.stopLoading", timeoutMilliseconds: 2_000)
            _ = try? self.command(
                "Page.navigate", parameters: ["url": recoveryURL], timeoutMilliseconds: 5_000
            )
            self.navigationLock.lock(); self.navigationRecoveryPending = false; self.navigationLock.unlock()
        }
    }

    private func screenshotClip(_ rect: [String: JSONValue]) throws -> [String: Any] {
        guard let x = rect["x"]?.numberValue, let y = rect["y"]?.numberValue,
              let width = rect["width"]?.numberValue, let height = rect["height"]?.numberValue,
              x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 64_000_000 else {
            throw CDPError.commandFailed("screenshot dimensions exceed safety limits")
        }
        return ["x": x, "y": y, "width": width, "height": height, "scale": 1]
    }

    private func evaluate(_ body: String, input: [String: Any] = [:], timeout: TimeInterval = 10) throws -> JSONValue {
        _ = timeout // The dedicated DevTools socket has a bounded 125-second timeout.
        let inputData = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        guard let inputJSON = String(data: inputData, encoding: .utf8) else {
            throw CDPError.invalidResponse("input encoding")
        }
        let expression = """
        (async () => {
          const __input = \(inputJSON);
          const interactive = __input.interactive;
          const includeText = __input.includeText;
          const args = __input.args;
          const key = __input.key;
          \(agentRuntimeJavaScript)
          \(body)
        })()
        """
        let response = try command("Runtime.evaluate", parameters: [
            "expression": expression,
            "awaitPromise": true,
            "returnByValue": true,
            "userGesture": true,
            "contextId": try isolatedExecutionContextID(),
        ])
        if let exception = response["exceptionDetails"] as? [String: Any] {
            throw CDPError.commandFailed(exception["text"] as? String ?? String(describing: exception))
        }
        guard let result = response["result"] as? [String: Any] else {
            throw CDPError.invalidResponse("Runtime.evaluate result")
        }
        if let description = result["description"] as? String, result["subtype"] as? String == "error" {
            throw CDPError.commandFailed(description)
        }
        return try JSONValue.foundationValue(result["value"] ?? NSNull())
    }

    /// Evaluate agent helpers in a fresh isolated world. Page scripts cannot
    /// discover or replace `__headlessAgent`, while the world still has DOM
    /// access. Recreating the world also avoids stale context IDs after a
    /// cross-document navigation.
    private func isolatedExecutionContextID() throws -> Int {
        let frameTree = try command("Page.getFrameTree")
        guard let tree = frameTree["frameTree"] as? [String: Any],
              let frame = tree["frame"] as? [String: Any],
              let frameID = frame["id"] as? String else {
            throw CDPError.invalidResponse("Page.getFrameTree did not return the main frame")
        }
        let result = try command("Page.createIsolatedWorld", parameters: [
            "frameId": frameID,
            "worldName": "HeadlessAgent",
            "grantUniversalAccess": false,
        ])
        guard let contextID = result["executionContextId"] as? NSNumber else {
            throw CDPError.invalidResponse("Page.createIsolatedWorld did not return an execution context")
        }
        return contextID.intValue
    }

    private func targetArguments(_ parameters: [String: JSONValue]) throws -> [String: Any] {
        if let target = parameters["target"]?.stringValue {
            guard target.hasPrefix("@e"), target.count <= 16 else { throw CDPError.commandFailed("invalid element ref") }
            return ["target": target]
        }
        var result: [String: Any] = [:]
        if let role = parameters["role"]?.stringValue { result["role"] = role }
        if let name = parameters["name"]?.stringValue { result["name"] = name }
        guard !result.isEmpty else { throw CDPError.commandFailed("missing target") }
        return result
    }

    private func requireSensitiveDiagnosticsIfNeeded(_ requested: Bool) throws {
        guard !requested || ProcessInfo.processInfo.environment["HEADLESS_ALLOW_SENSITIVE_DIAGNOSTICS"] == "1" else {
            throw CDPError.commandFailed("SENSITIVE_DIAGNOSTICS_DISABLED")
        }
    }

    private func stringHeaders(_ headers: [String: Any]?) -> [String: String] {
        (headers ?? [:]).reduce(into: [:]) { result, entry in
            result[entry.key] = String(describing: entry.value)
        }
    }

    private func matchingMock(_ url: String) -> NetworkMock? {
        mockLock.lock(); defer { mockLock.unlock() }
        return networkMocks.first { $0.url == url }
    }

    private func mockCount() -> Int {
        mockLock.lock(); defer { mockLock.unlock() }
        return networkMocks.count
    }
}
