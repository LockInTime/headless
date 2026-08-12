import Foundation

public struct BrowserScreenshot: Sendable {
    public let data: Data
    public let clipboardCopied: Bool

    public init(data: Data, clipboardCopied: Bool = false) {
        self.data = data
        self.clipboardCopied = clipboardCopied
    }
}

/// The portable browser surface used by `HostCore`. Platform adapters keep
/// WKWebView and CDP details out of the command dispatcher.
public protocol BrowserEngineSession: AnyObject {
    func hostEnableAgentControl()
    func hostVisit(_ url: URL) throws -> JSONValue
    func hostInspect(parameters: [String: JSONValue]) throws -> JSONValue
    func hostClick(parameters: [String: JSONValue]) throws -> JSONValue
    func hostFill(parameters: [String: JSONValue]) throws -> JSONValue
    func hostPress(parameters: [String: JSONValue]) throws -> JSONValue
    func hostScroll(parameters: [String: JSONValue]) throws -> JSONValue
    func hostWait(parameters: [String: JSONValue]) throws -> JSONValue
    func hostTour(parameters: [String: JSONValue]) throws -> JSONValue
    func hostBack() throws -> JSONValue
    func hostReload() throws -> JSONValue
    func hostCaptureInfo() throws -> JSONValue
    func hostScreenshot(
        parameters: [String: JSONValue], format: ScreenshotFormat, copyToClipboard: Bool
    ) throws -> BrowserScreenshot
    func hostRecordingFrame() throws -> Data
    func hostScreenshotSeriesPlan(mode: String) throws -> JSONValue
    func hostScrollToCapturePoint(y: Double) throws -> JSONValue
    func hostQAReport() throws -> JSONValue
    func hostQAClear() throws -> JSONValue
    func hostConsole(level: String, limit: Int) throws -> JSONValue
    func hostNetwork(failedOnly: Bool, status: Int?, limit: Int) throws -> JSONValue
    func hostNetworkDetail(requestID: String) throws -> JSONValue
    func hostStyles(parameters: [String: JSONValue]) throws -> JSONValue
    func hostCookies(includeValues: Bool) throws -> JSONValue
    func hostStorage(scope: String, includeValues: Bool) throws -> JSONValue
    func hostPerformance() throws -> JSONValue
    func hostAnimations() throws -> JSONValue
    func hostEmulateNetwork(parameters: [String: JSONValue]) throws -> JSONValue
    func hostSetNetworkMock(parameters: [String: JSONValue]) throws -> JSONValue
    func hostClearNetworkMocks() throws -> JSONValue
}

public extension BrowserEngineSession {
    func hostEnableAgentControl() {}

    func hostEmulateNetwork(parameters: [String: JSONValue]) throws -> JSONValue {
        throw HostError(
            code: .unsupportedCapability,
            message: "Network simulation requires the Chromium CDP engine."
        )
    }

    func hostSetNetworkMock(parameters: [String: JSONValue]) throws -> JSONValue {
        throw HostError(
            code: .unsupportedCapability,
            message: "Request mocking requires the Chromium CDP engine."
        )
    }

    func hostClearNetworkMocks() throws -> JSONValue {
        throw HostError(
            code: .unsupportedCapability,
            message: "Request mocking requires the Chromium CDP engine."
        )
    }
}

public protocol BrowserEngine: AnyObject {
    associatedtype Session: BrowserEngineSession
    var name: String { get }
    var platform: String { get }
    var capabilities: BrowserEngineCapabilities { get }
    func createSession() throws -> Session
    func closeSession(_ session: Session)
    func stop()
    func pingDetails() -> [String: JSONValue]
    func hostError(for error: Error) -> HostError?
}

public extension BrowserEngine {
    func pingDetails() -> [String: JSONValue] { [:] }
    func hostError(for error: Error) -> HostError? { nil }
}

/// Shared command dispatcher and lifecycle state for every browser engine.
/// New portable commands belong here exactly once.
public final class HostCore<Engine: BrowserEngine>: @unchecked Sendable {
    private let engine: Engine
    private let artifacts: ArtifactStore
    private let shutdownHandler: @Sendable () -> Void
    private let lock = NSLock()
    private var sessions: [String: Engine.Session]
    private var trace: [String: [JSONValue]] = ["default": []]
    private var activeFlows: [String: [RecordedFlowStep]] = [:]
    private var recordings: [String: BrowserRecording] = [:]
    private var stopping = false
    private let traceStartedAt = ProcessInfo.processInfo.systemUptime

    public init(
        engine: Engine,
        artifacts: ArtifactStore,
        defaultSession: Engine.Session,
        shutdownHandler: @escaping @Sendable () -> Void
    ) {
        self.engine = engine
        self.artifacts = artifacts
        self.sessions = ["default": defaultSession]
        self.shutdownHandler = shutdownHandler
    }

    private func withState<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public func sessionDidClose(_ closed: Engine.Session) {
        let stoppedRecordings = withState { () -> [BrowserRecording] in
            let names = sessions.compactMap { $0.value === closed ? $0.key : nil }
            var stopped: [BrowserRecording] = []
            for name in names {
                sessions.removeValue(forKey: name)
                trace.removeValue(forKey: name)
                activeFlows.removeValue(forKey: name)
                if let recording = recordings.removeValue(forKey: name) { stopped.append(recording) }
            }
            return stopped
        }
        DispatchQueue.global(qos: .utility).async {
            for recording in stoppedRecordings { _ = try? recording.stop(timeout: 5) }
        }
    }

    public func stop() {
        let captured = withState { () -> ([BrowserRecording], [Engine.Session]) in
            if stopping { return ([], []) }
            stopping = true
            let activeRecordings = Array(recordings.values)
            let openSessions = Array(sessions.values)
            recordings.removeAll()
            sessions.removeAll()
            trace.removeAll()
            activeFlows.removeAll()
            return (activeRecordings, openSessions)
        }
        for recording in captured.0 { _ = try? recording.stop(timeout: 5) }
        for session in captured.1 { engine.closeSession(session) }
        engine.stop()
    }

    public func handle(_ request: CommandRequest) -> CommandResponse {
        if request.command == .ping { return ping(request) }
        if request.command == .shutdown {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1, execute: shutdownHandler)
            return .success(id: request.id, result: .object(["stopping": .bool(true)]))
        }

        do {
            if request.command == .artifactList {
                return .success(id: request.id, result: try artifacts.list())
            }
            switch request.command {
            case .sessionCreate:
                return try createSession(request)
            case .sessionList:
                let names = withState { sessions.keys.sorted() }
                return .success(
                    id: request.id,
                    result: .object(["sessions": .array(names.map(JSONValue.string))])
                )
            case .sessionClose:
                return closeSession(request)
            default:
                break
            }

            let name = request.session ?? "default"
            guard let session = withState({ sessions[name] }) else {
                return missingSession(request, name)
            }
            session.hostEnableAgentControl()
            let result = try execute(request, sessionName: name, session: session)
            record(request.command, session: name, result: result)
            if let step = flowStepIfSafe(command: request.command, parameters: request.parameters) {
                withState {
                    guard let steps = activeFlows[name], steps.count < 200 else { return }
                    activeFlows[name] = steps + [step]
                }
            }
            return .success(id: request.id, result: result)
        } catch let error as HostError {
            return hostFailure(request, error)
        } catch let error as ProtocolValidationError {
            if case .unsafeResourceType = error {
                return failure(
                    request, "UNSAFE_RESOURCE_TYPE", error.description,
                    suggestion: "Executable files, installers, scripts, and disk images are blocked. Use normal web pages or media only."
                )
            }
            return failure(request, "INVALID_INPUT", error.description)
        } catch let error as RecordingError {
            let code: String
            let suggestion: String?
            switch error {
            case .unavailable:
                code = "RECORDER_UNAVAILABLE"
                suggestion = "Install FFmpeg or set HEADLESS_FFMPEG_EXECUTABLE."
            case .alreadyActive: code = "RECORDING_ACTIVE"; suggestion = nil
            case .notActive: code = "RECORDING_NOT_ACTIVE"; suggestion = nil
            default: code = "RECORDING_FAILED"; suggestion = nil
            }
            return failure(request, code, error.description, suggestion: suggestion)
        } catch let error as CaptureFormatError {
            return failure(request, "INVALID_CAPTURE_FORMAT", error.description)
        } catch let error as ArtifactError {
            return failure(request, "ARTIFACT_ERROR", error.description)
        } catch {
            if let translated = engine.hostError(for: error) {
                return hostFailure(request, translated)
            }
            return failure(request, "INTERNAL_ERROR", String(describing: error))
        }
    }

    private func ping(_ request: CommandRequest) -> CommandResponse {
        var details: [String: JSONValue] = [
            "ready": .bool(true),
            "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "engine": .string(engine.name),
            "platform": .string(engine.platform),
            "productVersion": .string(headlessProductVersion),
            "protocolVersion": .string(headlessProtocolVersion),
            "capabilities": engine.capabilities.document,
            "recordingAvailable": .bool(BrowserRecording.isAvailable()),
            "artifactDirectory": .string(artifacts.rootURL.path),
        ]
        details.merge(engine.pingDetails()) { _, engineValue in engineValue }
        return .success(id: request.id, result: .object(details))
    }

    private func createSession(_ request: CommandRequest) throws -> CommandResponse {
        guard let name = request.parameters["name"]?.stringValue else {
            return failure(request, "MISSING_PARAMETER", "Session name is required.")
        }
        do { try validateIdentifier(name, field: "session") }
        catch { return failure(request, "INVALID_SESSION", String(describing: error)) }
        let preflightRejection = withState { () -> String? in
            if stopping { return "HOST_UNAVAILABLE" }
            if sessions[name] != nil { return "SESSION_EXISTS" }
            return nil
        }
        if let preflightRejection {
            return failure(
                request, preflightRejection,
                preflightRejection == "HOST_UNAVAILABLE"
                    ? "Host is shutting down." : "Session already exists: \(name)"
            )
        }
        let created = try engine.createSession()
        let rejection = withState { () -> String? in
            if stopping { return "HOST_UNAVAILABLE" }
            if sessions[name] != nil { return "SESSION_EXISTS" }
            sessions[name] = created
            trace[name] = []
            return nil
        }
        if let rejection {
            engine.closeSession(created)
            return failure(
                request, rejection,
                rejection == "SESSION_EXISTS" ? "Session already exists: \(name)" : "Host is shutting down."
            )
        }
        created.hostEnableAgentControl()
        record(.sessionCreate, session: name)
        return .success(id: request.id, result: .object(["session": .string(name)]))
    }

    private func closeSession(_ request: CommandRequest) -> CommandResponse {
        let name = request.session ?? "default"
        let closing = withState { () -> (Engine.Session?, BrowserRecording?) in
            let session = sessions.removeValue(forKey: name)
            guard session != nil else { return (nil, nil) }
            let recording = recordings.removeValue(forKey: name)
            trace.removeValue(forKey: name)
            activeFlows.removeValue(forKey: name)
            return (session, recording)
        }
        guard let session = closing.0 else { return missingSession(request, name) }
        if let recording = closing.1 { _ = try? recording.stop(timeout: 5) }
        engine.closeSession(session)
        return .success(id: request.id, result: .object(["closed": .string(name)]))
    }

    private func execute(
        _ request: CommandRequest, sessionName name: String, session: Engine.Session
    ) throws -> JSONValue {
        switch request.command {
        case .visit:
            guard let value = request.parameters["url"]?.stringValue else {
                throw HostError(code: .missingParameter, message: "URL is required.")
            }
            return try session.hostVisit(normalizedWebURL(value))
        case .inspect: return try session.hostInspect(parameters: request.parameters)
        case .click: return try session.hostClick(parameters: request.parameters)
        case .fill: return try session.hostFill(parameters: request.parameters)
        case .press: return try session.hostPress(parameters: request.parameters)
        case .scroll: return try session.hostScroll(parameters: request.parameters)
        case .wait: return try session.hostWait(parameters: request.parameters)
        case .tour: return try session.hostTour(parameters: request.parameters)
        case .back: return try session.hostBack()
        case .reload: return try session.hostReload()
        case .captureInfo:
            return try captureInfo(session, name: name)
        case .screenshot:
            if request.parameters["series"]?.stringValue != nil {
                return try captureScreenshotSeries(session: session, parameters: request.parameters)
            }
            let format = try screenshotFormat(
                explicit: request.parameters["format"]?.stringValue,
                output: request.parameters["output"]?.stringValue
            )
            let screenshot = try session.hostScreenshot(
                parameters: request.parameters,
                format: format,
                copyToClipboard: request.parameters["clipboard"]?.boolValue ?? false
            )
            var metadata = try artifacts.write(
                screenshot.data,
                requestedName: request.parameters["output"]?.stringValue,
                extension: artifactExtension(request.parameters["output"]?.stringValue ?? "")
                    ?? format.fileExtension,
                prefix: "screenshot-\(name)"
            )
            if screenshot.clipboardCopied {
                metadata = merge(metadata, with: .object(["clipboard": .bool(true)]))
            }
            return metadata
        case .recordStart:
            return try startRecording(request, name: name, session: session)
        case .recordStatus:
            return withState { recordings[name]?.status() ?? .object(["active": .bool(false)]) }
        case .recordStop:
            return try stopRecording(request, name: name)
        case .qaReport: return try session.hostQAReport()
        case .qaClear: return try session.hostQAClear()
        case .consoleList:
            return try session.hostConsole(
                level: request.parameters["level"]?.stringValue ?? "all",
                limit: Int(request.parameters["limit"]?.numberValue ?? 100)
            )
        case .networkList:
            return try session.hostNetwork(
                failedOnly: request.parameters["failed"]?.boolValue ?? false,
                status: request.parameters["status"]?.numberValue.map(Int.init),
                limit: Int(request.parameters["limit"]?.numberValue ?? 100)
            )
        case .networkGet:
            guard let requestID = request.parameters["requestId"]?.stringValue else {
                throw HostError(code: .missingParameter, message: "Network request ID is required.")
            }
            return try session.hostNetworkDetail(requestID: requestID)
        case .stylesGet: return try session.hostStyles(parameters: request.parameters)
        case .cookiesList:
            return try session.hostCookies(
                includeValues: request.parameters["includeValues"]?.boolValue ?? false
            )
        case .storageList:
            return try session.hostStorage(
                scope: request.parameters["scope"]?.stringValue ?? "all",
                includeValues: request.parameters["includeValues"]?.boolValue ?? false
            )
        case .performanceGet: return try session.hostPerformance()
        case .animationList: return try session.hostAnimations()
        case .networkEmulate: return try session.hostEmulateNetwork(parameters: request.parameters)
        case .networkMockSet: return try session.hostSetNetworkMock(parameters: request.parameters)
        case .networkMockClear: return try session.hostClearNetworkMocks()
        case .visualCompare:
            return try visualCompare(request, sessionName: name)
        case .reportCreate:
            return try createReport(request, sessionName: name, session: session)
        case .flowStart:
            withState { activeFlows[name] = [] }
            return .object([
                "recording": .bool(true),
                "note": .string("Only safe navigation actions are recorded; typed values and credentials are never stored."),
            ])
        case .flowStop:
            let steps = withState { activeFlows.removeValue(forKey: name) } ?? []
            return try artifacts.write(
                ProtocolCodec.encoder.encode(RecordedFlow(commands: steps)),
                requestedName: request.parameters["output"]?.stringValue,
                extension: "json", prefix: "flow-\(name)"
            )
        case .flowRun:
            return try runFlow(request, sessionName: name)
        case .ping, .shutdown, .sessionCreate, .sessionList, .sessionClose, .artifactList:
            throw HostError(code: .invalidCommand, message: "Command is not valid in this context.")
        }
    }

    private func captureInfo(_ session: Engine.Session, name: String) throws -> JSONValue {
        let base = try session.hostCaptureInfo()
        guard case .object(var object) = base else { return base }
        object["trace"] = .array(withState { trace[name] ?? [] })
        object["recording"] = withState {
            recordings[name]?.status() ?? .object(["active": .bool(false)])
        }
        return .object(object)
    }

    private func captureScreenshotSeries(
        session: Engine.Session, parameters: [String: JSONValue]
    ) throws -> JSONValue {
        let mode = parameters["series"]?.stringValue ?? "viewport"
        let format = try screenshotFormat(explicit: parameters["format"]?.stringValue, output: nil)
        let plan = try parseScreenshotSeriesPlan(try session.hostScreenshotSeriesPlan(mode: mode))
        let prefix = try screenshotSeriesPrefix(parameters: parameters, mode: mode)
        defer { _ = try? session.hostScrollToCapturePoint(y: plan.initialY) }
        let reserved = try reserveScreenshotSeriesArtifacts(
            store: artifacts, points: plan.points, prefix: prefix, mode: mode, format: format
        )
        do {
            let metadata = try plan.points.enumerated().map { index, point -> JSONValue in
                _ = try session.hostScrollToCapturePoint(y: point.y)
                let screenshot = try session.hostScreenshot(
                    parameters: [:], format: format, copyToClipboard: false
                )
                return try artifacts.writeReserved(screenshot.data, to: reserved[index])
            }
            return screenshotSeriesSummary(
                mode: mode, points: plan.points, artifacts: metadata,
                truncated: plan.truncated, totalPoints: plan.totalPoints
            )
        } catch {
            artifacts.discardReserved(reserved)
            throw error
        }
    }

    private func startRecording(
        _ request: CommandRequest, name: String, session: Engine.Session
    ) throws -> JSONValue {
        guard withState({ recordings[name] == nil }) else { throw RecordingError.alreadyActive }
        let format = try recordingFormat(
            explicit: request.parameters["format"]?.stringValue,
            output: request.parameters["output"]?.stringValue
        )
        let quality = try RecordingQuality.parse(
            request.parameters["quality"]?.stringValue ?? "balanced"
        )
        let output = try artifacts.reserve(
            requestedName: request.parameters["output"]?.stringValue,
            extension: format.fileExtension, prefix: "recording-\(name)"
        )
        let recording: BrowserRecording
        do {
            recording = try BrowserRecording(
                outputURL: output,
                fps: request.parameters["fps"]?.numberValue ?? 10,
                format: format,
                quality: quality
            ) { [weak session] in
                guard let session else { throw RecordingError.captureFailed("session closed") }
                return try session.hostRecordingFrame()
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        let registered = withState { () -> Bool in
            guard !stopping, sessions[name] === session, recordings[name] == nil else { return false }
            recordings[name] = recording
            return true
        }
        guard registered else {
            _ = try? recording.stop(timeout: 5)
            try? FileManager.default.removeItem(at: output)
            throw HostError(code: .operationFailed, message: "Host is shutting down")
        }
        return recording.status()
    }

    private func stopRecording(_ request: CommandRequest, name: String) throws -> JSONValue {
        guard let active = withState({ recordings[name] }) else { throw RecordingError.notActive }
        if let output = request.parameters["output"]?.stringValue,
           let actual = artifactExtension(output),
           actual != active.format.fileExtension {
            throw CaptureFormatError.mismatchedOutputFormat(
                expected: active.format.fileExtension, actual: actual
            )
        }
        guard let recording = withState({ recordings.removeValue(forKey: name) }) else {
            throw RecordingError.notActive
        }
        let status: JSONValue
        do { status = try recording.stop() }
        catch {
            try? FileManager.default.removeItem(at: recording.outputURL)
            throw error
        }
        let artifact = try artifacts.finalize(
            recording.outputURL, renameTo: request.parameters["output"]?.stringValue
        )
        return merge(status, with: artifact)
    }

    private func visualCompare(_ request: CommandRequest, sessionName: String) throws -> JSONValue {
        guard let before = request.parameters["before"]?.stringValue else {
            throw HostError(code: .missingParameter, message: "Before artifact name is required.")
        }
        guard let after = request.parameters["after"]?.stringValue else {
            throw HostError(code: .missingParameter, message: "After artifact name is required.")
        }
        _ = try artifacts.read(name: before, expectedExtension: "png", maximumBytes: 100 * 1_024 * 1_024)
        _ = try artifacts.read(name: after, expectedExtension: "png", maximumBytes: 100 * 1_024 * 1_024)
        let difference = try artifacts.reserve(
            requestedName: request.parameters["output"]?.stringValue,
            extension: "png", prefix: "difference-\(sessionName)"
        )
        let comparison = try VisualComparison.compare(
            before: artifacts.rootURL.appendingPathComponent(before),
            after: artifacts.rootURL.appendingPathComponent(after),
            difference: difference
        )
        return merge(comparison, with: try artifacts.finalize(difference, renameTo: nil))
    }

    private func createReport(
        _ request: CommandRequest, sessionName name: String, session: Engine.Session
    ) throws -> JSONValue {
        let report: JSONValue = .object([
            "format": .string("headless-qa-report-v1"),
            "createdAt": .number(Date().timeIntervalSince1970),
            "session": .string(name),
            "page": try captureInfo(session, name: name),
            "qa": try session.hostQAReport(),
            "trace": .array(withState { trace[name] ?? [] }),
            "artifacts": try artifacts.list(),
            "security": .object([
                "sensitiveValuesIncluded": .bool(false),
                "transport": .string("local-unix-socket"),
            ]),
        ])
        return try artifacts.write(
            ProtocolCodec.encoder.encode(report),
            requestedName: request.parameters["output"]?.stringValue,
            extension: "json", prefix: "qa-report-\(name)"
        )
    }

    private func runFlow(_ request: CommandRequest, sessionName name: String) throws -> JSONValue {
        guard let input = request.parameters["input"]?.stringValue else {
            throw HostError(code: .missingParameter, message: "Flow input is required.")
        }
        let data = try artifacts.read(
            name: input, expectedExtension: "json", maximumBytes: 1_024 * 1_024
        )
        let flow = try ProtocolCodec.decoder.decode(RecordedFlow.self, from: data)
        guard flow.version == 1,
              flow.commands.count <= 200,
              flow.commands.allSatisfy({ replayableFlowCommands.contains($0.command) }) else {
            throw HostError(code: .invalidFlow, message: "Flow contains unsupported commands.")
        }
        var completed = 0
        for step in flow.commands {
            let replay = CommandRequest(
                command: step.command, session: name, parameters: step.parameters
            )
            try replay.validate()
            let response = handle(replay)
            guard response.ok else {
                throw HostError(
                    code: .flowFailed,
                    message: "Step \(completed + 1) (\(step.command.rawValue)) failed: \(response.error?.message ?? "unknown error")"
                )
            }
            completed += 1
        }
        return .object(["completed": .number(Double(completed)), "input": .string(input)])
    }

    private func record(_ command: CommandName, session: String, result: JSONValue? = nil) {
        var event: [String: JSONValue] = [
            "time": .number(ProcessInfo.processInfo.systemUptime - traceStartedAt),
            "command": .string(command.rawValue),
        ]
        if case .object(let object) = result, let url = object["url"]?.stringValue {
            event["url"] = .string(String(decoding: url.utf8.prefix(2_048), as: UTF8.self))
        }
        withState {
            guard sessions[session] != nil else { return }
            var entries = trace[session] ?? []
            entries.append(.object(event))
            if entries.count > 256 { entries.removeFirst(entries.count - 256) }
            trace[session] = entries
        }
    }

    private func hostFailure(_ request: CommandRequest, _ error: HostError) -> CommandResponse {
        .failure(
            id: request.id, code: error.code.rawValue,
            message: error.message, suggestion: error.suggestion
        )
    }

    private func missingSession(_ request: CommandRequest, _ name: String) -> CommandResponse {
        failure(
            request, "SESSION_NOT_FOUND", "Session does not exist: \(name)",
            suggestion: "Run `headless session create \(name)`."
        )
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
