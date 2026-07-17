import ChromelessProtocol
import Foundation
#if canImport(Glibc)
import Glibc
#endif

final class LinuxBrowserHost: @unchecked Sendable {
    private let browser: ChromiumProcess
    private var sessions: [String: LinuxBrowserSession] = [:]
    private var trace: [String: [JSONValue]] = [:]
    private var activeFlows: [String: [RecordedFlowStep]] = [:]
    private var recordings: [String: BrowserRecording] = [:]
    private let traceStartedAt = ProcessInfo.processInfo.systemUptime
    private let artifacts: ArtifactStore
    var onShutdown: (() -> Void)?

    init() throws {
        artifacts = try ArtifactStore()
        browser = try ChromiumProcess()
        sessions["default"] = try browser.createSession()
        trace["default"] = []
    }

    func stop() {
        for recording in recordings.values { _ = try? recording.stop(timeout: 5) }
        recordings.removeAll()
        for session in sessions.values { browser.closeSession(session) }
        sessions.removeAll()
        browser.stop()
    }

    func handle(_ request: CommandRequest) -> CommandResponse {
        if request.command == .ping {
            return .success(id: request.id, result: .object([
                "ready": .bool(true), "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
                "engine": .string("chromium"), "platform": .string("linux"),
                "protocolVersion": .string(chromelessProtocolVersion),
                "recordingAvailable": .bool(BrowserRecording.isAvailable()),
                "artifactDirectory": .string(artifacts.rootURL.path),
            ]))
        }
        if request.command == .shutdown {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { self.onShutdown?() }
            return .success(id: request.id, result: .object(["stopping": .bool(true)]))
        }
        do {
            if request.command == .artifactList {
                return .success(id: request.id, result: try artifacts.list())
            }
            switch request.command {
            case .sessionCreate:
                guard let name = request.parameters["name"]?.stringValue else { return failure(request, "MISSING_PARAMETER", "Session name is required.") }
                try validateIdentifier(name, field: "session")
                guard sessions[name] == nil else { return failure(request, "SESSION_EXISTS", "Session already exists: \(name)") }
                sessions[name] = try browser.createSession()
                trace[name] = []
                record(.sessionCreate, session: name)
                return .success(id: request.id, result: .object(["session": .string(name)]))
            case .sessionList:
                return .success(id: request.id, result: .object(["sessions": .array(sessions.keys.sorted().map(JSONValue.string))]))
            case .sessionClose:
                let name = request.session ?? "default"
                guard let session = sessions.removeValue(forKey: name) else { return missingSession(request, name) }
                if let recording = recordings.removeValue(forKey: name) { _ = try? recording.stop(timeout: 5) }
                browser.closeSession(session)
                trace.removeValue(forKey: name)
                activeFlows.removeValue(forKey: name)
                return .success(id: request.id, result: .object(["closed": .string(name)]))
            default:
                break
            }

            let name = request.session ?? "default"
            guard let session = sessions[name] else { return missingSession(request, name) }
            let result: JSONValue
            switch request.command {
            case .visit:
                guard let value = request.parameters["url"]?.stringValue else { return failure(request, "MISSING_PARAMETER", "URL is required.") }
                result = try session.visit(normalizedWebURL(value))
            case .inspect:
                result = try session.inspect(interactive: request.parameters["interactive"]?.boolValue ?? false,
                                             includeText: request.parameters["text"]?.boolValue ?? false)
            case .click: result = try session.click(parameters: request.parameters)
            case .fill: result = try session.fill(parameters: request.parameters)
            case .press: result = try session.press(parameters: request.parameters)
            case .scroll: result = try session.scroll(parameters: request.parameters)
            case .wait: result = try session.wait(parameters: request.parameters)
            case .tour: result = try session.tour(parameters: request.parameters)
            case .back: result = try session.back()
            case .reload: result = try session.reload()
            case .captureInfo:
                result = .object([
                    "engine": .string("chromium"), "headless": .bool(browser.headless),
                    "browserPid": .number(Double(browser.processIdentifier)),
                    "targetId": .string(session.targetID), "page": try session.state(),
                    "trace": .array(trace[name] ?? []),
                    "recording": recordings[name]?.status() ?? .object(["active": .bool(false)]),
                ])
            case .screenshot:
                let data = try session.screenshot(parameters: request.parameters)
                result = try artifacts.write(
                    data, requestedName: request.parameters["output"]?.stringValue,
                    extension: "png", prefix: "screenshot-\(name)"
                )
            case .recordStart:
                guard recordings[name] == nil else { throw RecordingError.alreadyActive }
                let output = try artifacts.reserve(
                    requestedName: request.parameters["output"]?.stringValue,
                    extension: "mp4", prefix: "recording-\(name)"
                )
                let fps = request.parameters["fps"]?.numberValue ?? 10
                let recording: BrowserRecording
                do {
                    recording = try BrowserRecording(outputURL: output, fps: fps) { [weak session] in
                        guard let session else { throw RecordingError.captureFailed("session closed") }
                        return try session.recordingFrame()
                    }
                } catch {
                    try? FileManager.default.removeItem(at: output)
                    throw error
                }
                recordings[name] = recording
                result = recording.status()
            case .recordStatus:
                result = recordings[name]?.status() ?? .object(["active": .bool(false)])
            case .recordStop:
                guard let recording = recordings.removeValue(forKey: name) else { throw RecordingError.notActive }
                let recordingStatus: JSONValue
                do { recordingStatus = try recording.stop() }
                catch {
                    try? FileManager.default.removeItem(at: recording.outputURL)
                    throw error
                }
                let artifact = try artifacts.finalize(
                    recording.outputURL, renameTo: request.parameters["output"]?.stringValue
                )
                result = merge(recordingStatus, with: artifact)
            case .qaReport:
                result = try session.qaReport()
            case .qaClear:
                result = session.diagnostics.clear()
            case .consoleList:
                result = session.console(
                    level: request.parameters["level"]?.stringValue ?? "all",
                    limit: Int(request.parameters["limit"]?.numberValue ?? 100)
                )
            case .networkList:
                result = session.network(
                    failedOnly: request.parameters["failed"]?.boolValue ?? false,
                    status: request.parameters["status"]?.numberValue.map(Int.init),
                    limit: Int(request.parameters["limit"]?.numberValue ?? 100)
                )
            case .networkGet:
                guard let requestID = request.parameters["requestId"]?.stringValue else {
                    return failure(request, "MISSING_PARAMETER", "Network request ID is required.")
                }
                result = session.networkDetail(requestID: requestID)
            case .stylesGet:
                result = try session.styles(parameters: request.parameters)
            case .cookiesList:
                result = try session.cookies(includeValues: request.parameters["includeValues"]?.boolValue ?? false)
            case .storageList:
                result = try session.storage(
                    scope: request.parameters["scope"]?.stringValue ?? "all",
                    includeValues: request.parameters["includeValues"]?.boolValue ?? false
                )
            case .performanceGet: result = try session.performance()
            case .animationList: result = try session.animations()
            case .networkEmulate: result = try session.emulateNetwork(parameters: request.parameters)
            case .networkMockSet: result = try session.setNetworkMock(parameters: request.parameters)
            case .networkMockClear: result = try session.clearNetworkMocks()
            case .visualCompare:
                let before = request.parameters["before"]!.stringValue!
                let after = request.parameters["after"]!.stringValue!
                _ = try artifacts.read(name: before, expectedExtension: "png", maximumBytes: 100 * 1_024 * 1_024)
                _ = try artifacts.read(name: after, expectedExtension: "png", maximumBytes: 100 * 1_024 * 1_024)
                let difference = try artifacts.reserve(requestedName: request.parameters["output"]?.stringValue,
                                                       extension: "png", prefix: "difference-\(name)")
                let comparison = try VisualComparison.compare(
                    before: artifacts.rootURL.appendingPathComponent(before),
                    after: artifacts.rootURL.appendingPathComponent(after), difference: difference
                )
                result = merge(comparison, with: try artifacts.finalize(difference, renameTo: nil))
            case .reportCreate:
                let report: JSONValue = .object([
                    "format": .string("chromeless-qa-report-v1"),
                    "createdAt": .number(Date().timeIntervalSince1970), "session": .string(name),
                    "page": .object(["engine": .string("chromium"), "state": try session.state()]),
                    "qa": try session.qaReport(), "trace": .array(trace[name] ?? []),
                    "artifacts": try artifacts.list(),
                    "security": .object(["sensitiveValuesIncluded": .bool(false), "transport": .string("local-unix-socket")]),
                ])
                result = try artifacts.write(ProtocolCodec.encoder.encode(report),
                                             requestedName: request.parameters["output"]?.stringValue,
                                             extension: "json", prefix: "qa-report-\(name)")
            case .flowStart:
                activeFlows[name] = []
                result = .object(["recording": .bool(true), "note": .string("Only safe navigation actions are recorded; typed values and credentials are never stored.")])
            case .flowStop:
                let steps = activeFlows.removeValue(forKey: name) ?? []
                result = try artifacts.write(ProtocolCodec.encoder.encode(RecordedFlow(commands: steps)),
                                             requestedName: request.parameters["output"]?.stringValue,
                                             extension: "json", prefix: "flow-\(name)")
            case .flowRun:
                guard let input = request.parameters["input"]?.stringValue else { return failure(request, "MISSING_PARAMETER", "Flow input is required.") }
                let flow = try ProtocolCodec.decoder.decode(RecordedFlow.self, from: artifacts.read(name: input, expectedExtension: "json", maximumBytes: 1_024 * 1_024))
                guard flow.version == 1, flow.commands.count <= 200,
                      flow.commands.allSatisfy({ replayableFlowCommands.contains($0.command) }) else {
                    return failure(request, "INVALID_FLOW", "Flow contains unsupported commands.")
                }
                var completed = 0
                for step in flow.commands {
                    try CommandRequest(command: step.command, session: name, parameters: step.parameters).validate()
                    let response = handle(CommandRequest(command: step.command, session: name, parameters: step.parameters))
                    guard response.ok else { return failure(request, "FLOW_FAILED", "Step \(completed + 1) (\(step.command.rawValue)) failed: \(response.error?.message ?? "unknown error")") }
                    completed += 1
                }
                result = .object(["completed": .number(Double(completed)), "input": .string(input)])
            case .ping, .shutdown, .sessionCreate, .sessionList, .sessionClose, .artifactList:
                return failure(request, "INVALID_COMMAND", "Command is not valid in this context.")
            }
            record(request.command, session: name, result: result)
            if let step = flowStepIfSafe(command: request.command, parameters: request.parameters), activeFlows[name] != nil {
                if (activeFlows[name]?.count ?? 0) < 200 { activeFlows[name]?.append(step) }
            }
            return .success(id: request.id, result: result)
        } catch let error as ProtocolValidationError {
            if case .unsafeResourceType = error {
                return failure(request, "UNSAFE_RESOURCE_TYPE", error.description,
                               suggestion: "Executable files, installers, scripts, and disk images are blocked. Use normal web pages or media only.")
            }
            return failure(request, "INVALID_INPUT", error.description)
        } catch let error as CDPError {
            let code: String
            let suggestion: String?
            switch error {
            case .timedOut:
                code = "TIMEOUT"; suggestion = "Inspect the page or wait for a narrower condition."
            case .commandFailed(let message) where message.contains("ELEMENT_NOT_FOUND"):
                code = "ELEMENT_NOT_FOUND"; suggestion = "Run `chromeless inspect --interactive` to refresh references."
            case .commandFailed(let message) where message.contains("UNSAFE_NAVIGATION"):
                code = "UNSAFE_NAVIGATION"; suggestion = "Agent-controlled sessions allow web navigation only."
            case .commandFailed(let message) where message.contains("UNSAFE_RESOURCE_TYPE"):
                code = "UNSAFE_RESOURCE_TYPE"
                suggestion = "Executable files, installers, scripts, and disk images are blocked."
            case .commandFailed(let message) where message.contains("SENSITIVE_DIAGNOSTICS_DISABLED"):
                code = "SENSITIVE_DIAGNOSTICS_DISABLED"
                suggestion = "Restart the host with CHROMELESS_ALLOW_SENSITIVE_DIAGNOSTICS=1 only when cookie or storage values are required."
            default:
                code = "OPERATION_FAILED"; suggestion = nil
            }
            return .failure(id: request.id, code: code, message: error.description, suggestion: suggestion)
        } catch let error as RecordingError {
            let code: String
            let suggestion: String?
            switch error {
            case .unavailable:
                code = "RECORDER_UNAVAILABLE"
                suggestion = "Install FFmpeg or set CHROMELESS_FFMPEG_EXECUTABLE."
            case .alreadyActive: code = "RECORDING_ACTIVE"; suggestion = nil
            case .notActive: code = "RECORDING_NOT_ACTIVE"; suggestion = nil
            default: code = "RECORDING_FAILED"; suggestion = nil
            }
            return .failure(
                id: request.id, code: code, message: error.description,
                suggestion: suggestion
            )
        } catch let error as ArtifactError {
            return .failure(id: request.id, code: "ARTIFACT_ERROR", message: error.description)
        } catch {
            return failure(request, "INTERNAL_ERROR", String(describing: error))
        }
    }

    private func record(_ command: CommandName, session: String, result: JSONValue? = nil) {
        var event: [String: JSONValue] = [
            "time": .number(ProcessInfo.processInfo.systemUptime - traceStartedAt),
            "command": .string(command.rawValue),
        ]
        if case .object(let object) = result, let url = object["url"]?.stringValue {
            event["url"] = .string(String(decoding: url.utf8.prefix(2_048), as: UTF8.self))
        }
        var entries = trace[session] ?? []
        entries.append(.object(event))
        if entries.count > 256 { entries.removeFirst(entries.count - 256) }
        trace[session] = entries
    }

    private func missingSession(_ request: CommandRequest, _ name: String) -> CommandResponse {
        .failure(id: request.id, code: "SESSION_NOT_FOUND", message: "Session does not exist: \(name)",
                 suggestion: "Run `chromeless session create \(name)`.")
    }

    private func failure(
        _ request: CommandRequest, _ code: String, _ message: String, suggestion: String? = nil
    ) -> CommandResponse {
        .failure(id: request.id, code: code, message: message, suggestion: suggestion)
    }

    private func merge(_ first: JSONValue, with second: JSONValue) -> JSONValue {
        guard case .object(var result) = first, case .object(let extra) = second else { return second }
        result.merge(extra) { _, new in new }
        return .object(result)
    }
}

do {
            #if canImport(Glibc)
            signal(SIGPIPE, SIG_IGN)
            #endif
            let host = try LinuxBrowserHost()
            let server = LocalSocketServer()
            let stopped = DispatchSemaphore(value: 0)
            host.onShutdown = { stopped.signal() }
            try server.start { request in host.handle(request) }

            #if canImport(Glibc)
            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)
            let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            term.setEventHandler { stopped.signal() }
            interrupt.setEventHandler { stopped.signal() }
            term.resume(); interrupt.resume()
            #endif

            stopped.wait()
            server.stop()
            host.stop()
} catch {
    fputs("chromeless-host: \(error)\n", stderr)
    exit(70)
}
