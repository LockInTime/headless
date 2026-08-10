import HeadlessProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure(description: message) }
}

private func expectThrows(_ message: String, _ body: () throws -> Void) throws {
    do {
        try body()
        throw TestFailure(description: message)
    } catch is TestFailure {
        throw TestFailure(description: message)
    } catch {
        return
    }
}

private func connectRawUnixSocket(path: String) throws -> Int32 {
    #if canImport(Darwin)
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    #else
    let descriptor = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard descriptor >= 0 else { throw TestFailure(description: "raw socket creation failed") }

    #if canImport(Darwin)
    var noSigPipe: Int32 = 1
    guard setsockopt(
        descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
        socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
        Darwin.close(descriptor)
        throw TestFailure(description: "raw socket SIGPIPE configuration failed")
    }
    #endif

    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else {
        #if canImport(Darwin)
        Darwin.close(descriptor)
        #else
        Glibc.close(descriptor)
        #endif
        throw TestFailure(description: "raw socket path was too long")
    }
    address.sun_family = sa_family_t(AF_UNIX)
    #if canImport(Darwin)
    address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + bytes.count + 1)
    #endif
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            #if canImport(Darwin)
            Darwin.connect(descriptor, $0, length)
            #else
            Glibc.connect(descriptor, $0, length)
            #endif
        }
    }
    guard connected == 0 else {
        #if canImport(Darwin)
        Darwin.close(descriptor)
        #else
        Glibc.close(descriptor)
        #endif
        throw TestFailure(description: "raw socket connection failed")
    }
    return descriptor
}

private func closeRawSocket(_ descriptor: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(descriptor)
    #else
    _ = Glibc.close(descriptor)
    #endif
}

private func writeRawSocket(_ data: Data, descriptor: Int32) throws -> Int {
    try data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return 0 }
        var sent = 0
        while sent < buffer.count {
            #if canImport(Darwin)
            let count = Darwin.send(descriptor, base.advanced(by: sent), buffer.count - sent, 0)
            #else
            let count = Glibc.send(
                descriptor, base.advanced(by: sent), buffer.count - sent, Int32(MSG_NOSIGNAL)
            )
            #endif
            if count < 0 {
                if errno == EINTR { continue }
                if sent > headlessMaximumMessageBytes { return sent }
                throw TestFailure(description: "raw socket write failed before the size limit")
            }
            guard count > 0 else { return sent }
            sent += count
        }
        return sent
    }
}

private func readRawSocketLine(descriptor: Int32) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 8_192)
    while result.count <= headlessMaximumMessageBytes {
        #if canImport(Darwin)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        #else
        let count = Glibc.read(descriptor, &buffer, buffer.count)
        #endif
        guard count > 0 else { throw TestFailure(description: "raw socket closed without a response") }
        if let newline = buffer[..<count].firstIndex(of: 0x0A) {
            result.append(contentsOf: buffer[..<newline])
            result.append(0x0A)
            return result
        }
        result.append(contentsOf: buffer[..<count])
    }
    throw TestFailure(description: "raw socket response exceeded the protocol limit")
}

private final class TestBrowserSession: BrowserEngineSession {
    private(set) var agentControlEnableCount = 0

    func hostEnableAgentControl() { agentControlEnableCount += 1 }
    func hostVisit(_ url: URL) throws -> JSONValue { .object(["url": .string(url.absoluteString)]) }
    func hostInspect(parameters: [String: JSONValue]) throws -> JSONValue {
        .object(["engineResult": .bool(true), "parameters": .object(parameters)])
    }
    func hostClick(parameters: [String: JSONValue]) throws -> JSONValue { .object(["clicked": .bool(true)]) }
    func hostFill(parameters: [String: JSONValue]) throws -> JSONValue { .object(["filled": .bool(true)]) }
    func hostPress(parameters: [String: JSONValue]) throws -> JSONValue { .object(["pressed": .bool(true)]) }
    func hostScroll(parameters: [String: JSONValue]) throws -> JSONValue { .object(["scrolled": .bool(true)]) }
    func hostWait(parameters: [String: JSONValue]) throws -> JSONValue { .object(["waited": .bool(true)]) }
    func hostTour(parameters: [String: JSONValue]) throws -> JSONValue { .object(["toured": .bool(true)]) }
    func hostBack() throws -> JSONValue { .object(["back": .bool(true)]) }
    func hostReload() throws -> JSONValue { .object(["reloaded": .bool(true)]) }
    func hostCaptureInfo() throws -> JSONValue { .object(["engine": .string("fake")]) }
    func hostScreenshot(
        parameters: [String: JSONValue], format: ScreenshotFormat, copyToClipboard: Bool
    ) throws -> BrowserScreenshot { BrowserScreenshot(data: Data("image".utf8)) }
    func hostRecordingFrame() throws -> Data { Data("frame".utf8) }
    func hostScreenshotSeriesPlan(mode: String) throws -> JSONValue {
        .object([
            "initialY": .number(0), "totalPoints": .number(1), "truncated": .bool(false),
            "points": .array([.object(["y": .number(0), "label": .string("viewport")])]),
        ])
    }
    func hostScrollToCapturePoint(y: Double) throws -> JSONValue { .object(["y": .number(y)]) }
    func hostQAReport() throws -> JSONValue { .object(["issues": .array([])]) }
    func hostQAClear() throws -> JSONValue { .object(["cleared": .bool(true)]) }
    func hostConsole(level: String, limit: Int) throws -> JSONValue { .object(["entries": .array([])]) }
    func hostNetwork(failedOnly: Bool, status: Int?, limit: Int) throws -> JSONValue {
        .object(["requests": .array([])])
    }
    func hostNetworkDetail(requestID: String) throws -> JSONValue {
        .object(["requestId": .string(requestID)])
    }
    func hostStyles(parameters: [String: JSONValue]) throws -> JSONValue { .object(["styles": .array([])]) }
    func hostCookies(includeValues: Bool) throws -> JSONValue { .object(["cookies": .array([])]) }
    func hostStorage(scope: String, includeValues: Bool) throws -> JSONValue { .object(["scope": .string(scope)]) }
    func hostPerformance() throws -> JSONValue { .object(["metrics": .array([])]) }
    func hostAnimations() throws -> JSONValue { .object(["animations": .array([])]) }
}

private final class TestBrowserEngine: BrowserEngine {
    typealias Session = TestBrowserSession

    let name = "fake"
    let platform = "test"
    let capabilities = BrowserEngineCapabilities.chromium
    private(set) var createdSessions: [TestBrowserSession] = []
    private(set) var closedSessions: [TestBrowserSession] = []
    private(set) var stopped = false

    func createSession() throws -> TestBrowserSession {
        let session = TestBrowserSession()
        createdSessions.append(session)
        return session
    }

    func closeSession(_ session: TestBrowserSession) { closedSessions.append(session) }
    func stop() { stopped = true }
    func pingDetails() -> [String: JSONValue] { ["adapter": .string("test-adapter")] }
}

@main
struct ProtocolTests {
    typealias TestCase = (String, () throws -> Void)

    static func requestRoundTrip() throws {
        let request = CommandRequest(
            id: "request-1",
            command: .visit,
            session: "qa",
            parameters: ["url": .string("http://localhost:3000/dashboard")]
        )
        let data = try ProtocolCodec.encodeLine(request)
        try expect(try ProtocolCodec.decodeLine(CommandRequest.self, from: data) == request, "request should round-trip")
    }

    static func rejectsUnsafeNavigationSchemes() throws {
        for value in [
            "file:///etc/passwd", "javascript:alert(1)", "mailto:test@example.com",
            "https://user:password@example.com",
        ] {
            try expectThrows("expected \(value) to be rejected") {
                _ = try normalizedWebURL(value)
            }
        }
    }

    static func normalizesLocalhostToHTTP() throws {
        try expect(
            try normalizedWebURL("localhost:3000/designers/dashboard").absoluteString
                == "http://localhost:3000/designers/dashboard",
            "localhost should default to HTTP"
        )
        try expect(
            try normalizedWebURL("localhost.evil.example/path").absoluteString
                == "https://localhost.evil.example/path",
            "a localhost-looking public hostname must not be downgraded to HTTP"
        )
    }

    static func pageNavigationBoundary() throws {
        try expect(
            agentMayNavigate(to: URL(string: "https://example.com/dashboard")!),
            "ordinary HTTPS navigation should be allowed"
        )
        try expect(
            !agentMayNavigate(to: URL(string: "https://user:secret@example.com/private")!),
            "credential-bearing page navigation should be rejected"
        )
        try expect(
            !agentMayNavigate(to: URL(string: "data:text/html,unsafe")!),
            "non-web page navigation should be rejected"
        )
        try expect(
            !agentMayNavigate(to: URL(string: "https://example.com/installer.dmg")!),
            "remote installers should be rejected"
        )
        try expect(
            agentMayNavigate(to: URL(string: "https://example.com/walkthrough.mp4")!),
            "normal web media should remain allowed"
        )
        try expect(
            remoteResourceSafety(for: URL(string: "https://example.com/archive.zip")!) == .caution,
            "archives should be visible as caution resources"
        )
        try expectThrows("remote installers should fail explicit visits") {
            _ = try normalizedWebURL("https://example.com/installer.dmg")
        }
    }

    static func messageSizeLimit() throws {
        let exactPayload = String(repeating: "a", count: headlessMaximumMessageBytes - 3)
        let exactLine = try ProtocolCodec.encodeLine(exactPayload)
        try expect(exactLine.count == headlessMaximumMessageBytes, "framed message should fit the exact limit")
        try expect(
            try ProtocolCodec.decodeLine(String.self, from: exactLine) == exactPayload,
            "an exact-limit framed message should round-trip"
        )
        try expectThrows("encoding beyond the framed limit should be rejected") {
            _ = try ProtocolCodec.encodeLine(String(repeating: "a", count: headlessMaximumMessageBytes - 2))
        }
        let data = Data(repeating: 0x61, count: headlessMaximumMessageBytes + 1)
        try expectThrows("oversized messages should be rejected") {
            _ = try ProtocolCodec.decodeLine(CommandRequest.self, from: data)
        }
    }

    static func rejectsUnexpectedRequestFields() throws {
        let valid = Data(#"{"id":"request-1","version":"0.5","command":"ping","parameters":{}}"#.utf8)
        let decoded = try ProtocolCodec.decodeLine(CommandRequest.self, from: valid)
        try expect(decoded.command == .ping, "the strict-field control request should decode")

        let data = Data(#"{"id":"request-1","version":"0.5","command":"ping","parameters":{},"execute":"anything"}"#.utf8)
        try expectThrows("unexpected top-level request fields should be rejected") {
            _ = try ProtocolCodec.decodeLine(CommandRequest.self, from: data)
        }
    }

    static func identifierValidation() throws {
        try validateIdentifier("qa-session_1", field: "session")
        try expectThrows("path traversal identifier should be rejected") {
            try validateIdentifier("../other-user", field: "session")
        }
        try expectThrows("long identifier should be rejected") {
            try validateIdentifier(String(repeating: "a", count: 65), field: "session")
        }
    }

    static func commandParameterValidation() throws {
        try CommandRequest(
            id: "valid-scroll", command: .scroll,
            parameters: ["direction": .string("down"), "amount": .number(500)]
        ).validate()
        try expectThrows("unknown command parameters should be rejected") {
            try CommandRequest(
                id: "unknown-param", command: .ping,
                parameters: ["execute": .string("anything")]
            ).validate()
        }
        try expectThrows("invalid scroll direction should be rejected") {
            try CommandRequest(
                id: "invalid-scroll", command: .scroll,
                parameters: ["direction": .string("sideways")]
            ).validate()
        }
        try expectThrows("non-numeric element refs should be rejected") {
            try CommandRequest(
                id: "invalid-ref", command: .click,
                parameters: ["target": .string("@e../1")]
            ).validate()
        }
        try expectThrows("screenshot traversal should be rejected") {
            try CommandRequest(
                id: "bad-output", command: .screenshot,
                parameters: ["output": .string("../report.png")]
            ).validate()
        }
        try expectThrows("full-page and element screenshots should conflict") {
            try CommandRequest(
                id: "conflicting-screenshot", command: .screenshot,
                parameters: ["fullPage": .bool(true), "target": .string("@e1")]
            ).validate()
        }
        try CommandRequest(
            id: "valid-screenshot-series", command: .screenshot,
            parameters: ["series": .string("viewport"), "outputPrefix": .string("dashboard-scroll")]
        ).validate()
        try CommandRequest(
            id: "valid-jpeg-screenshot", command: .screenshot,
            parameters: ["format": .string("jpeg"), "output": .string("dashboard.jpeg")]
        ).validate()
        try CommandRequest(
            id: "valid-pdf-screenshot", command: .screenshot,
            parameters: [
                "format": .string("pdf"), "fullPage": .bool(true),
                "output": .string("dashboard.pdf"),
            ]
        ).validate()
        try expectThrows("PDF screenshots should require full-page mode") {
            try CommandRequest(
                id: "bad-viewport-pdf", command: .screenshot,
                parameters: ["format": .string("pdf"), "output": .string("dashboard.pdf")]
            ).validate()
        }
        try expectThrows("PDF screenshots should reject element targets consistently") {
            try CommandRequest(
                id: "bad-target-pdf", command: .screenshot,
                parameters: [
                    "format": .string("pdf"), "fullPage": .bool(true),
                    "target": .string("@e1"), "output": .string("element.pdf"),
                ]
            ).validate()
        }
        try expectThrows("invalid screenshot series should be rejected") {
            try CommandRequest(
                id: "bad-screenshot-series", command: .screenshot,
                parameters: ["series": .string("footer")]
            ).validate()
        }
        try expectThrows("screenshot series should reject path prefixes") {
            try CommandRequest(
                id: "bad-screenshot-prefix", command: .screenshot,
                parameters: ["series": .string("section"), "outputPrefix": .string("../sections")]
            ).validate()
        }
        try expectThrows("output prefixes without a screenshot series should be rejected") {
            try CommandRequest(
                id: "unused-screenshot-prefix", command: .screenshot,
                parameters: ["outputPrefix": .string("ignored")]
            ).validate()
        }
        try expectThrows("screenshot series should not combine with a single output") {
            try CommandRequest(
                id: "bad-screenshot-series-output", command: .screenshot,
                parameters: ["series": .string("viewport"), "output": .string("one.png")]
            ).validate()
        }
        try expectThrows("screenshot series should reject PDF") {
            try CommandRequest(
                id: "bad-screenshot-series-pdf", command: .screenshot,
                parameters: ["series": .string("viewport"), "format": .string("pdf")]
            ).validate()
        }
        try expectThrows("screenshot series should reject clipboard") {
            try CommandRequest(
                id: "bad-screenshot-series-clipboard", command: .screenshot,
                parameters: ["series": .string("section"), "clipboard": .bool(true)]
            ).validate()
        }
        try expectThrows("screenshot output extension should match format") {
            try CommandRequest(
                id: "bad-screenshot-format-extension", command: .screenshot,
                parameters: ["format": .string("pdf"), "output": .string("dashboard.png")]
            ).validate()
        }
        try CommandRequest(
            id: "valid-webm-recording", command: .recordStart,
            parameters: ["format": .string("webm"), "quality": .string("high"), "output": .string("flow.webm")]
        ).validate()
        try expectThrows("recording output extension should match start format") {
            try CommandRequest(
                id: "bad-recording-format-extension", command: .recordStart,
                parameters: ["format": .string("mov"), "output": .string("flow.mp4")]
            ).validate()
        }
        try CommandRequest(
            id: "valid-inspect-context", command: .inspect,
            parameters: [
                "context": .string("text"), "task": .string("search open ai"),
                "within": .string("@r12"), "limit": .number(8),
                "budget": .number(900), "depth": .number(2),
            ]
        ).validate()
        try expectThrows("invalid inspect context should be rejected") {
            try CommandRequest(
                id: "bad-inspect-context", command: .inspect,
                parameters: ["context": .string("debug")]
            ).validate()
        }
        try expectThrows("inspect task should remain bounded") {
            try CommandRequest(
                id: "long-inspect-task", command: .inspect,
                parameters: ["task": .string(String(repeating: "x", count: 513))]
            ).validate()
        }
        try expectThrows("invalid inspect region refs should be rejected") {
            try CommandRequest(
                id: "bad-inspect-region", command: .inspect,
                parameters: ["within": .string("@e1")]
            ).validate()
        }
        try expectThrows("inspect item limit should remain bounded") {
            try CommandRequest(
                id: "large-inspect-limit", command: .inspect,
                parameters: ["limit": .number(251)]
            ).validate()
        }
        try expectThrows("inspect token budget should retain a useful minimum") {
            try CommandRequest(
                id: "small-inspect-budget", command: .inspect,
                parameters: ["budget": .number(128)]
            ).validate()
        }
        try expectThrows("raw inspect limits should reject fractional values") {
            try CommandRequest(
                id: "fractional-inspect-limit", command: .inspect,
                parameters: ["limit": .number(1.5)]
            ).validate()
        }
    }

    static func cliVisit() throws {
        let invocation = try CLIParser().parse([
            "--session", "qa", "visit", "localhost:3000/designers/dashboard", "--json",
        ])
        try expect(invocation.jsonOutput, "--json should be retained")
        try expect(invocation.request?.command == .visit, "visit command should parse")
        try expect(invocation.request?.session == "qa", "session should parse")
        try expect(
            invocation.request?.parameters["url"] == .string("http://localhost:3000/designers/dashboard"),
            "visit URL should normalize"
        )
        try expect(!agentHelp.contains("--json"), "the no-op --json compatibility flag should stay out of help")
    }

    static func cliFillPreservesLiteralValue() throws {
        let value = "pass  --json\tto API"
        let invocation = try CLIParser().parse([
            "--session", "qa", "--json", "fill", "@e1", "--", value,
        ])
        try expect(invocation.jsonOutput, "global --json before the sentinel should parse")
        try expect(invocation.request?.session == "qa", "global --session before the sentinel should parse")
        try expect(invocation.request?.parameters["target"] == .string("@e1"), "fill target should parse")
        try expect(invocation.request?.parameters["value"] == .string(value), "fill text should preserve whitespace and literal flags")

        let literalFlag = try CLIParser().parse(["fill", "@e1", "--", "--json"])
        try expect(!literalFlag.jsonOutput, "--json after the sentinel should not become a global option")
        try expect(literalFlag.request?.parameters["value"] == .string("--json"), "a literal --json fill value should survive")

        let literalSession = try CLIParser().parse(["fill", "@e1", "--", "--session"])
        try expect(literalSession.request?.session == nil, "--session after the sentinel should not become a global option")
        try expect(literalSession.request?.parameters["value"] == .string("--session"), "a literal --session fill value should survive")

        try expectThrows("multi-word fill text must stay one shell argument") {
            _ = try CLIParser().parse(["fill", "@e1", "two", "words"])
        }
    }

    static func cliSemanticClick() throws {
        let invocation = try CLIParser().parse(["click", "--role", "button", "--name", "Continue"])
        try expect(
            invocation.request?.parameters == ["role": .string("button"), "name": .string("Continue")],
            "semantic target should parse"
        )
    }

    static func cliInspectContextAndTask() throws {
        let invocation = try CLIParser().parse([
            "inspect", "--context", "text", "--task", "search open ai",
            "--within", "@r4", "--limit", "6", "--budget", "800", "--depth", "2",
        ])
        try expect(invocation.request?.command == .inspect, "inspect command should parse")
        try expect(invocation.request?.parameters["context"] == .string("text"), "inspect context should parse")
        try expect(invocation.request?.parameters["interactive"] == .bool(false), "text context should not imply interactive output")
        try expect(invocation.request?.parameters["task"] == .string("search open ai"), "inspect task should parse")
        try expect(invocation.request?.parameters["within"] == .string("@r4"), "inspect region should parse")
        try expect(invocation.request?.parameters["limit"] == .number(6), "inspect limit should parse")
        try expect(invocation.request?.parameters["budget"] == .number(800), "inspect budget should parse")
        try expect(invocation.request?.parameters["depth"] == .number(2), "inspect depth should parse")
        try expectThrows("invalid inspect context should fail in the CLI") {
            _ = try CLIParser().parse(["inspect", "--context", "debug"])
        }
        try expectThrows("invalid inspect region should fail in the CLI") {
            _ = try CLIParser().parse(["inspect", "--within", "@e2"])
        }
        try expectThrows("fractional inspect limits should fail in the CLI") {
            _ = try CLIParser().parse(["inspect", "--limit", "1.5"])
        }
    }

    static func cliRejectsConflictingClickTarget() throws {
        try expectThrows("conflicting click targets should fail") {
            _ = try CLIParser().parse([
                "click", "@e12", "--role", "button", "--name", "Continue",
            ])
        }
    }

    static func cliWaitDefaultsToSettled() throws {
        let invocation = try CLIParser().parse(["wait"])
        try expect(invocation.request?.parameters["settled"] == .bool(true), "wait should default to settled")
    }

    static func cliRejectsUnboundedTimeout() throws {
        try expectThrows("unbounded timeout should fail") {
            _ = try CLIParser().parse(["wait", "--timeout", "9999999"])
        }
    }

    static func clientTimeoutsMatchCommandBounds() throws {
        let longWait = try CLIParser().parse(["wait", "--timeout", "90000"])
        try expect(
            longWait.request.map { requestTimeout(for: $0) } == 95,
            "wait timeout should include the five-second transport allowance"
        )
        let maximumWait = try CLIParser().parse(["wait", "--timeout", "120000"])
        try expect(maximumWait.request.map { requestTimeout(for: $0) } == 125, "wait timeout should remain capped")
        let shortWait = try CLIParser().parse(["wait", "--timeout", "100"])
        try expect(shortWait.request.map { requestTimeout(for: $0) } == 10, "wait timeout should retain the transport minimum")

        try expect(requestTimeout(for: CommandRequest(command: .tour)) == 125, "tour should use the long timeout")
        try expect(requestTimeout(for: CommandRequest(command: .flowRun)) == 125, "flow replay should use the long timeout")
        try expect(
            requestTimeout(for: CommandRequest(command: .screenshot, parameters: ["series": .string("viewport")])) == 125,
            "screenshot series should use the long timeout"
        )
        try expect(requestTimeout(for: CommandRequest(command: .screenshot)) == 30, "single screenshots should get 30 seconds")
        try expect(requestTimeout(for: CommandRequest(command: .recordStop)) == 30, "record stop should get 30 seconds")
        try expect(requestTimeout(for: CommandRequest(command: .ping)) == 15, "ordinary commands should use the shared default")
    }

    static func cliP1Artifacts() throws {
        let screenshot = try CLIParser().parse([
            "--session", "qa", "screenshot", "--role", "button", "--name", "Continue",
            "--output", "continue.png",
        ])
        try expect(screenshot.request?.command == .screenshot, "screenshot command should parse")
        try expect(screenshot.request?.parameters["output"] == .string("continue.png"), "screenshot output should parse")
        let jpegScreenshot = try CLIParser().parse([
            "screenshot", "--format", "jpeg", "--output", "continue.jpeg", "--clipboard",
        ])
        try expect(jpegScreenshot.request?.parameters["format"] == .string("jpeg"), "screenshot format should parse")
        try expect(jpegScreenshot.request?.parameters["clipboard"] == .bool(true), "screenshot clipboard should parse")
        let pdfScreenshot = try CLIParser().parse([
            "screenshot", "--format", "pdf", "--full-page", "--output", "page.pdf",
        ])
        try expect(pdfScreenshot.request?.parameters["fullPage"] == .bool(true), "PDF should parse in full-page mode")
        try expectThrows("viewport PDF should fail in the CLI") {
            _ = try CLIParser().parse(["screenshot", "--format", "pdf", "--output", "page.pdf"])
        }
        try expectThrows("element PDF should fail in the CLI") {
            _ = try CLIParser().parse(["screenshot", "@e1", "--format", "pdf", "--full-page"])
        }
        let viewportSeries = try CLIParser().parse([
            "screenshot", "--every-viewport", "--format", "jpg", "--output", "dashboard-scroll",
        ])
        try expect(viewportSeries.request?.command == .screenshot, "viewport screenshot series should parse")
        try expect(viewportSeries.request?.parameters["series"] == .string("viewport"), "viewport series should parse")
        try expect(viewportSeries.request?.parameters["format"] == .string("jpeg"), "viewport series format should parse")
        try expect(viewportSeries.request?.parameters["outputPrefix"] == .string("dashboard-scroll"), "series prefix should parse")
        let sectionSeries = try CLIParser().parse([
            "screenshot", "--by-section", "--output", "dashboard-sections.jpeg",
        ])
        try expect(sectionSeries.request?.parameters["series"] == .string("section"), "section series should parse")
        try expect(sectionSeries.request?.parameters["outputPrefix"] == .string("dashboard-sections"), "series prefix should strip image extension")
        try expectThrows("series screenshot must reject element targets") {
            _ = try CLIParser().parse(["screenshot", "--every-viewport", "@e1"])
        }
        try expectThrows("series screenshot must reject full-page mode") {
            _ = try CLIParser().parse(["screenshot", "--by-section", "--full-page"])
        }
        try expectThrows("series screenshot must reject PDF") {
            _ = try CLIParser().parse(["screenshot", "--by-section", "--format", "pdf"])
        }
        try expectThrows("series screenshot must reject clipboard") {
            _ = try CLIParser().parse(["screenshot", "--every-viewport", "--clipboard"])
        }
        let record = try CLIParser().parse([
            "record", "start", "--fps", "8", "--format", "webm", "--quality", "high", "--output", "flow.webm",
        ])
        try expect(record.request?.command == .recordStart, "record start should parse")
        try expect(record.request?.parameters["fps"] == .number(8), "record FPS should parse")
        try expect(record.request?.parameters["format"] == .string("webm"), "recording format should parse")
        try expect(record.request?.parameters["quality"] == .string("high"), "recording quality should parse")
        try expectThrows("unsupported recorder selectors should fail instead of being ignored") {
            _ = try CLIParser().parse(["record", "start", "--provider", "browser"])
        }
        try expectThrows("recording output mismatch should fail") {
            _ = try CLIParser().parse(["record", "start", "--format", "mov", "--output", "flow.mp4"])
        }
        try expectThrows("record requests should reject obsolete provider fields") {
            try CommandRequest(command: .recordStart, parameters: ["provider": .string("browser")]).validate()
        }
        try expectThrows("artifact path traversal should fail in the CLI") {
            _ = try CLIParser().parse(["screenshot", "--output", "../escape.png"])
        }
    }

    static func cliP2CommandsAndBoundaries() throws {
        let visual = try CLIParser().parse(["visual", "compare", "before.png", "after.png", "--output", "diff.png"])
        try expect(visual.request?.command == .visualCompare, "visual compare should parse")
        // Both hosts read these two names to locate the artifacts to diff. They
        // guard the lookup and answer MISSING_PARAMETER, but the validator is
        // what keeps a malformed request from reaching that path at all — if it
        // ever stopped requiring them, the guards would be the only thing
        // standing between a crafted request and a broken comparison.
        for missing in ["before", "after"] {
            try expectThrows("visual compare should require \(missing)") {
                var parameters: [String: JSONValue] = [
                    "before": .string("one.png"), "after": .string("two.png"),
                ]
                parameters.removeValue(forKey: missing)
                try CommandRequest(
                    id: "visual-compare-missing-\(missing)", command: .visualCompare,
                    parameters: parameters
                ).validate()
            }
        }
        try expect(visual.request?.parameters["before"] == .string("before.png"), "visual input should remain an artifact name")
        let flow = try CLIParser().parse(["flow", "run", "happy-path.json"])
        try expect(flow.request?.command == .flowRun, "flow run should parse")
        let mock = try CLIParser().parse(["network", "mock", "set", "localhost:3000/api", "--body", "{}", "--status", "201"])
        try expect(mock.request?.command == .networkMockSet, "network mock should parse")
        try expectThrows("visual compare must reject traversal") {
            _ = try CLIParser().parse(["visual", "compare", "../before.png", "after.png"])
        }
        try expectThrows("network mock body must remain bounded") {
            try CommandRequest(command: .networkMockSet, parameters: [
                "url": .string("https://example.com/api"), "body": .string(String(repeating: "x", count: 65_537)),
            ]).validate()
        }
        try expectThrows("network mock content type must not contain header control characters") {
            try CommandRequest(command: .networkMockSet, parameters: [
                "url": .string("https://example.com/api"), "body": .string("{}"),
                "contentType": .string("application/json\r\nX-Injected: yes"),
            ]).validate()
        }
    }

    static func cliCommandMatrix() throws {
        let remoteCommands: [([String], CommandName)] = [
            (["status"], .ping),
            (["stop"], .shutdown),
            (["session", "create", "qa"], .sessionCreate),
            (["session", "list"], .sessionList),
            (["session", "close", "qa"], .sessionClose),
            (["back"], .back),
            (["reload"], .reload),
            (["tour", "--pace", "750"], .tour),
            (["capture-info"], .captureInfo),
            (["artifacts", "list"], .artifactList),
            (["qa", "report"], .qaReport),
            (["qa", "clear"], .qaClear),
            (["performance", "get"], .performanceGet),
            (["animations", "list"], .animationList),
            (["report", "create", "--output", "report.json"], .reportCreate),
            (["flow", "start"], .flowStart),
            (["flow", "stop", "--output", "flow.json"], .flowStop),
            (["network", "emulate", "--offline", "--latency", "100"], .networkEmulate),
            (["network", "mock", "clear"], .networkMockClear),
        ]
        for (arguments, command) in remoteCommands {
            let invocation = try CLIParser().parse(arguments)
            try expect(
                invocation.request?.command == command,
                "\(arguments.joined(separator: " ")) should parse as \(command.rawValue)"
            )
        }

        let localCommands: [([String], LocalCommand)] = [
            (["start"], .start),
            (["help"], .help),
            (["--help"], .help),
        ]
        for (arguments, command) in localCommands {
            let invocation = try CLIParser().parse(arguments)
            try expect(
                invocation.local == command && invocation.request == nil,
                "\(arguments.joined(separator: " ")) should stay local"
            )
        }

        let sessionCreate = try CLIParser().parse(["session", "create", "qa"])
        try expect(sessionCreate.request?.parameters["name"] == .string("qa"), "session create name should parse")
        let sessionClose = try CLIParser().parse(["session", "close", "qa"])
        try expect(sessionClose.request?.session == "qa", "session close target should parse")
        let tour = try CLIParser().parse(["tour", "--pace", "750"])
        try expect(tour.request?.parameters["pace"] == .number(750), "tour pace should parse")
        let emulation = try CLIParser().parse([
            "network", "emulate", "--offline", "--latency", "100",
            "--download-kbps", "2000", "--upload-kbps", "500",
        ])
        try expect(emulation.request?.parameters["offline"] == .bool(true), "offline emulation should parse")
        try expect(emulation.request?.parameters["latencyMs"] == .number(100), "emulation latency should parse")
        try expectThrows("unknown trailing arguments should not be ignored") {
            _ = try CLIParser().parse(["performance", "get", "extra"])
        }
    }

    static func chromiumRuntimeSelection() throws {
        let runtimeInvocation = try CLIParser().parse(["runtime"])
        try expect(runtimeInvocation.local == .runtime, "runtime diagnostics command should parse")

        let root = "/tmp/headless-runtime-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let bundled = root + "/lib/headless/chromium/chromium"
        let system = root + "/system/chromium"
        let overrideLink = root + "/override-chromium"
        let snapWrapper = root + "/chromium-browser"
        try FileManager.default.createDirectory(
            atPath: (bundled as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: (system as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("bundled".utf8).write(to: URL(fileURLWithPath: bundled))
        try Data("system".utf8).write(to: URL(fileURLWithPath: system))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: system)
        try FileManager.default.createSymbolicLink(atPath: overrideLink, withDestinationPath: system)
        try Data("#!/bin/sh\nexec /snap/bin/chromium \"$@\"\n".utf8)
            .write(to: URL(fileURLWithPath: snapWrapper))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snapWrapper)

        let bundledSelection = try ChromiumRuntimeResolver(
            environment: [:], hostExecutablePath: root + "/bin/headless-host",
            systemCandidates: [system]
        ).resolve()
        try expect(bundledSelection.source == .bundled, "bundled Chromium should be preferred")
        try expect(bundledSelection.executableURL.path == bundled, "bundled Chromium path should be selected")

        let overrideSelection = try ChromiumRuntimeResolver(
            environment: ["HEADLESS_CHROMIUM_EXECUTABLE": overrideLink],
            hostExecutablePath: root + "/bin/headless-host", systemCandidates: [bundled]
        ).resolve()
        try expect(overrideSelection.source == .override, "a valid explicit override should be authoritative")
        try expect(overrideSelection.executableURL.path == system, "override symlinks should resolve to a regular executable")

        try expectThrows("a missing override must not fall through to a supported default") {
            _ = try ChromiumRuntimeResolver(
                environment: ["HEADLESS_CHROMIUM_EXECUTABLE": root + "/missing"],
                hostExecutablePath: root + "/bin/headless-host", systemCandidates: [system]
            ).resolve()
        }
        try expectThrows("relative Chromium overrides should be rejected") {
            _ = try ChromiumRuntimeResolver(
                environment: ["HEADLESS_CHROMIUM_EXECUTABLE": "relative/chromium"],
                hostExecutablePath: root + "/bin/headless-host", systemCandidates: [system]
            ).resolve()
        }
        try expectThrows("Snap Chromium overrides should be rejected before launch") {
            _ = try ChromiumRuntimeResolver(
                environment: ["HEADLESS_CHROMIUM_EXECUTABLE": "/snap/bin/chromium"],
                hostExecutablePath: root + "/bin/headless-host", systemCandidates: [system]
            ).resolve()
        }
        try expectThrows("scripts that delegate to Snap Chromium should be rejected") {
            _ = try ChromiumRuntimeResolver(
                environment: ["HEADLESS_CHROMIUM_EXECUTABLE": snapWrapper],
                hostExecutablePath: root + "/bin/headless-host", systemCandidates: [system]
            ).resolve()
        }

        let nativeAfterSnap = try ChromiumRuntimeResolver(
            environment: [:], hostExecutablePath: root + "/unbundled/bin/headless-host",
            systemCandidates: ["/snap/bin/chromium", system]
        ).resolve()
        try expect(nativeAfterSnap.executableURL.path == system, "automatic selection should skip Snap for a native runtime")
    }

    static func artifactStoreRoundTrip() throws {
        let root = "/tmp/headless-artifact-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try ArtifactStore(environment: ["HEADLESS_ARTIFACT_DIR": root])
        let artifact = try store.write(
            Data([0x89, 0x50, 0x4e, 0x47]), requestedName: "sample.png",
            extension: "png", prefix: "unused"
        )
        guard case .object(let metadata) = artifact else { throw TestFailure(description: "artifact metadata") }
        try expect(metadata["name"] == .string("sample.png"), "artifact name should be returned")
        guard case .object(let listing) = try store.list(), case .array(let artifacts)? = listing["artifacts"] else {
            throw TestFailure(description: "artifact listing")
        }
        try expect(artifacts.count == 1, "artifact listing should include the write")
        let rootMode = (try FileManager.default.attributesOfItem(atPath: root)[.posixPermissions] as? NSNumber)?.intValue
        let artifactMode = (try FileManager.default.attributesOfItem(atPath: root + "/sample.png")[.posixPermissions] as? NSNumber)?.intValue
        try expect(rootMode == 0o700, "artifact root should be private")
        try expect(artifactMode == 0o600, "artifact file should be private from creation")
        let recording = try store.reserve(
            requestedName: "recording.mp4", extension: "mp4", prefix: "unused"
        )
        let recordingMode = (try FileManager.default.attributesOfItem(atPath: recording.path)[.posixPermissions] as? NSNumber)?.intValue
        try expect(recordingMode == 0o600, "reserved recording should be private")
        _ = try store.writeReserved(Data("recording".utf8), to: recording)
        let finalized = try store.finalize(recording, renameTo: "final-recording.mp4")
        guard case .object(let finalizedMetadata) = finalized else {
            throw TestFailure(description: "finalized artifact metadata")
        }
        try expect(finalizedMetadata["name"] == .string("final-recording.mp4"), "artifact rename should return its final name")
        try expect(!FileManager.default.fileExists(atPath: recording.path), "artifact rename should remove its reserved source name")

        let collisionSource = try store.reserve(
            requestedName: "collision-source.mp4", extension: "mp4", prefix: "unused"
        )
        _ = try store.writeReserved(Data("source".utf8), to: collisionSource)
        _ = try store.write(
            Data("destination".utf8), requestedName: "collision.mp4",
            extension: "mp4", prefix: "unused"
        )
        try expectThrows("artifact finalization must never replace an existing destination") {
            _ = try store.finalize(collisionSource, renameTo: "collision.mp4")
        }
        try expect(
            try Data(contentsOf: URL(fileURLWithPath: root + "/collision.mp4")) == Data("destination".utf8),
            "artifact collision should preserve the existing destination"
        )
        try expect(FileManager.default.fileExists(atPath: collisionSource.path), "failed finalization should preserve its source")
        try expectThrows("artifact overwrite should be rejected") {
            _ = try store.write(Data(), requestedName: "sample.png", extension: "png", prefix: "unused")
        }
        let symlinkTarget = root + "-target"
        let symlinkRoot = root + "-link"
        defer {
            try? FileManager.default.removeItem(atPath: symlinkRoot)
            try? FileManager.default.removeItem(atPath: symlinkTarget)
        }
        try FileManager.default.createDirectory(atPath: symlinkTarget, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: symlinkRoot, withDestinationPath: symlinkTarget)
        try expectThrows("artifact root symlinks should be rejected") {
            _ = try ArtifactStore(environment: ["HEADLESS_ARTIFACT_DIR": symlinkRoot])
        }
    }

    static func artifactReadsStayInsideBounds() throws {
        let root = "/tmp/headless-artifact-read-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try ArtifactStore(environment: ["HEADLESS_ARTIFACT_DIR": root])
        let payload = Data("bounded artifact".utf8)
        _ = try store.write(
            payload, requestedName: "bounded.json", extension: "json", prefix: "unused"
        )
        try expect(
            try store.read(name: "bounded.json", expectedExtension: "json", maximumBytes: payload.count) == payload,
            "an exact-bound regular artifact should be readable"
        )
        try expectThrows("artifacts larger than the caller's bound should be rejected") {
            _ = try store.read(name: "bounded.json", expectedExtension: "json", maximumBytes: payload.count - 1)
        }
        try expectThrows("artifact reads should validate the expected extension") {
            _ = try store.read(name: "bounded.json", expectedExtension: "png", maximumBytes: payload.count)
        }

        let outside = root + "-outside.json"
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try payload.write(to: URL(fileURLWithPath: outside))
        try FileManager.default.createSymbolicLink(
            atPath: root + "/linked.json", withDestinationPath: outside
        )
        try expectThrows("artifact reads should reject symbolic links") {
            _ = try store.read(name: "linked.json", expectedExtension: "json", maximumBytes: payload.count)
        }

        try FileManager.default.createDirectory(atPath: root + "/folder.json", withIntermediateDirectories: false)
        try expectThrows("artifact reads should reject non-regular files") {
            _ = try store.read(name: "folder.json", expectedExtension: "json", maximumBytes: payload.count)
        }
    }

    static func flowRecordingOmitsSensitiveCommands() throws {
        let safeParameters: [String: JSONValue] = ["target": .string("@e1")]
        for command in replayableFlowCommands {
            let step = flowStepIfSafe(command: command, parameters: safeParameters)
            try expect(step?.command == command, "\(command.rawValue) should remain replayable")
            try expect(step?.parameters == safeParameters, "safe flow parameters should be retained")
        }

        let secret = "never-record-this-value"
        let fill = flowStepIfSafe(
            command: .fill,
            parameters: ["target": .string("@e1"), "value": .string(secret)]
        )
        try expect(fill == nil, "fill values must never become replayable flow steps")
        for command in [CommandName.shutdown, .sessionClose, .cookiesList, .storageList] {
            try expect(
                flowStepIfSafe(command: command, parameters: [:]) == nil,
                "\(command.rawValue) should not be replayable"
            )
        }

        let commands = replayableFlowCommands.compactMap {
            flowStepIfSafe(command: $0, parameters: safeParameters)
        }
        let encoded = try ProtocolCodec.encoder.encode(RecordedFlow(commands: commands))
        try expect(!String(decoding: encoded, as: UTF8.self).contains(secret), "serialized flows must omit fill values")
    }

    static func visualComparisonInvokesBoundedTool() throws {
        let root = "/tmp/headless-visual-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        let executable = root + "/ffmpeg"
        let script = """
        #!/bin/sh
        set -eu
        last=''
        for argument in "$@"; do last="$argument"; done
        printf '%s\n' "$@" > "$last"
        """
        try script.write(toFile: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)

        let previous = ProcessInfo.processInfo.environment["HEADLESS_FFMPEG_EXECUTABLE"]
        setenv("HEADLESS_FFMPEG_EXECUTABLE", executable, 1)
        defer {
            if let previous { setenv("HEADLESS_FFMPEG_EXECUTABLE", previous, 1) }
            else { unsetenv("HEADLESS_FFMPEG_EXECUTABLE") }
        }

        let before = URL(fileURLWithPath: root + "/before.png")
        let after = URL(fileURLWithPath: root + "/after.png")
        let difference = URL(fileURLWithPath: root + "/difference.png")
        try Data([0x01]).write(to: before)
        try Data([0x02]).write(to: after)
        let result = try VisualComparison.compare(before: before, after: after, difference: difference)
        guard case .object(let metadata) = result else {
            throw TestFailure(description: "visual comparison metadata")
        }
        try expect(metadata["differenceGenerated"] == .bool(true), "visual comparison should report success")
        let arguments = try String(contentsOf: difference, encoding: .utf8)
        try expect(arguments.contains(before.path), "visual comparison should pass the before artifact")
        try expect(arguments.contains(after.path), "visual comparison should pass the after artifact")
        try expect(arguments.contains("blend=all_mode=difference"), "visual comparison should use difference blending")
        try expect(arguments.contains("-frames:v\n1"), "visual comparison should remain bounded to one output frame")

        let failingExecutable = root + "/ffmpeg-fail"
        try "#!/bin/sh\necho deliberate-failure >&2\nexit 7\n".write(
            toFile: failingExecutable, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failingExecutable)
        setenv("HEADLESS_FFMPEG_EXECUTABLE", failingExecutable, 1)
        try expectThrows("visual comparison should surface encoder failure") {
            _ = try VisualComparison.compare(before: before, after: after, difference: difference)
        }
    }

    static func recordingArgumentsAndFailureBounds() throws {
        let root = "/tmp/headless-recording-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        let executable = root + "/ffmpeg"
        let script = """
        #!/bin/sh
        set -eu
        last=''
        for argument in "$@"; do last="$argument"; done
        printf '%s\n' "$@" > "$last.arguments"
        case "$last" in
          *exit-early*) dd bs=1 count=1 of=/dev/null 2>/dev/null; : > "$last"; exit 0 ;;
        esac
        cat >/dev/null
        : > "$last"
        """
        try script.write(toFile: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)

        let nonExecutable = root + "/not-executable"
        try "not executable".write(toFile: nonExecutable, atomically: true, encoding: .utf8)
        try expect(
            BrowserRecording.ffmpegExecutable(
                environment: ["HEADLESS_FFMPEG_EXECUTABLE": "relative/ffmpeg"],
                systemCandidates: []
            ) == nil,
            "relative ffmpeg overrides should be rejected"
        )
        try expect(
            BrowserRecording.ffmpegExecutable(
                environment: ["HEADLESS_FFMPEG_EXECUTABLE": root], systemCandidates: []
            ) == nil,
            "ffmpeg directories should be rejected"
        )
        try expect(
            BrowserRecording.ffmpegExecutable(
                environment: ["HEADLESS_FFMPEG_EXECUTABLE": nonExecutable], systemCandidates: []
            ) == nil,
            "non-executable ffmpeg files should be rejected"
        )
        let resolved = BrowserRecording.ffmpegExecutable(
            environment: ["HEADLESS_FFMPEG_EXECUTABLE": executable], systemCandidates: []
        )
        try expect(resolved?.path == executable, "a regular absolute ffmpeg override should resolve")

        let previous = ProcessInfo.processInfo.environment["HEADLESS_FFMPEG_EXECUTABLE"]
        setenv("HEADLESS_FFMPEG_EXECUTABLE", executable, 1)
        defer {
            if let previous { setenv("HEADLESS_FFMPEG_EXECUTABLE", previous, 1) }
            else { unsetenv("HEADLESS_FFMPEG_EXECUTABLE") }
        }

        func argument(after flag: String, in arguments: [String]) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        enum SyntheticInitialCaptureFailure: Error { case unavailable }
        var initialCaptureAttempts = 0
        do {
            _ = try BrowserRecording(
                outputURL: URL(fileURLWithPath: root + "/initial-failure.mp4"), fps: 8,
                captureFrame: {
                    initialCaptureAttempts += 1
                    throw SyntheticInitialCaptureFailure.unavailable
                }
            )
            throw TestFailure(description: "an unavailable initial frame should fail recording startup")
        } catch RecordingError.captureFailed {
            try expect(
                initialCaptureAttempts == 6,
                "recording startup should use six bounded attempts instead of polling for three seconds"
            )
        }

        let earlyExitRecording = try BrowserRecording(
            outputURL: URL(fileURLWithPath: root + "/exit-early.mp4"), fps: 4,
            captureFrame: { Data([0x01, 0x02, 0x03, 0x04]) }
        )
        let earlyExitDeadline = Date().addingTimeInterval(2)
        while Date() < earlyExitDeadline {
            guard case .object(let status) = earlyExitRecording.status(),
                  status["active"] == .bool(true) else { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard case .object(let earlyExitStatus) = earlyExitRecording.status() else {
            throw TestFailure(description: "early-exit recording status")
        }
        try expect(earlyExitStatus["active"] == .bool(false), "encoder termination should update recording status")
        _ = try earlyExitRecording.stop(timeout: 2)

        for format in RecordingFormat.allCases {
            for quality in RecordingQuality.allCases {
                let output = URL(fileURLWithPath: root)
                    .appendingPathComponent("\(format.rawValue)-\(quality.rawValue).\(format.fileExtension)")
                let recording = try BrowserRecording(
                    outputURL: output, fps: 7.5, format: format, quality: quality,
                    captureFrame: { Data([0x89, 0x50, 0x4e, 0x47]) }
                )
                _ = try recording.stop(timeout: 2)
                let text = try String(contentsOfFile: output.path + ".arguments", encoding: .utf8)
                let arguments = text.split(separator: "\n").map(String.init)
                try expect(argument(after: "-f", in: arguments) == "image2pipe", "recording input should be image2pipe")
                try expect(argument(after: "-framerate", in: arguments) == "7.500", "recording FPS should retain precision")
                try expect(arguments.last == output.path, "recording output should be the final ffmpeg argument")
                switch format {
                case .mp4, .mov:
                    let expected = [RecordingQuality.fast: "6", .balanced: "4", .high: "2"][quality]
                    try expect(argument(after: "-c:v", in: arguments) == "mpeg4", "MP4/MOV should use mpeg4")
                    try expect(argument(after: "-q:v", in: arguments) == expected, "MP4/MOV quality mapping changed")
                    try expect(argument(after: "-movflags", in: arguments) == "+faststart", "MP4/MOV should remain streamable")
                case .webm:
                    let expectedCRF = [RecordingQuality.fast: "40", .balanced: "34", .high: "28"][quality]
                    let expectedDeadline = quality == .high ? "good" : "realtime"
                    try expect(argument(after: "-c:v", in: arguments) == "libvpx-vp9", "WebM should use VP9")
                    try expect(argument(after: "-crf", in: arguments) == expectedCRF, "WebM quality mapping changed")
                    try expect(argument(after: "-deadline", in: arguments) == expectedDeadline, "WebM deadline mapping changed")
                case .gif:
                    let expectedScale = [
                        RecordingQuality.fast: "scale=960:-1:flags=lanczos",
                        .balanced: "scale=1280:-1:flags=lanczos",
                        .high: "scale=-1:-1:flags=lanczos",
                    ][quality]
                    let filter = argument(after: "-vf", in: arguments)
                    try expect(filter?.contains("fps=7.500") == true, "GIF filter should retain FPS")
                    try expect(filter?.contains(expectedScale ?? "missing") == true, "GIF quality scale changed")
                    try expect(argument(after: "-loop", in: arguments) == "0", "GIF should loop continuously")
                }
            }
        }

        enum SyntheticCaptureFailure: Error { case unavailable }
        let failureLock = NSLock()
        var failureCalls = 0
        let failedOutput = URL(fileURLWithPath: root + "/capture-failure.mp4")
        let failedRecording = try BrowserRecording(
            outputURL: failedOutput, fps: 4, captureFrame: {
                failureLock.lock(); failureCalls += 1; let call = failureCalls; failureLock.unlock()
                if call == 1 { return Data([0x01]) }
                throw SyntheticCaptureFailure.unavailable
            }
        )
        let failureDeadline = Date().addingTimeInterval(5)
        while Date() < failureDeadline {
            guard case .object(let status) = failedRecording.status() else { break }
            if status["active"] == .bool(false) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard case .object(let failedStatus) = failedRecording.status() else {
            throw TestFailure(description: "failed recording status")
        }
        try expect(failedStatus["active"] == .bool(false), "consecutive capture failures should abort recording")
        try expect(failedStatus["droppedFrames"] == .number(12), "failure threshold should be max(10, fps × 3)")
        do {
            _ = try failedRecording.stop(timeout: 2)
            throw TestFailure(description: "capture failure should surface from stop")
        } catch RecordingError.captureFailed {
            // Expected.
        }

        let loopEntered = DispatchSemaphore(value: 0)
        let timeoutLock = NSLock()
        var timeoutCalls = 0
        let timeoutRecording = try BrowserRecording(
            outputURL: URL(fileURLWithPath: root + "/timeout.mp4"), fps: 1,
            captureFrame: {
                timeoutLock.lock(); timeoutCalls += 1; let call = timeoutCalls; timeoutLock.unlock()
                if call == 2 { loopEntered.signal() }
                return Data([0x01])
            }
        )
        try expect(loopEntered.wait(timeout: .now() + 1) == .success, "capture loop should start")
        do {
            _ = try timeoutRecording.stop(timeout: 0.01)
            throw TestFailure(description: "a bounded stop should report timeout")
        } catch RecordingError.timedOut {
            // Expected.
        }
        Thread.sleep(forTimeInterval: 1.1)
    }

    static func capabilitiesMatchProtocolCommands() throws {
        guard case .object(let document) = capabilitiesDocument,
              case .array(let rawCommands)? = document["commands"],
              case .object(let engines)? = document["engines"],
              case .object(let security)? = document["security"] else {
            throw TestFailure(description: "capabilities document shape")
        }
        let commands = rawCommands.compactMap(\.stringValue)
        let expected = CommandName.allCases.map(\.rawValue)
        try expect(commands.count == expected.count, "capabilities should not omit or duplicate commands")
        try expect(Set(commands) == Set(expected), "capabilities should match CommandName.allCases")
        try expect(
            engines.count == BrowserEngineName.allCases.count,
            "capabilities should contain exactly one profile for every engine"
        )
        for profile in BrowserEngineCapabilities.all {
            guard case .object(let engine)? = engines[profile.engine.rawValue],
                  case .array(let rawSupported)? = engine["commands"],
                  case .array(let rawUnsupported)? = engine["unsupportedCommands"],
                  case .object(let features)? = engine["features"] else {
                throw TestFailure(description: "missing engine capability profile: \(profile.engine.rawValue)")
            }
            let supported = Set(rawSupported.compactMap(\.stringValue))
            let unsupported = Set(rawUnsupported.compactMap(\.stringValue))
            try expect(supported.isDisjoint(with: unsupported), "engine command sets must not overlap")
            try expect(supported.union(unsupported) == Set(expected), "engine command sets must be exhaustive")
            try expect(
                features["tourTimeoutMs"] == .number(65_000),
                "both engine profiles should declare the shared tour timeout"
            )
            try expect(
                features["backWithoutHistory"] == .string("operation-failed"),
                "both engines should fail consistently when back history is empty"
            )
        }
        try expect(
            BrowserEngineCapabilities.webkit.unsupportedCommands
                == [.networkEmulate, .networkMockSet, .networkMockClear],
            "WebKit unsupported commands should be explicit and exact"
        )
        try expect(
            BrowserEngineCapabilities.chromium.unsupportedCommands.isEmpty,
            "Chromium should implement every protocol command"
        )
        try expect(
            document["currentEngine"] == .string(currentBrowserEngineCapabilities.engine.rawValue),
            "capabilities should identify the engine for this binary"
        )
        guard case .array(let screenshotFormats)? = document["screenshotFormats"],
              case .array(let recordingFormats)? = document["recordingFormats"],
              case .array(let recordingQuality)? = document["recordingQuality"] else {
            throw TestFailure(description: "generated capture capability shape")
        }
        try expect(
            Set(screenshotFormats.compactMap(\.stringValue)) == ScreenshotFormat.artifactExtensions,
            "screenshot capabilities should be generated from ScreenshotFormat"
        )
        try expect(
            Set(recordingFormats.compactMap(\.stringValue)) == RecordingFormat.artifactExtensions,
            "recording capabilities should be generated from RecordingFormat"
        )
        try expect(
            Set(recordingQuality.compactMap(\.stringValue)) == Set(RecordingQuality.allCases.map(\.rawValue)),
            "recording quality capabilities should be generated from RecordingQuality"
        )
        try expect(
            security["maximumMessageBytes"] == .number(Double(headlessMaximumMessageBytes)),
            "capabilities should publish the real frame bound"
        )
        try expect(security["tcpListener"] == .bool(false), "capabilities must not advertise TCP control")
        try expect(security["arbitraryJavaScript"] == .bool(false), "capabilities must not advertise arbitrary JavaScript")
    }

    static func oversizedSocketRequestIsRejected() throws {
        try LocalRuntime.preparePrivateDirectory()
        let socketPath = LocalRuntime.directoryURL
            .appendingPathComponent("oversized-\(UUID().uuidString).sock").path
        let server = LocalSocketServer(socketPath: socketPath)
        try server.start { request in
            CommandResponse.success(id: request.id, result: .object(["unexpected": .bool(true)]))
        }
        defer { server.stop() }

        let descriptor = try connectRawUnixSocket(path: socketPath)
        defer { closeRawSocket(descriptor) }
        var request = Data(repeating: 0x78, count: headlessMaximumMessageBytes + 8_192)
        request.append(0x0A)
        let sent = try writeRawSocket(request, descriptor: descriptor)
        try expect(sent > headlessMaximumMessageBytes, "raw request should cross the protocol limit")
        let response = try ProtocolCodec.decodeLine(
            CommandResponse.self, from: readRawSocketLine(descriptor: descriptor)
        )
        try expect(!response.ok, "oversized socket request should fail")
        try expect(response.error?.code == "INVALID_REQUEST", "oversized request should retain an explicit error code")
        try expect(response.result == nil, "oversized request must not reach the command handler")
    }

    static func differentPeerUserIsRejected() throws {
        #if os(Linux)
        // The Linux CI container runs this suite as root, which lets the test
        // launch one deliberately unprivileged peer. Normal developer runs
        // still exercise every other transport boundary without requiring
        // privilege escalation.
        guard getuid() == 0 else { return }
        let setpriv = "/usr/bin/setpriv"
        try expect(FileManager.default.isExecutableFile(atPath: setpriv), "Linux CI should provide setpriv")
        try LocalRuntime.preparePrivateDirectory()
        let socketPath = LocalRuntime.directoryURL
            .appendingPathComponent("peer-uid-\(UUID().uuidString).sock").path
        let server = LocalSocketServer(socketPath: socketPath)
        try server.start { request in CommandResponse.success(id: request.id) }
        defer {
            server.stop()
            _ = Glibc.chmod(LocalRuntime.directoryURL.path, 0o700)
        }
        // The production modes are 0700/0600. Open them only inside this
        // disposable test so a different uid can reach accept(), where the
        // credential check must still fail closed.
        try expect(Glibc.chmod(LocalRuntime.directoryURL.path, 0o777) == 0, "test runtime directory chmod failed")
        try expect(Glibc.chmod(socketPath, 0o666) == 0, "test socket chmod failed")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: setpriv)
        process.arguments = [
            "--reuid=65534", "--regid=65534", "--clear-groups",
            CommandLine.arguments[0], "--peer-denied-client", socketPath,
        ]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let errorText = String(
            decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        try expect(process.terminationStatus == 0, "different-uid peer was not rejected: \(errorText)")
        #endif
    }

    static func screenshotSeriesHelpers() throws {
        let rawPlan = JSONValue.object([
            "initialY": .number(240),
            "truncated": .bool(true),
            "totalPoints": .number(100),
            "points": .array([
                .object(["y": .number(0), "label": .string("top"), "kind": .string("viewport")]),
                .object(["y": .number(900), "label": .string("bottom"), "kind": .string("viewport")]),
            ]),
        ])
        let plan = try parseScreenshotSeriesPlan(rawPlan)
        try expect(plan.initialY == 240, "series plans should retain the initial scroll position")
        try expect(plan.points.count == 2, "series plans should parse capture points")
        try expect(plan.truncated && plan.totalPoints == 100, "series plans should report truncation")
        try expectThrows("invalid initial scroll positions should fail") {
            _ = try parseScreenshotSeriesPlan(.object([
                "initialY": .number(-1),
                "points": .array([.object(["y": .number(0)])]),
            ]))
        }

        let root = "/tmp/headless-series-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try ArtifactStore(environment: ["HEADLESS_ARTIFACT_DIR": root])
        let collisionName = try screenshotSeriesArtifactName(
            prefix: "capture", mode: "viewport", index: 2, count: plan.points.count,
            point: plan.points[1], format: .png
        )
        _ = try store.write(
            Data([0x01]), requestedName: collisionName, extension: "png", prefix: "unused"
        )
        try expectThrows("a later series collision should fail atomically") {
            _ = try reserveScreenshotSeriesArtifacts(
                store: store, points: plan.points, prefix: "capture",
                mode: "viewport", format: .png
            )
        }
        let firstName = try screenshotSeriesArtifactName(
            prefix: "capture", mode: "viewport", index: 1, count: plan.points.count,
            point: plan.points[0], format: .png
        )
        try expect(
            !FileManager.default.fileExists(atPath: root + "/" + firstName),
            "partial series reservations should be removed after a later collision"
        )
        try expect(RecordingFormat.webm.videoCodec == "vp9", "recording metadata should report the codec, not encoder")
        try expect(!agentRuntimeJavaScript.contains("hints.push('select')"), "inspect must not advertise a missing select command")
        try expect(!agentRuntimeJavaScript.contains("hints.push('upload')"), "inspect must not advertise a missing upload command")
        try expect(!agentRuntimeJavaScript.contains("hints.push('slide')"), "inspect must not advertise a missing slide command")
    }

    static func diagnosticSummary() throws {
        let store = QADiagnosticStore()
        store.append(kind: "console", level: "error", message: "Next.js hydration mismatch")
        store.append(kind: "page-error", message: "uncaught")
        store.append(kind: "response", url: "http://127.0.0.1:3000/missing", status: 404)
        guard case .object(let report) = store.report(), case .object(let summary)? = report["summary"] else {
            throw TestFailure(description: "diagnostic report")
        }
        try expect(report["untrustedContent"] == .bool(true), "diagnostic reports should mark page evidence untrusted")
        try expect(summary["consoleErrors"] == .number(1), "console errors should be counted")
        try expect(summary["pageErrors"] == .number(1), "page errors should be counted")
        try expect(summary["httpErrors"] == .number(1), "HTTP errors should be counted")
        guard case .array(let issues)? = report["issues"] else { throw TestFailure(description: "diagnostic issues") }
        try expect(issues.count == 3, "each actionable diagnostic should have an issue")
        guard case .object(let firstIssue) = issues[0] else { throw TestFailure(description: "diagnostic issue shape") }
        try expect(firstIssue["untrustedContent"] == .bool(true), "derived diagnostic issues should stay untrusted")
        guard case .array(let events)? = report["events"], case .object(let firstEvent) = events[0] else {
            throw TestFailure(description: "diagnostic event shape")
        }
        try expect(firstEvent["untrustedContent"] == .bool(true), "diagnostic events should mark page evidence untrusted")
        let serialized = String(decoding: try ProtocolCodec.encoder.encode(report), as: UTF8.self)
        try expect(serialized.contains("framework-error"), "framework issues should be classified")
        try expect(serialized.contains("local-not-found"), "local 404s should be classified")
        guard case .object(let cleared) = store.clear() else { throw TestFailure(description: "diagnostic clear") }
        try expect(cleared["cleared"] == .number(3), "diagnostic clear should report count")
    }

    static func diagnosticsBoundAndRedacted() throws {
        let store = QADiagnosticStore()
        for _ in 0..<500 { store.append(kind: "console", level: "warn", message: "notice") }
        guard case .object(let exact) = store.report() else { throw TestFailure(description: "exact diagnostic report") }
        try expect(exact["truncated"] == .bool(false), "an exact diagnostic limit is not truncated")
        store.append(kind: "response", url: "https://user:secret@example.com/fail", status: 500)
        guard case .object(let overflow) = store.report() else { throw TestFailure(description: "overflow diagnostic report") }
        try expect(overflow["truncated"] == .bool(true), "overflow diagnostics should be marked truncated")
        let serialized = String(decoding: try ProtocolCodec.encoder.encode(overflow), as: UTF8.self)
        try expect(!serialized.contains("secret@"), "diagnostics must redact URL credentials")
        _ = store.clear()
        store.markTruncated()
        guard case .object(let externallyTruncated) = store.report() else {
            throw TestFailure(description: "externally truncated diagnostic report")
        }
        try expect(externallyTruncated["truncated"] == .bool(true), "diagnostic sources should report rejected events")
    }

    static func responsesFitTheProtocolFrame() throws {
        // 500 events each carrying a 4 KiB message is roughly 2 MB — twice the
        // frame. Before the response bound this encoded past the limit and the
        // agent saw INVALID_REQUEST for a valid `qa report`.
        let store = QADiagnosticStore()
        let wide = String(repeating: "d", count: 4_096)
        for _ in 0..<500 {
            store.append(kind: "console", level: "error", message: wide, url: "https://example.com/\(wide)")
        }
        let report = store.report()
        let encoded = try ProtocolCodec.encodeLine(
            CommandResponse.success(id: "report", result: report)
        )
        try expect(
            encoded.count <= headlessMaximumMessageBytes,
            "a full diagnostic report must fit the protocol frame"
        )
        guard case .object(let object) = report else { throw TestFailure(description: "report shape") }
        try expect(object["truncated"] == .bool(true), "a bounded report should report truncation")
        guard case .object(let summary)? = object["summary"],
              case .object(let omitted)? = object["omitted"],
              case .array(let events)? = object["events"],
              case .array(let issues)? = object["issues"] else {
            throw TestFailure(description: "report bounds")
        }
        try expect(summary["events"] == .number(500), "summary counts should describe every event")
        try expect((omitted["events"]?.numberValue ?? 0) > 0, "omitted events should be counted")
        try expect(
            events.count + Int(omitted["events"]?.numberValue ?? 0) == 500,
            "kept plus omitted events should account for the whole buffer"
        )
        // Issues carry the same message and URL as the events they describe, so
        // a count cap is not a size cap — bounding them by bytes is what keeps
        // the report inside the frame.
        try expect(
            issues.count + Int(omitted["issues"]?.numberValue ?? 0)
                == Int(summary["issues"]?.numberValue ?? 0),
            "kept plus omitted issues should account for every issue"
        )
    }

    static func artifactListingStaysBounded() throws {
        let root = "/tmp/headless-artifact-bound-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try ArtifactStore(environment: ["HEADLESS_ARTIFACT_DIR": root])
        for index in 0..<260 {
            _ = try store.write(Data("x".utf8), requestedName: "bound-\(index).json", extension: "json", prefix: "bound")
        }
        guard case .object(let listing) = try store.list(),
              case .array(let artifacts)? = listing["artifacts"] else {
            throw TestFailure(description: "artifact listing")
        }
        try expect(artifacts.count == 250, "artifact listing should stay bounded")
        try expect(listing["total"] == .number(260), "artifact listing should report the true total")
        try expect(listing["omitted"] == .number(10), "artifact listing should report what it left out")
        try expect(listing["truncated"] == .bool(true), "a bounded artifact listing is truncated")
        let encoded = try ProtocolCodec.encodeLine(
            CommandResponse.success(id: "artifacts", result: try store.list())
        )
        try expect(
            encoded.count <= headlessMaximumMessageBytes,
            "an artifact listing must fit the protocol frame"
        )
    }

    static func diagnosticServices() throws {
        let store = QADiagnosticStore()
        let typedHeaders = diagnosticStringHeaders([
            "X-String": "value", "X-Number": 42, "X-Object": ["nested": true],
        ])
        try expect(typedHeaders == ["X-String": "value"], "non-string CDP header values should be dropped")
        store.append(kind: "console", level: "warn", message: "first")
        store.append(kind: "console", level: "error", message: "second")
        store.append(
            kind: "response", url: "https://example.com/api", method: "POST", status: 500,
            requestID: "request-1", requestHeaders: ["Authorization": "Bearer secret", "X-Visible": "yes"],
            responseHeaders: ["Set-Cookie": "session=secret", "Content-Type": "application/json"], source: "test"
        )
        guard case .object(let console) = store.console(level: "error", limit: 10),
              case .array(let messages)? = console["messages"] else {
            throw TestFailure(description: "console service")
        }
        try expect(console["untrustedContent"] == .bool(true), "console output should mark page evidence untrusted")
        try expect(messages.count == 1, "console service should filter by level")
        guard case .object(let network) = store.network(failedOnly: true, status: nil, limit: 10),
              case .array(let requests)? = network["requests"] else {
            throw TestFailure(description: "network service")
        }
        try expect(network["untrustedContent"] == .bool(true), "network output should mark page evidence untrusted")
        try expect(requests.count == 1, "network service should find failed HTTP responses")
        let networkText = String(decoding: try ProtocolCodec.encoder.encode(network), as: UTF8.self)
        try expect(!networkText.contains("Bearer secret"), "network summaries must omit headers")
        let detail = store.networkDetail(requestID: "request-1")
        guard case .object(let detailObject) = detail else { throw TestFailure(description: "network detail shape") }
        try expect(detailObject["untrustedContent"] == .bool(true), "network detail should mark page evidence untrusted")
        let detailText = String(decoding: try ProtocolCodec.encoder.encode(detail), as: UTF8.self)
        try expect(detailText.contains("[redacted]"), "network details must redact sensitive headers")
        try expect(detailText.contains("X-Visible"), "network details should retain non-sensitive headers")

        var manyHeaders: [String: String] = [:]
        for index in (0..<70).reversed() {
            manyHeaders[String(format: "X-%03d", index)] = "value-\(index)"
        }
        store.append(kind: "response", requestID: "request-headers", requestHeaders: manyHeaders)
        guard case .object(let headerDetail) = store.networkDetail(requestID: "request-headers"),
              case .object(let requestEvent)? = headerDetail["request"],
              case .object(let boundedHeaders)? = requestEvent["requestHeaders"] else {
            throw TestFailure(description: "bounded diagnostic headers")
        }
        try expect(boundedHeaders.count == 64, "diagnostic headers should remain capped at 64")
        try expect(boundedHeaders["X-000"] == .string("value-0"), "header selection should use sorted keys")
        try expect(boundedHeaders["X-063"] == .string("value-63"), "the deterministic header boundary changed")
        try expect(boundedHeaders["X-064"] == nil, "headers beyond the sorted cap should be omitted")
    }

    static func diagnosticCLI() throws {
        let console = try CLIParser().parse(["console", "list", "--level", "error", "--limit", "25"])
        try expect(console.request?.command == .consoleList, "console command should parse")
        let network = try CLIParser().parse(["network", "get", "request-1"])
        try expect(network.request?.command == .networkGet, "network detail command should parse")
        let styles = try CLIParser().parse(["styles", "get", "--role", "button", "--name", "Continue", "--property", "display"])
        try expect(styles.request?.parameters["properties"] == .array([.string("display")]), "style property should parse")
        let storage = try CLIParser().parse(["storage", "list", "--scope", "local"])
        try expect(storage.request?.command == .storageList, "storage command should parse")
        do {
            _ = try CLIParser().parse(["qa", "bogus", "--x"])
            throw TestFailure(description: "unknown QA subcommands should fail")
        } catch let error as CLIParseError {
            try expect(error == .unknownCommand("qa bogus"), "unknown QA subcommands should win over trailing-option validation")
        }
    }

    static func localSocketRoundTrip() throws {
        try LocalRuntime.preparePrivateDirectory()
        let socketPath = LocalRuntime.directoryURL
            .appendingPathComponent("test-\(UUID().uuidString).sock").path
        let server = LocalSocketServer(socketPath: socketPath)
        try server.start { request in
            CommandResponse.success(id: request.id, result: .object(["pong": .bool(true)]))
        }
        defer { server.stop() }
        let request = CommandRequest(id: "ping-1", command: .ping)
        let response = try LocalSocketClient(socketPath: socketPath).send(request, timeout: 2)
        try expect(response.ok, "socket response should succeed")
        try expect(response.id == request.id, "socket response should preserve request ID")
        try expect(response.result == .object(["pong": .bool(true)]), "socket response should decode")
    }

    static func rejectsMismatchedResponseIdentifier() throws {
        try LocalRuntime.preparePrivateDirectory()
        let socketPath = LocalRuntime.directoryURL
            .appendingPathComponent("test-\(UUID().uuidString).sock").path
        let server = LocalSocketServer(socketPath: socketPath)
        // A host that answers with someone else's id is answering the wrong
        // question. One request per connection means the client can say so.
        try server.start { _ in
            CommandResponse.success(id: "a-different-request", result: .object(["pong": .bool(true)]))
        }
        defer { server.stop() }
        try expectThrows("a mismatched response identifier should be rejected") {
            _ = try LocalSocketClient(socketPath: socketPath)
                .send(CommandRequest(id: "ping-correlated", command: .ping), timeout: 2)
        }
        // The unknown-id sentinel stays usable, because a host that could not
        // read the request still has to be able to explain why.
        let sentinelPath = LocalRuntime.directoryURL
            .appendingPathComponent("test-\(UUID().uuidString).sock").path
        let sentinelServer = LocalSocketServer(socketPath: sentinelPath)
        try sentinelServer.start { _ in
            CommandResponse.failure(
                id: CommandResponse.unknownRequestIdentifier,
                code: "INVALID_REQUEST", message: "unreadable"
            )
        }
        defer { sentinelServer.stop() }
        let sentinel = try LocalSocketClient(socketPath: sentinelPath)
            .send(CommandRequest(id: "ping-sentinel", command: .ping), timeout: 2)
        try expect(!sentinel.ok, "the sentinel reply should still reach the caller")
        try expect(sentinel.error?.code == "INVALID_REQUEST", "the sentinel reply should keep its reason")
    }

    static func liveSocketCannotBeReplaced() throws {
        try LocalRuntime.preparePrivateDirectory()
        let socketPath = LocalRuntime.directoryURL
            .appendingPathComponent("live-\(UUID().uuidString).sock").path
        let first = LocalSocketServer(socketPath: socketPath)
        try first.start { CommandResponse.success(id: $0.id) }
        defer { first.stop() }
        let second = LocalSocketServer(socketPath: socketPath)
        try expectThrows("a live host socket must not be unlinked") {
            try second.start { CommandResponse.success(id: $0.id) }
        }
        let response = try LocalSocketClient(socketPath: socketPath)
            .send(CommandRequest(id: "still-live", command: .ping), timeout: 2)
        try expect(response.ok, "first host should remain reachable")
    }

    static func serverRejectsSocketOutsidePrivateDirectory() throws {
        let server = LocalSocketServer(socketPath: "/tmp/headless-outside-\(UUID().uuidString).sock")
        try expectThrows("server should reject a socket outside its private runtime directory") {
            try server.start { CommandResponse.success(id: $0.id) }
        }
    }

    static func shutdownBypassesBusyRequest() throws {
        try LocalRuntime.preparePrivateDirectory()
        let socketPath = LocalRuntime.directoryURL
            .appendingPathComponent("shutdown-\(UUID().uuidString).sock").path
        let server = LocalSocketServer(socketPath: socketPath)
        let requestStarted = DispatchSemaphore(value: 0)
        let releaseRequest = DispatchSemaphore(value: 0)
        let requestFinished = DispatchSemaphore(value: 0)
        try server.start { request in
            if request.command == .visit {
                requestStarted.signal()
                _ = releaseRequest.wait(timeout: .now() + 2)
                requestFinished.signal()
            }
            return CommandResponse.success(id: request.id)
        }
        defer { server.stop() }

        DispatchQueue.global(qos: .userInitiated).async {
            defer { requestFinished.signal() }
            _ = try? LocalSocketClient(socketPath: socketPath).send(
                CommandRequest(command: .visit, parameters: ["url": .string("http://localhost")]), timeout: 3
            )
        }
        try expect(requestStarted.wait(timeout: .now() + 1) == .success, "visit should begin")
        let shutdown = try LocalSocketClient(socketPath: socketPath).send(
            CommandRequest(command: .shutdown), timeout: 1
        )
        try expect(shutdown.ok, "shutdown should not wait for an in-flight browser request")
        releaseRequest.signal()
        _ = requestFinished.wait(timeout: .now() + 2)
    }

    static func nullTerminatedBufferScansIncrementally() throws {
        var buffer = NullTerminatedMessageBuffer()
        let chunk = [UInt8](repeating: 0x61, count: 8_192)
        let chunkSlice = chunk[...]
        let chunkCount = 30 * 1_024 * 1_024 / chunk.count

        for _ in 0..<chunkCount {
            buffer.append(contentsOf: chunkSlice)
            try expect(
                buffer.unscannedByteCount == chunk.count,
                "only newly appended CDP bytes should remain unscanned"
            )
            try expect(buffer.popFirst() == nil, "unterminated CDP payload should remain buffered")
            try expect(buffer.unscannedByteCount == 0, "the CDP scan cursor should advance to the buffer end")
        }
        try expect(
            buffer.bufferedByteCount == 30 * 1_024 * 1_024,
            "large chunked CDP payload should retain every byte"
        )
        buffer.append(contentsOf: [UInt8(0)][...])
        try expect(buffer.popFirst()?.count == 30 * 1_024 * 1_024, "terminator should release the complete CDP payload")
        try expect(buffer.bufferedByteCount == 0, "consumed CDP storage should compact")

        buffer.append(contentsOf: Array("one\0two\0".utf8)[...])
        try expect(buffer.popFirst() == Array("one".utf8), "first buffered CDP message changed")
        try expect(buffer.popFirst() == Array("two".utf8), "second buffered CDP message changed")
    }

    static func typedHostErrorsRoundTrip() throws {
        let success = try unwrapAgentEvaluationResult(.object([
            "__headlessAgentResult": .bool(true), "ok": .bool(true),
            "value": .object(["clicked": .string("@e1")]),
        ]))
        try expect(
            success == .object(["clicked": .string("@e1")]),
            "agent result envelope should preserve successful values"
        )

        do {
            _ = try unwrapAgentEvaluationResult(.object([
                "__headlessAgentResult": .bool(true), "ok": .bool(false),
                "error": .object([
                    "code": .string("ELEMENT_NOT_FOUND"),
                    "message": .string("reference expired"),
                ]),
            ]))
            throw TestFailure(description: "typed agent error should throw")
        } catch let error as HostError {
            try expect(error.code == .elementNotFound, "agent error code should survive the engine boundary")
            try expect(error.message == "reference expired", "agent error message should survive the engine boundary")
            try expect(error.suggestion?.contains("inspect --interactive") == true, "typed error should own its suggestion")
        }

        do {
            _ = try unwrapAgentEvaluationResult(.object([
                "__headlessAgentResult": .bool(true), "ok": .bool(false),
                "error": .object(["code": .string("PAGE_DEFINED_CODE"), "message": .string("failed")]),
            ]))
            throw TestFailure(description: "unknown agent error should throw")
        } catch let error as HostError {
            try expect(error.code == .operationFailed, "unknown error codes must fail closed")
        }
    }

    static func singleSourceContractConstants() throws {
        func javaScriptSet(named name: String) throws -> Set<String> {
            let marker = "const \(name) = new Set(["
            guard let start = agentRuntimeJavaScript.range(of: marker),
                  let end = agentRuntimeJavaScript.range(
                    of: "]);", range: start.upperBound..<agentRuntimeJavaScript.endIndex
                  ) else {
                throw TestFailure(description: "missing JavaScript set: \(name)")
            }
            return Set(agentRuntimeJavaScript[start.upperBound..<end.lowerBound]
                .split(separator: ",")
                .map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                })
        }

        try expect(
            javaScriptSet(named: "blockedResourceExtensions") == blockedRemoteResourceExtensions,
            "blocked resource extensions drifted between Swift and the isolated runtime"
        )
        try expect(
            javaScriptSet(named: "cautionResourceExtensions") == cautionRemoteResourceExtensions,
            "caution resource extensions drifted between Swift and the isolated runtime"
        )
        try expect(hasPortableNameCharacters("artifact-1_name.json"), "portable artifact characters changed")
        try expect(!hasPortableNameCharacters("artifact/name.json"), "path separators must not be portable name characters")
        try expect(
            localDevelopmentHosts == ["localhost", "127.0.0.1", "0.0.0.0", "::1"],
            "local development host allowlist changed"
        )
        let maximumScreenshot = try BoundedScreenshotRectangle([
            "x": .number(0), "y": .number(0),
            "width": .number(ProtocolBounds.screenshotDimension),
            "height": .number(ProtocolBounds.screenshotPixels / ProtocolBounds.screenshotDimension),
        ])
        try expect(
            maximumScreenshot.width * maximumScreenshot.height == ProtocolBounds.screenshotPixels,
            "the shared screenshot pixel bound should accept its exact limit"
        )
        try expectThrows("the shared screenshot bound should reject oversized captures") {
            _ = try BoundedScreenshotRectangle([
                "x": .number(0), "y": .number(0),
                "width": .number(ProtocolBounds.screenshotDimension),
                "height": .number(ProtocolBounds.screenshotDimension),
            ])
        }
        try expect(
            try browserTargetArguments(["target": .string("@e123")])["target"] as? String == "@e123",
            "shared target conversion should preserve validated references"
        )
        try expectThrows("shared target conversion should reject invalid references") {
            _ = try browserTargetArguments(["target": .string("#page-owned-selector")])
        }
        try requireSensitiveDiagnosticsAccess(
            if: true, environment: ["HEADLESS_ALLOW_SENSITIVE_DIAGNOSTICS": "1"]
        )
        try expectThrows("sensitive diagnostics should stay double-gated") {
            try requireSensitiveDiagnosticsAccess(if: true, environment: [:])
        }

        let minimumScroll = try CLIParser().parse([
            "scroll", "down", "--amount", String(ProtocolBounds.scrollAmount.lowerBound),
        ])
        try minimumScroll.request?.validate()
        try expectThrows("CLI should reject scroll amounts below the validator minimum") {
            _ = try CLIParser().parse(["scroll", "down", "--amount", "0.09"])
        }
        let maximumNetwork = try CLIParser().parse([
            "network", "emulate",
            "--latency", String(ProtocolBounds.networkLatencyMilliseconds.upperBound),
            "--download-kbps", String(ProtocolBounds.networkThroughputKbps.upperBound),
            "--upload-kbps", String(ProtocolBounds.networkThroughputKbps.lowerBound),
        ])
        try maximumNetwork.request?.validate()
        try expectThrows("CLI should reject latency above the validator maximum") {
            _ = try CLIParser().parse(["network", "emulate", "--latency", "120001"])
        }
        try expectThrows("CLI should reject throughput below the validator minimum") {
            _ = try CLIParser().parse(["network", "emulate", "--download-kbps", "-2"])
        }
    }

    static func sharedHostCoreDispatch() throws {
        let root = "/tmp/headless-host-core-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let defaultSession = TestBrowserSession()
        let engine = TestBrowserEngine()
        let core = HostCore(
            engine: engine,
            artifacts: try ArtifactStore(environment: ["HEADLESS_ARTIFACT_DIR": root]),
            defaultSession: defaultSession,
            shutdownHandler: {}
        )
        defer { core.stop() }

        let ping = core.handle(CommandRequest(command: .ping))
        guard ping.ok, case .object(let pingResult) = ping.result else {
            throw TestFailure(description: "shared host ping should succeed")
        }
        try expect(pingResult["engine"] == .string("fake"), "ping should identify the engine")
        try expect(pingResult["platform"] == .string("test"), "ping should identify the platform")
        try expect(pingResult["adapter"] == .string("test-adapter"), "engine ping details should be merged")
        try expect(pingResult["capabilities"] != nil, "ping should publish the active engine profile")

        let created = core.handle(CommandRequest(
            command: .sessionCreate, parameters: ["name": .string("secondary")]
        ))
        try expect(created.ok, "shared session creation should succeed")
        try expect(engine.createdSessions.count == 1, "session creation should delegate to the engine")

        let inspected = core.handle(CommandRequest(
            command: .inspect, session: "secondary", parameters: ["interactive": .bool(true)]
        ))
        guard inspected.ok, case .object(let inspectResult) = inspected.result else {
            throw TestFailure(description: "shared inspect dispatch should succeed")
        }
        try expect(inspectResult["engineResult"] == .bool(true), "inspect should delegate to the session")
        try expect(
            engine.createdSessions[0].agentControlEnableCount == 2,
            "agent control should be enabled at creation and before command execution"
        )

        let capture = core.handle(CommandRequest(command: .captureInfo, session: "secondary"))
        guard capture.ok, case .object(let captureResult) = capture.result else {
            throw TestFailure(description: "shared capture info should succeed")
        }
        try expect(captureResult["engine"] == .string("fake"), "capture info should retain engine fields")
        try expect(captureResult["trace"] != nil, "capture info should include the shared trace")
        try expect(captureResult["recording"] != nil, "capture info should include recording state")

        let unsupported = core.handle(CommandRequest(command: .networkEmulate, session: "secondary"))
        try expect(
            unsupported.error?.code == "UNSUPPORTED_CAPABILITY",
            "unsupported engine features should return a typed capability error"
        )

        let closed = core.handle(CommandRequest(command: .sessionClose, session: "secondary"))
        try expect(closed.ok, "shared session close should succeed")
        try expect(engine.closedSessions.count == 1, "session close should delegate to the engine")
        let missing = core.handle(CommandRequest(command: .inspect, session: "secondary"))
        try expect(missing.error?.code == "SESSION_NOT_FOUND", "closed sessions should be removed from shared state")
    }

    static func main() {
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--peer-denied-client" {
            do {
                let descriptor = try connectRawUnixSocket(path: CommandLine.arguments[2])
                defer { closeRawSocket(descriptor) }
                let response = try ProtocolCodec.decodeLine(
                    CommandResponse.self, from: readRawSocketLine(descriptor: descriptor)
                )
                guard response.error?.code == "PEER_DENIED" else {
                    fputs("expected PEER_DENIED\n", stderr)
                    exit(1)
                }
                exit(0)
            } catch {
                fputs("peer client failed: \(error)\n", stderr)
                exit(1)
            }
        }
        let tests: [TestCase] = [
            ("request round-trip", requestRoundTrip),
            ("unsafe navigation schemes", rejectsUnsafeNavigationSchemes),
            ("localhost normalization", normalizesLocalhostToHTTP),
            ("page navigation boundary", pageNavigationBoundary),
            ("message size limit", messageSizeLimit),
            ("identifier validation", identifierValidation),
            ("command parameter validation", commandParameterValidation),
            ("strict request fields", rejectsUnexpectedRequestFields),
            ("CLI visit", cliVisit),
            ("CLI fill literal value", cliFillPreservesLiteralValue),
            ("CLI semantic click", cliSemanticClick),
            ("CLI inspect context and task", cliInspectContextAndTask),
            ("CLI conflicting target", cliRejectsConflictingClickTarget),
            ("CLI settled wait", cliWaitDefaultsToSettled),
            ("CLI timeout bound", cliRejectsUnboundedTimeout),
            ("client timeout parity", clientTimeoutsMatchCommandBounds),
            ("CLI P1 artifacts", cliP1Artifacts),
            ("CLI P2 commands and boundaries", cliP2CommandsAndBoundaries),
            ("CLI command matrix", cliCommandMatrix),
            ("Chromium runtime selection", chromiumRuntimeSelection),
            ("artifact store round-trip", artifactStoreRoundTrip),
            ("artifact read boundaries", artifactReadsStayInsideBounds),
            ("flow recording safety", flowRecordingOmitsSensitiveCommands),
            ("visual comparison", visualComparisonInvokesBoundedTool),
            ("recording arguments and bounds", recordingArgumentsAndFailureBounds),
            ("capabilities match commands", capabilitiesMatchProtocolCommands),
            ("screenshot series helpers", screenshotSeriesHelpers),
            ("diagnostic summary", diagnosticSummary),
            ("diagnostic bounds and URL redaction", diagnosticsBoundAndRedacted),
            ("responses fit the protocol frame", responsesFitTheProtocolFrame),
            ("artifact listing stays bounded", artifactListingStaysBounded),
            ("diagnostic services", diagnosticServices),
            ("diagnostic CLI", diagnosticCLI),
            ("local socket round-trip", localSocketRoundTrip),
            ("response identifier correlation", rejectsMismatchedResponseIdentifier),
            ("live socket replacement protection", liveSocketCannotBeReplaced),
            ("private socket directory", serverRejectsSocketOutsidePrivateDirectory),
            ("shutdown bypasses busy request", shutdownBypassesBusyRequest),
            ("oversized socket request", oversizedSocketRequestIsRejected),
            ("different peer uid", differentPeerUserIsRejected),
            ("incremental NUL message buffering", nullTerminatedBufferScansIncrementally),
            ("typed host errors", typedHostErrorsRoundTrip),
            ("single-source contract constants", singleSourceContractConstants),
            ("shared host core dispatch", sharedHostCoreDispatch),
        ]

        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("✓ \(name)")
            } catch {
                failures += 1
                fputs("✗ \(name): \(error)\n", stderr)
            }
        }
        print("\(tests.count - failures)/\(tests.count) protocol tests passed")
        if failures > 0 { exit(1) }
    }
}
