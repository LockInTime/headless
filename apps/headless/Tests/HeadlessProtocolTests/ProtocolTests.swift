import HeadlessProtocol
import Foundation

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
        let data = Data(#"{"id":"request-1","version":"0.1","command":"ping","parameters":{},"execute":"anything"}"#.utf8)
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
    }

    static func cliSemanticClick() throws {
        let invocation = try CLIParser().parse(["click", "--role", "button", "--name", "Continue"])
        try expect(
            invocation.request?.parameters == ["role": .string("button"), "name": .string("Continue")],
            "semantic target should parse"
        )
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

    static func cliP1Artifacts() throws {
        let screenshot = try CLIParser().parse([
            "--session", "qa", "screenshot", "--role", "button", "--name", "Continue",
            "--output", "continue.png",
        ])
        try expect(screenshot.request?.command == .screenshot, "screenshot command should parse")
        try expect(screenshot.request?.parameters["output"] == .string("continue.png"), "screenshot output should parse")
        let record = try CLIParser().parse(["record", "start", "--fps", "8", "--output", "flow.mp4"])
        try expect(record.request?.command == .recordStart, "record start should parse")
        try expect(record.request?.parameters["fps"] == .number(8), "record FPS should parse")
        try expectThrows("unsupported recorder selectors should fail instead of being ignored") {
            _ = try CLIParser().parse(["record", "start", "--provider", "browser"])
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

    static func diagnosticSummary() throws {
        let store = QADiagnosticStore()
        store.append(kind: "console", level: "error", message: "Next.js hydration mismatch")
        store.append(kind: "page-error", message: "uncaught")
        store.append(kind: "response", url: "http://127.0.0.1:3000/missing", status: 404)
        guard case .object(let report) = store.report(), case .object(let summary)? = report["summary"] else {
            throw TestFailure(description: "diagnostic report")
        }
        try expect(summary["consoleErrors"] == .number(1), "console errors should be counted")
        try expect(summary["pageErrors"] == .number(1), "page errors should be counted")
        try expect(summary["httpErrors"] == .number(1), "HTTP errors should be counted")
        guard case .array(let issues)? = report["issues"] else { throw TestFailure(description: "diagnostic issues") }
        try expect(issues.count == 3, "each actionable diagnostic should have an issue")
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
    }

    static func diagnosticServices() throws {
        let store = QADiagnosticStore()
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
        try expect(messages.count == 1, "console service should filter by level")
        guard case .object(let network) = store.network(failedOnly: true, status: nil, limit: 10),
              case .array(let requests)? = network["requests"] else {
            throw TestFailure(description: "network service")
        }
        try expect(requests.count == 1, "network service should find failed HTTP responses")
        let networkText = String(decoding: try ProtocolCodec.encoder.encode(network), as: UTF8.self)
        try expect(!networkText.contains("Bearer secret"), "network summaries must omit headers")
        let detailText = String(decoding: try ProtocolCodec.encoder.encode(store.networkDetail(requestID: "request-1")), as: UTF8.self)
        try expect(detailText.contains("[redacted]"), "network details must redact sensitive headers")
        try expect(detailText.contains("X-Visible"), "network details should retain non-sensitive headers")
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

    static func main() {
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
            ("CLI semantic click", cliSemanticClick),
            ("CLI conflicting target", cliRejectsConflictingClickTarget),
            ("CLI settled wait", cliWaitDefaultsToSettled),
            ("CLI timeout bound", cliRejectsUnboundedTimeout),
            ("CLI P1 artifacts", cliP1Artifacts),
            ("CLI P2 commands and boundaries", cliP2CommandsAndBoundaries),
            ("Chromium runtime selection", chromiumRuntimeSelection),
            ("artifact store round-trip", artifactStoreRoundTrip),
            ("diagnostic summary", diagnosticSummary),
            ("diagnostic bounds and URL redaction", diagnosticsBoundAndRedacted),
            ("diagnostic services", diagnosticServices),
            ("diagnostic CLI", diagnosticCLI),
            ("local socket round-trip", localSocketRoundTrip),
            ("live socket replacement protection", liveSocketCannotBeReplaced),
            ("private socket directory", serverRejectsSocketOutsidePrivateDirectory),
            ("shutdown bypasses busy request", shutdownBypassesBusyRequest),
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
