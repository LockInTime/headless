import AppKit
import HeadlessProtocol
import CoreFoundation
import Foundation
import WebKit

let agentWorld = WKContentWorld.world(name: "HeadlessAgent")

struct ScreenshotArtifactData {
    let data: Data
    let clipboardCopied: Bool
}

extension BrowserWindowController {
    func agentVisit(_ url: URL, timeout: TimeInterval = 20) throws -> JSONValue {
        onMain { self.navigate(to: url) }
        Thread.sleep(forTimeInterval: 0.05)
        return try agentWait(parameters: ["settled": .bool(true), "timeoutMs": .number(timeout * 1_000)])
    }

    func agentInspect(parameters: [String: JSONValue]) throws -> JSONValue {
        var options: [String: Any] = [
            "context": parameters["context"]?.stringValue ?? "full",
            "task": parameters["task"]?.stringValue ?? "",
        ]
        if let within = parameters["within"]?.stringValue { options["within"] = within }
        if let limit = parameters["limit"]?.numberValue { options["limit"] = limit }
        if let budget = parameters["budget"]?.numberValue { options["budget"] = budget }
        if let depth = parameters["depth"]?.numberValue { options["depth"] = depth }
        return try callAgent(
            "return globalThis.__headlessAgent.snapshot(interactive, includeText, options);",
            arguments: [
                "interactive": parameters["interactive"]?.boolValue ?? false,
                "includeText": parameters["text"]?.boolValue ?? false,
                "options": options,
            ]
        )
    }

    func agentClick(parameters: [String: JSONValue]) throws -> JSONValue {
        let args = try targetArguments(parameters)
        return try callAgent("return globalThis.__headlessAgent.click(args);", arguments: ["args": args])
    }

    func agentFill(parameters: [String: JSONValue]) throws -> JSONValue {
        var args = try targetArguments(parameters)
        guard let value = parameters["value"]?.stringValue else {
            throw HostError(code: .operationFailed, message: "Missing command parameter: value")
        }
        args["value"] = value
        return try callAgent("return globalThis.__headlessAgent.fill(args);", arguments: ["args": args])
    }

    func agentPress(parameters: [String: JSONValue]) throws -> JSONValue {
        guard let key = parameters["key"]?.stringValue, !key.isEmpty, key.count <= 32 else {
            throw HostError(code: .operationFailed, message: "Missing command parameter: key")
        }
        return try callAgent("return globalThis.__headlessAgent.press(key);", arguments: ["key": key])
    }

    func agentScroll(parameters: [String: JSONValue]) throws -> JSONValue {
        let direction = parameters["direction"]?.stringValue ?? "down"
        var args: [String: Any] = ["direction": direction]
        if let amount = parameters["amount"]?.numberValue { args["amount"] = amount }
        return try callAgent("return globalThis.__headlessAgent.scroll(args);", arguments: ["args": args])
    }

    func agentWait(parameters: [String: JSONValue]) throws -> JSONValue {
        let timeoutMs = min(120_000, max(100, parameters["timeoutMs"]?.numberValue ?? 20_000))
        let expectedURL = parameters["url"]?.stringValue
        let expectedText = parameters["text"]?.stringValue
        let requireSettled = parameters["settled"]?.boolValue ?? false
        let deadline = Date().addingTimeInterval(timeoutMs / 1_000)
        var lastState: JSONValue = .object([:])

        repeat {
            lastState = try callAgent("return globalThis.__headlessAgent.state();")
            guard case .object(let state) = lastState else {
                throw HostError(code: .operationFailed, message: "Browser returned an invalid agent result")
            }
            let urlMatches = expectedURL.map { state["url"]?.stringValue?.contains($0) == true } ?? true
            let textMatches = expectedText.map { state["text"]?.stringValue?.localizedCaseInsensitiveContains($0) == true } ?? true
            let isLoading = onMain { self.webView.isLoading }
            let ready = state["readyState"]?.stringValue == "complete"
            let animations = state["runningAnimations"]?.numberValue ?? 0
            let quiet = state["mutationQuietMs"]?.numberValue ?? 0
            let settled = !requireSettled || (!isLoading && ready && animations == 0 && quiet >= 300)
            if urlMatches && textMatches && settled { return lastState }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline

        throw HostError(code: .timedOut, message: "Timed out while waiting for page condition")
    }

    func agentTour(parameters: [String: JSONValue]) throws -> JSONValue {
        let pace = min(5_000, max(100, parameters["pace"]?.numberValue ?? 800))
        return try callAgent(
            "return await globalThis.__headlessAgent.tour(args);",
            arguments: ["args": ["pace": pace, "fullPage": parameters["fullPage"]?.boolValue ?? true]],
            timeout: 65
        )
    }

    func agentCaptureInfo() throws -> JSONValue {
        let windowInfo: [String: JSONValue] = onMain {
            guard let window = self.window else { return [:] }
            return [
                "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
                "windowId": .number(Double(window.windowNumber)),
                "title": .string(window.title),
                "bounds": .object([
                    "x": .number(Double(window.frame.origin.x)),
                    "y": .number(Double(window.frame.origin.y)),
                    "width": .number(Double(window.frame.width)),
                    "height": .number(Double(window.frame.height)),
                ]),
                "scaleFactor": .number(Double(window.backingScaleFactor)),
            ]
        }
        let state = try callAgent("return globalThis.__headlessAgent.state();")
        return .object(["window": .object(windowInfo), "page": state, "engine": .string("webkit")])
    }

    func agentScreenshot(parameters: [String: JSONValue]) throws -> Data {
        try agentScreenshotData(parameters: parameters, format: .png, copyToClipboard: false).data
    }

    func agentScreenshotData(
        parameters: [String: JSONValue],
        format: ScreenshotFormat,
        copyToClipboard: Bool
    ) throws -> ScreenshotArtifactData {
        let image = try agentScreenshotImage(parameters: parameters)
        guard let data = encodeScreenshot(image, format: format) else {
            throw HostError(code: .operationFailed, message: "Browser returned an invalid agent result")
        }
        if copyToClipboard {
            guard format.isImage else {
                throw HostError(code: .operationFailed, message: "Clipboard output is only supported for image screenshots")
            }
            onMain {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
        }
        return ScreenshotArtifactData(data: data, clipboardCopied: copyToClipboard)
    }

    private func agentScreenshotImage(parameters: [String: JSONValue]) throws -> NSImage {
        var requestedRect: CGRect?
        let hasTarget = parameters["target"] != nil || parameters["role"] != nil || parameters["name"] != nil
        if hasTarget {
            let args = try targetArguments(parameters)
            let value = try callAgent(
                "return globalThis.__headlessAgent.rectangle(args);", arguments: ["args": args]
            )
            guard case .object(let outer) = value, case .object(let rect)? = outer["viewport"] else {
                throw HostError(code: .operationFailed, message: "Browser returned an invalid agent result")
            }
            requestedRect = try screenshotRect(rect)
        } else if parameters["fullPage"]?.boolValue == true {
            let value = try callAgent("""
                return {x: 0, y: 0, width: document.documentElement.scrollWidth,
                        height: document.documentElement.scrollHeight};
                """)
            guard case .object(let rect) = value else {
                throw HostError(code: .operationFailed, message: "Browser returned an invalid agent result")
            }
            requestedRect = try screenshotRect(rect)
        }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var captured: Result<NSImage, Error>?
        DispatchQueue.main.async {
            let configuration: WKSnapshotConfiguration?
            if let requestedRect {
                let value = WKSnapshotConfiguration()
                value.rect = requestedRect
                value.snapshotWidth = NSNumber(value: min(requestedRect.width, 4_096))
                configuration = value
            } else {
                configuration = nil
            }
            self.webView.takeSnapshot(with: configuration) { image, error in
                lock.lock()
                if let image { captured = .success(image) }
                else {
                    captured = .failure(error ?? HostError(
                        code: .operationFailed, message: "Browser returned an invalid agent result"
                    ))
                }
                lock.unlock()
                semaphore.signal()
            }
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw HostError(code: .timedOut, message: "Timed out while waiting for screenshot")
        }
        lock.lock(); let result = captured; lock.unlock()
        guard let image = try result?.get() else {
            throw HostError(code: .operationFailed, message: "Browser returned an invalid agent result")
        }
        return image
    }

    private func encodeScreenshot(_ image: NSImage, format: ScreenshotFormat) -> Data? {
        switch format {
        case .png:
            return bitmapData(for: image, type: .png, properties: [:])
        case .jpeg:
            return bitmapData(for: image, type: .jpeg, properties: [.compressionFactor: 0.88])
        case .pdf:
            return pdfData(for: image)
        }
    }

    private func bitmapData(
        for image: NSImage,
        type: NSBitmapImageRep.FileType,
        properties: [NSBitmapImageRep.PropertyKey: Any]
    ) -> Data? {
        guard let representation = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: representation) else { return nil }
        return bitmap.representation(using: type, properties: properties)
    }

    private func pdfData(for image: NSImage) -> Data? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &rect, nil),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        context.beginPDFPage(nil)
        context.draw(cgImage, in: rect)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    func agentScreenshotSeriesPlan(mode: String) throws -> JSONValue {
        try callAgent(
            "return globalThis.__headlessAgent.screenshotPlan(args);",
            arguments: ["args": ["mode": mode]]
        )
    }

    func agentScrollToCapturePoint(y: Double) throws -> JSONValue {
        try callAgent(
            "return await globalThis.__headlessAgent.scrollToCapturePoint(args);",
            arguments: ["args": ["y": y]]
        )
    }

    func agentQAReport() -> JSONValue { qaBridge.store.report() }
    func agentQAClear() -> JSONValue { qaBridge.store.clear() }

    func agentConsole(level: String, limit: Int) -> JSONValue {
        qaBridge.store.console(level: level, limit: limit)
    }

    func agentNetwork(failedOnly: Bool, status: Int?, limit: Int) -> JSONValue {
        qaBridge.store.network(failedOnly: failedOnly, status: status, limit: limit)
    }

    func agentNetworkDetail(requestID: String) -> JSONValue {
        qaBridge.store.networkDetail(requestID: requestID)
    }

    func agentStyles(parameters: [String: JSONValue]) throws -> JSONValue {
        let args = try targetArguments(parameters)
        var input = args
        if case .array(let properties)? = parameters["properties"] {
            input["properties"] = properties.compactMap(\.stringValue)
        }
        return try callAgent("return globalThis.__headlessAgent.styles(args);", arguments: ["args": input])
    }

    func agentStorage(scope: String, includeValues: Bool) throws -> JSONValue {
        try requireSensitiveDiagnosticsIfNeeded(includeValues)
        return try callAgent(
            "return globalThis.__headlessAgent.storage(args);",
            arguments: ["args": ["scope": scope, "includeValues": includeValues]]
        )
    }

    func agentPerformance() throws -> JSONValue {
        try callAgent("return globalThis.__headlessAgent.performance();")
    }

    func agentAnimations() throws -> JSONValue {
        try callAgent("return globalThis.__headlessAgent.animations();")
    }

    func agentCookies(includeValues: Bool) throws -> JSONValue {
        try requireSensitiveDiagnosticsIfNeeded(includeValues)
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: [HTTPCookie] = []
        let currentURL = onMain { self.webView.url }
        onMain {
            self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                lock.lock(); result = cookies; lock.unlock(); semaphore.signal()
            }
        }
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw HostError(code: .timedOut, message: "Timed out while waiting for cookie inspection")
        }
        lock.lock(); let cookies = result; lock.unlock()
        let host = currentURL?.host?.lowercased()
        let visible = cookies.filter { cookie in
            guard let host else { return false }
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return host == domain || host.hasSuffix("." + domain)
        }
        let values: [JSONValue] = visible.prefix(200).map { cookie in
            var item: [String: JSONValue] = [
                "name": .string(String(cookie.name.prefix(512))),
                "domain": .string(String(cookie.domain.prefix(512))),
                "path": .string(String(cookie.path.prefix(512))),
                "secure": .bool(cookie.isSecure),
                "httpOnly": .bool(cookie.isHTTPOnly),
            ]
            if let expires = cookie.expiresDate { item["expiresAt"] = .number(expires.timeIntervalSince1970) }
            if includeValues { item["value"] = .string(String(cookie.value.prefix(16_384))) }
            else { item["valueBytes"] = .number(Double(cookie.value.utf8.count)) }
            return .object(item)
        }
        return .object([
            "origin": .string(currentURL?.absoluteString ?? ""),
            "cookies": .array(values),
            "returned": .number(Double(values.count)),
            "available": .number(Double(visible.count)),
            "truncated": .bool(visible.count > values.count),
            "source": .string("webkit-cookie-store"),
        ])
    }

    private func requireSensitiveDiagnosticsIfNeeded(_ requested: Bool) throws {
        guard !requested || ProcessInfo.processInfo.environment["HEADLESS_ALLOW_SENSITIVE_DIAGNOSTICS"] == "1" else {
            throw HostError(code: .sensitiveDiagnosticsDisabled, message: "Sensitive diagnostic values are disabled.")
        }
    }

    private func screenshotRect(_ object: [String: JSONValue]) throws -> CGRect {
        guard let x = object["x"]?.numberValue, let y = object["y"]?.numberValue,
              let width = object["width"]?.numberValue, let height = object["height"]?.numberValue,
              x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 64_000_000 else {
            throw HostError(code: .operationFailed, message: "Screenshot dimensions exceed safety limits")
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func targetArguments(_ parameters: [String: JSONValue]) throws -> [String: Any] {
        var args: [String: Any] = [:]
        if let target = parameters["target"]?.stringValue {
            guard target.hasPrefix("@e"), target.count <= 16 else {
                throw HostError(code: .operationFailed, message: "Invalid element reference")
            }
            args["target"] = target
        } else {
            if let role = parameters["role"]?.stringValue { args["role"] = role }
            if let name = parameters["name"]?.stringValue { args["name"] = name }
            guard !args.isEmpty else {
                throw HostError(code: .operationFailed, message: "Missing command parameter: target")
            }
        }
        return args
    }

    private func callAgent(
        _ body: String,
        arguments: [String: Any] = [:],
        timeout: TimeInterval = 10
    ) throws -> JSONValue {
        func evaluate(_ source: String) throws -> JSONValue {
            let semaphore = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var capturedResult: Result<Any, Error>?
            DispatchQueue.main.async {
                self.webView.callAsyncJavaScript(
                    source,
                    arguments: arguments,
                    in: nil,
                    in: agentWorld
                ) { result in
                    lock.lock()
                    capturedResult = result.map { $0 as Any }
                    lock.unlock()
                    semaphore.signal()
                }
            }
            guard semaphore.wait(timeout: .now() + timeout) == .success else {
                throw HostError(code: .timedOut, message: "Timed out while waiting for browser operation")
            }
            lock.lock()
            let result = capturedResult
            lock.unlock()
            guard let result else {
                throw HostError(code: .operationFailed, message: "Browser returned an invalid agent result")
            }
            do {
                return try unwrapAgentEvaluationResult(JSONValue.foundationValue(result.get()))
            } catch let error as HostError {
                throw error
            } catch {
                throw HostError(code: .operationFailed, message: String(describing: error))
            }
        }

        let runtimeUnavailable = "Headless agent runtime is not installed in this document"
        let guardedBody = """
        if (!globalThis.__headlessAgent) {
          const error = new Error('\(runtimeUnavailable)');
          error.headlessCode = 'OPERATION_FAILED';
          throw error;
        }
        \(body)
        """
        do {
            return try evaluate(agentEvaluationBody(guardedBody))
        } catch let error as HostError where error.code == .operationFailed && error.message == runtimeUnavailable {
            // WKWebView can expose its initial about:blank document before
            // document-start scripts run. Install once in that document, then
            // subsequent calls use the cached isolated-world runtime.
            return try evaluate(agentRuntimeJavaScript + "\n" + agentEvaluationBody(body))
        }
    }
}

private func onMain<T>(_ body: @escaping () -> T) -> T {
    if Thread.isMainThread { return body() }
    return DispatchQueue.main.sync(execute: body)
}
