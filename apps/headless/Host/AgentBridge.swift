import AppKit
import HeadlessProtocol
import CoreFoundation
import Foundation
import WebKit

enum AgentOperationError: Error, CustomStringConvertible {
    case timedOut(String)
    case invalidResult
    case missingParameter(String)
    case elementNotFound(String)
    case operationFailed(String)

    var description: String {
        switch self {
        case .timedOut(let operation): return "Timed out while waiting for \(operation)"
        case .invalidResult: return "Browser returned an invalid agent result"
        case .missingParameter(let value): return "Missing command parameter: \(value)"
        case .elementNotFound(let value): return "Element was not found: \(value)"
        case .operationFailed(let value): return value
        }
    }
}

private let agentWorld = WKContentWorld.world(name: "HeadlessAgent")


extension BrowserWindowController {
    func agentVisit(_ url: URL, timeout: TimeInterval = 20) throws -> JSONValue {
        onMain { self.navigate(to: url) }
        Thread.sleep(forTimeInterval: 0.05)
        return try agentWait(parameters: ["settled": .bool(true), "timeoutMs": .number(timeout * 1_000)])
    }

    func agentInspect(interactive: Bool, includeText: Bool) throws -> JSONValue {
        try callAgent(
            "return globalThis.__headlessAgent.snapshot(interactive, includeText);",
            arguments: ["interactive": interactive, "includeText": includeText]
        )
    }

    func agentClick(parameters: [String: JSONValue]) throws -> JSONValue {
        let args = try targetArguments(parameters)
        return try callAgent("return globalThis.__headlessAgent.click(args);", arguments: ["args": args])
    }

    func agentFill(parameters: [String: JSONValue]) throws -> JSONValue {
        var args = try targetArguments(parameters)
        guard let value = parameters["value"]?.stringValue else { throw AgentOperationError.missingParameter("value") }
        args["value"] = value
        return try callAgent("return globalThis.__headlessAgent.fill(args);", arguments: ["args": args])
    }

    func agentPress(parameters: [String: JSONValue]) throws -> JSONValue {
        guard let key = parameters["key"]?.stringValue, !key.isEmpty, key.count <= 32 else {
            throw AgentOperationError.missingParameter("key")
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
            guard case .object(let state) = lastState else { throw AgentOperationError.invalidResult }
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

        throw AgentOperationError.timedOut("page condition")
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
        var requestedRect: CGRect?
        let hasTarget = parameters["target"] != nil || parameters["role"] != nil || parameters["name"] != nil
        if hasTarget {
            let args = try targetArguments(parameters)
            let value = try callAgent(
                "return globalThis.__headlessAgent.rectangle(args);", arguments: ["args": args]
            )
            guard case .object(let outer) = value, case .object(let rect)? = outer["viewport"] else {
                throw AgentOperationError.invalidResult
            }
            requestedRect = try screenshotRect(rect)
        } else if parameters["fullPage"]?.boolValue == true {
            let value = try callAgent("""
                return {x: 0, y: 0, width: document.documentElement.scrollWidth,
                        height: document.documentElement.scrollHeight};
                """)
            guard case .object(let rect) = value else { throw AgentOperationError.invalidResult }
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
                else { captured = .failure(error ?? AgentOperationError.invalidResult) }
                lock.unlock()
                semaphore.signal()
            }
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw AgentOperationError.timedOut("screenshot")
        }
        lock.lock(); let result = captured; lock.unlock()
        guard let image = try result?.get(),
              let representation = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: representation),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AgentOperationError.invalidResult
        }
        return png
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
            throw AgentOperationError.timedOut("cookie inspection")
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
            throw AgentOperationError.operationFailed("SENSITIVE_DIAGNOSTICS_DISABLED")
        }
    }

    private func screenshotRect(_ object: [String: JSONValue]) throws -> CGRect {
        guard let x = object["x"]?.numberValue, let y = object["y"]?.numberValue,
              let width = object["width"]?.numberValue, let height = object["height"]?.numberValue,
              x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 64_000_000 else {
            throw AgentOperationError.operationFailed("Screenshot dimensions exceed safety limits")
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func targetArguments(_ parameters: [String: JSONValue]) throws -> [String: Any] {
        var args: [String: Any] = [:]
        if let target = parameters["target"]?.stringValue {
            guard target.hasPrefix("@e"), target.count <= 16 else {
                throw AgentOperationError.operationFailed("Invalid element reference")
            }
            args["target"] = target
        } else {
            if let role = parameters["role"]?.stringValue { args["role"] = role }
            if let name = parameters["name"]?.stringValue { args["name"] = name }
            guard !args.isEmpty else { throw AgentOperationError.missingParameter("target") }
        }
        return args
    }

    private func callAgent(
        _ body: String,
        arguments: [String: Any] = [:],
        timeout: TimeInterval = 10
    ) throws -> JSONValue {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var capturedResult: Result<Any, Error>?
        DispatchQueue.main.async {
            self.webView.callAsyncJavaScript(
                agentRuntimeJavaScript + "\n" + body,
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
            throw AgentOperationError.timedOut("browser operation")
        }
        lock.lock()
        let result = capturedResult
        lock.unlock()
        guard let result else { throw AgentOperationError.invalidResult }
        do {
            return try jsonValue(from: result.get())
        } catch let error as AgentOperationError {
            throw error
        } catch {
            let message = String(describing: error)
            if message.contains("ELEMENT_NOT_FOUND:") { throw AgentOperationError.elementNotFound(message) }
            throw AgentOperationError.operationFailed(message)
        }
    }
}

private func onMain<T>(_ body: @escaping () -> T) -> T {
    if Thread.isMainThread { return body() }
    return DispatchQueue.main.sync(execute: body)
}

private func jsonValue(from value: Any) throws -> JSONValue {
    switch value {
    case let value as String: return .string(value)
    case let value as NSNumber:
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
        return .number(value.doubleValue)
    case let value as [Any]: return .array(try value.map(jsonValue(from:)))
    case let value as [String: Any]:
        return .object(try value.mapValues(jsonValue(from:)))
    case is NSNull: return .null
    default: throw AgentOperationError.invalidResult
    }
}
