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
            ("CLI inspect context and task", cliInspectContextAndTask),
            ("CLI conflicting target", cliRejectsConflictingClickTarget),
            ("CLI settled wait", cliWaitDefaultsToSettled),
            ("CLI timeout bound", cliRejectsUnboundedTimeout),
            ("CLI P1 artifacts", cliP1Artifacts),
            ("CLI P2 commands and boundaries", cliP2CommandsAndBoundaries),
            ("Chromium runtime selection", chromiumRuntimeSelection),
            ("artifact store round-trip", artifactStoreRoundTrip),
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
