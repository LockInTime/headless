import Foundation

/// CDP defines header values as strings. Drop malformed values instead of
/// turning arbitrary JSON containers into implementation-dependent debug text.
public func diagnosticStringHeaders(_ headers: [String: Any]?) -> [String: String] {
    (headers ?? [:]).reduce(into: [:]) { result, entry in
        if let value = entry.value as? String { result[entry.key] = value }
    }
}

public final class QADiagnosticStore: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [JSONValue] = []
    private var didTruncate = false
    private let maximumEvents = 500
    /// A full report of 500 events, each carrying up to a 4 KiB message and an
    /// 8 KiB URL, can exceed the 1 MiB protocol frame. Encoding would then
    /// throw on the way out and the agent would receive a misleading
    /// INVALID_REQUEST for a request that was perfectly valid, so the arrays
    /// are bounded here and the response says what it dropped.
    private let maximumReportEventBytes = 384 * 1_024
    /// Issues are derived from the same events and carry the same message and
    /// URL, so a count cap alone is not a size cap: 100 issues built from 4 KiB
    /// messages and 8 KiB URLs is over a megabyte on its own.
    private let maximumReportIssueBytes = 192 * 1_024
    private let maximumReportIssues = 100

    public init() {}

    public func append(
        kind: String,
        level: String? = nil,
        message: String? = nil,
        url: String? = nil,
        method: String? = nil,
        status: Double? = nil,
        requestID: String? = nil,
        requestHeaders: [String: String]? = nil,
        responseHeaders: [String: String]? = nil,
        source: String? = nil,
        timestamp: Double = Date().timeIntervalSince1970
    ) {
        var event: [String: JSONValue] = [
            "kind": .string(bounded(kind, bytes: 64)),
            "timestamp": .number(timestamp),
        ]
        if let level { event["level"] = .string(bounded(level, bytes: 32)) }
        if let message { event["message"] = .string(bounded(message, bytes: 4_096)) }
        if let url { event["url"] = .string(bounded(redactedURL(url), bytes: 8_192)) }
        if let method { event["method"] = .string(bounded(method, bytes: 16)) }
        if let status, status.isFinite { event["status"] = .number(status) }
        if let requestID { event["requestId"] = .string(bounded(requestID, bytes: 128)) }
        if let requestHeaders { event["requestHeaders"] = headersValue(requestHeaders) }
        if let responseHeaders { event["responseHeaders"] = headersValue(responseHeaders) }
        if let source { event["source"] = .string(bounded(source, bytes: 64)) }
        lock.lock()
        events.append(.object(event))
        if events.count > maximumEvents {
            events.removeFirst(events.count - maximumEvents)
            didTruncate = true
        }
        lock.unlock()
    }

    public func clear() -> JSONValue {
        lock.lock(); let count = events.count; events.removeAll(); didTruncate = false; lock.unlock()
        return .object(["cleared": .number(Double(count))])
    }

    public func report() -> JSONValue {
        lock.lock(); let snapshot = events; let wasTruncated = didTruncate; lock.unlock()
        var consoleErrors = 0
        var pageErrors = 0
        var failedRequests = 0
        var httpErrors = 0
        for event in snapshot {
            guard case .object(let object) = event else { continue }
            switch object["kind"]?.stringValue {
            case "console":
                if ["error", "assert"].contains(object["level"]?.stringValue ?? "") { consoleErrors += 1 }
            case "page-error", "unhandled-rejection": pageErrors += 1
            case "request-failed": failedRequests += 1
            case "response":
                if (object["status"]?.numberValue ?? 0) >= 400 { httpErrors += 1 }
            default: break
            }
        }
        let issues = snapshot.compactMap(issue(for:))
        let errors = issues.filter { issue in
            guard case .object(let object) = issue else { return false }
            return object["severity"] == .string("error")
        }.count
        let warnings = issues.count - errors
        // Counts come from the whole snapshot; only the arrays are bounded, so
        // the summary stays accurate even when the payload is trimmed.
        let boundedIssues = valuesWithinBudget(
            Array(issues.suffix(maximumReportIssues)), bytes: maximumReportIssueBytes
        )
        let boundedEvents = valuesWithinBudget(snapshot, bytes: maximumReportEventBytes)
        let omittedIssues = issues.count - boundedIssues.count
        let omittedEvents = snapshot.count - boundedEvents.count
        return .object([
            "summary": .object([
                "events": .number(Double(snapshot.count)),
                "consoleErrors": .number(Double(consoleErrors)),
                "pageErrors": .number(Double(pageErrors)),
                "failedRequests": .number(Double(failedRequests)),
                "httpErrors": .number(Double(httpErrors)),
                "issues": .number(Double(issues.count)),
                "errors": .number(Double(errors)),
                "warnings": .number(Double(warnings)),
            ]),
            "issues": .array(boundedIssues),
            "events": .array(boundedEvents),
            "omitted": .object([
                "issues": .number(Double(omittedIssues)),
                "events": .number(Double(omittedEvents)),
            ]),
            "truncated": .bool(wasTruncated || omittedIssues > 0 || omittedEvents > 0),
        ])
    }

    /// Drops the oldest entries until the array fits its budget. Newest entries
    /// are the ones an agent is diagnosing, so they are the ones kept.
    private func valuesWithinBudget(_ values: [JSONValue], bytes: Int) -> [JSONValue] {
        var kept = values
        while kept.count > 1, encodedByteCount(kept) > bytes {
            kept.removeFirst(max(1, kept.count / 8))
        }
        if kept.count == 1, encodedByteCount(kept) > bytes { return [] }
        return kept
    }

    private func encodedByteCount(_ values: [JSONValue]) -> Int {
        guard let data = try? ProtocolCodec.encoder.encode(JSONValue.array(values)) else { return 0 }
        return data.count
    }

    public func console(level: String, limit: Int) -> JSONValue {
        lock.lock(); let snapshot = events; lock.unlock()
        let items = snapshot.filter { event in
            guard case .object(let object) = event, object["kind"] == .string("console") else { return false }
            return level == "all" || object["level"] == .string(level)
        }
        let boundedLimit = max(1, min(limit, 200))
        let boundedItems = Array(items.suffix(boundedLimit))
        return .object([
            "messages": .array(boundedItems),
            "returned": .number(Double(boundedItems.count)),
            "available": .number(Double(items.count)),
        ])
    }

    public func network(failedOnly: Bool, status: Int?, limit: Int) -> JSONValue {
        lock.lock(); let snapshot = events; lock.unlock()
        let matching = snapshot.filter { event in
            guard case .object(let object) = event,
                  ["response", "request-failed"].contains(object["kind"]?.stringValue ?? "") else { return false }
            if failedOnly,
               object["kind"]?.stringValue != "request-failed",
               (object["status"]?.numberValue ?? 0) < 400 { return false }
            if let status, Int(object["status"]?.numberValue ?? 0) != status { return false }
            return true
        }.map(networkSummary(_:))
        let bounded = Array(matching.suffix(max(1, min(limit, 200))))
        return .object([
            "requests": .array(bounded),
            "returned": .number(Double(bounded.count)),
            "available": .number(Double(matching.count)),
        ])
    }

    public func networkDetail(requestID: String) -> JSONValue {
        lock.lock(); let snapshot = events; lock.unlock()
        guard let event = snapshot.reversed().first(where: { event in
            guard case .object(let object) = event else { return false }
            return object["requestId"]?.stringValue == requestID
        }) else {
            return .object(["found": .bool(false), "requestId": .string(requestID)])
        }
        return .object(["found": .bool(true), "request": event])
    }

    private func issue(for event: JSONValue) -> JSONValue? {
        guard case .object(let object) = event,
              let eventKind = object["kind"]?.stringValue else { return nil }
        let message = object["message"]?.stringValue ?? ""
        let url = object["url"]?.stringValue
        let local = url.map(isLocalURL) ?? false
        let status = object["status"]?.numberValue
        let lower = message.lowercased()
        let framework = ["next", "react", "hydration", "webpack", "turbopack"].contains { lower.contains($0) }
        var issue: [String: JSONValue] = [:]

        func finish(_ severity: String, _ kind: String, _ text: String, _ suggestion: String) -> JSONValue {
            issue["severity"] = .string(severity)
            issue["kind"] = .string(kind)
            issue["message"] = .string(text)
            issue["suggestion"] = .string(suggestion)
            if let url { issue["url"] = .string(url) }
            if let status { issue["status"] = .number(status) }
            if let method = object["method"] { issue["method"] = method }
            if url != nil { issue["local"] = .bool(local) }
            return .object(issue)
        }

        switch eventKind {
        case "response" where (status ?? 0) >= 400:
            let code = Int(status ?? 0)
            if local && code == 404 {
                return finish("error", "local-not-found", "Local request returned HTTP 404.",
                              "The local route or static asset is missing. Check the URL, route, and dev-server output.")
            }
            if local && code >= 500 {
                return finish("error", "local-server-error", "Local request returned HTTP \(code).",
                              "The local development server failed. Check its terminal output and the framework error overlay.")
            }
            return finish("error", "http-error", "Request returned HTTP \(code).",
                          "Inspect the request URL, response, and server logs.")
        case "request-failed":
            return finish("error", local ? "local-request-failed" : "request-failed",
                          message.isEmpty ? "A request failed before receiving a response." : message,
                          local ? "The local app may be stopped or unreachable. Check the dev-server terminal and port."
                                : "Check network connectivity and the request URL.")
        case "page-error", "unhandled-rejection":
            return finish("error", framework ? "framework-error" : eventKind,
                          message.isEmpty ? "The page threw a runtime error." : message,
                          framework ? "Check the Next.js/React error overlay and development-server terminal."
                                    : "Inspect the stack trace and the component or script that threw this error.")
        case "console" where ["error", "assert"].contains(object["level"]?.stringValue ?? ""):
            return finish("error", framework ? "framework-error" : "console-error",
                          message.isEmpty ? "The page wrote an error to the console." : message,
                          framework ? "Check the Next.js/React error overlay and development-server terminal."
                                    : "Inspect the browser console and the code that emitted this error.")
        case "navigation-blocked", "download-blocked":
            return finish("warning", eventKind,
                          message.isEmpty ? "Unsafe browser action was blocked." : message,
                          eventKind == "download-blocked"
                            ? "Page downloads are disabled. Use an explicit Headless artifact instead."
                            : "Only normal HTTP(S) pages are allowed in an agent-controlled session.")
        default:
            return nil
        }
    }

    private func isLocalURL(_ value: String) -> Bool {
        guard let host = URL(string: value)?.host?.lowercased() else { return false }
        return isLocalDevelopmentHost(host)
    }

    private func redactedURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        components.user = nil
        components.password = nil
        return components.string ?? value
    }

    private func headersValue(_ headers: [String: String]) -> JSONValue {
        var safe: [String: JSONValue] = [:]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }).prefix(64) {
            let normalizedName = bounded(name, bytes: 128)
            safe[normalizedName] = .string(
                sensitiveHeader(normalizedName) ? "[redacted]" : bounded(value, bytes: 1_024)
            )
        }
        return .object(safe)
    }

    private func sensitiveHeader(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized == "authorization" || normalized == "proxy-authorization" ||
            normalized == "cookie" || normalized == "set-cookie" ||
            normalized.contains("api-key") || normalized.contains("token") ||
            normalized.contains("secret")
    }

    private func networkSummary(_ event: JSONValue) -> JSONValue {
        guard case .object(var object) = event else { return event }
        object.removeValue(forKey: "requestHeaders")
        object.removeValue(forKey: "responseHeaders")
        return .object(object)
    }

    private func bounded(_ value: String, bytes: Int) -> String {
        String(decoding: value.utf8.prefix(bytes), as: UTF8.self)
    }
}
