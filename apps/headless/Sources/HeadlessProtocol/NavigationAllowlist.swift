import Foundation

public let headlessNavigationAllowlistEnvironmentKey = "HEADLESS_NAVIGATION_ALLOWLIST"

public enum NavigationAllowlistError: Error, Equatable, CustomStringConvertible {
    case empty
    case tooManyPatterns
    case invalidPattern(String)

    public var description: String {
        switch self {
        case .empty:
            return "Navigation allowlist requires at least one host pattern."
        case .tooManyPatterns:
            return "Navigation allowlist accepts at most \(NavigationAllowlist.maximumPatternCount) host patterns."
        case .invalidPattern(let pattern):
            return "Invalid navigation allowlist pattern: \(pattern)"
        }
    }
}

/// Host patterns that further restrict otherwise-legal HTTP(S) navigation.
/// An empty list is unrestricted; the scheme, credential, and extension
/// checks in `normalizedWebURL` / `agentMayNavigate` still apply.
public struct NavigationAllowlist: Equatable, Sendable {
    public static let unrestricted = NavigationAllowlist(compiled: [], denyAll: false)
    public static let maximumPatternCount = 32

    private let compiled: [CompiledPattern]
    private let denyAll: Bool

    public let patterns: [String]

    public var isRestricted: Bool { !patterns.isEmpty }

    public var environmentValue: String { patterns.joined(separator: ",") }

    public var jsonValue: JSONValue { .array(patterns.map(JSONValue.string)) }

    public var agentRuntimePreamble: String {
        "globalThis.__headlessNavigationAllowlist = Object.freeze(\(jsonArrayLiteral));\n"
    }

    private init(compiled: [CompiledPattern], denyAll: Bool) {
        self.compiled = compiled
        self.denyAll = denyAll
        self.patterns = compiled.map(\.canonical)
    }

    /// Parses CLI `--allow` values. Each value may be a single pattern or a
    /// comma-separated list. Empty input is invalid; use `unrestricted`.
    public static func parse(_ values: [String]) throws -> NavigationAllowlist {
        var tokens: [String] = []
        for value in values {
            tokens.append(contentsOf: value.split(separator: ",", omittingEmptySubsequences: false).map(String.init))
        }
        return try NavigationAllowlist(tokens: tokens)
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        try self.init(environmentValue: environment[headlessNavigationAllowlistEnvironmentKey])
    }

    public init(environmentValue: String?) throws {
        guard let environmentValue else {
            self = .unrestricted
            return
        }
        let trimmed = environmentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            self = .unrestricted
            return
        }
        self = try NavigationAllowlist.parse([trimmed])
    }

    public func allows(_ url: URL) -> Bool {
        if denyAll { return false }
        if compiled.isEmpty { return true }
        guard let host = navigationHost(of: url) else { return false }
        let port = effectiveNavigationPort(of: url)
        return compiled.contains { $0.matches(host: host, port: port) }
    }

    private init(tokens: [String]) throws {
        var unique: [CompiledPattern] = []
        var seen: Set<String> = []
        for token in tokens {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw NavigationAllowlistError.empty }
            let compiled = try CompiledPattern.parse(trimmed)
            if seen.insert(compiled.canonical).inserted {
                unique.append(compiled)
                if unique.count > NavigationAllowlist.maximumPatternCount {
                    throw NavigationAllowlistError.tooManyPatterns
                }
            }
        }
        if unique.isEmpty { throw NavigationAllowlistError.empty }
        self.init(compiled: unique, denyAll: false)
    }

    fileprivate static let denyAllList = NavigationAllowlist(compiled: [], denyAll: true)

    private var jsonArrayLiteral: String {
        "[" + patterns.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }
}

/// Loaded once from `HEADLESS_NAVIGATION_ALLOWLIST`. Missing or empty means
/// unrestricted. Invalid values fail closed and deny every navigation.
public let processNavigationAllowlist: NavigationAllowlist = {
    do {
        return try NavigationAllowlist(environment: ProcessInfo.processInfo.environment)
    } catch {
        return NavigationAllowlist.denyAllList
    }
}()

private struct CompiledPattern: Equatable, Sendable {
    let wildcard: Bool
    let host: String
    let port: Int?

    var canonical: String {
        (wildcard ? "*." : "") + host + (port.map { ":\($0)" } ?? "")
    }

    func matches(host: String, port: Int?) -> Bool {
        let hostMatches: Bool
        if wildcard {
            hostMatches = host != self.host && host.hasSuffix("." + self.host)
        } else {
            hostMatches = host == self.host
        }
        if let required = self.port {
            return hostMatches && port == required
        }
        return hostMatches
    }

    static func parse(_ raw: String) throws -> CompiledPattern {
        if raw != raw.trimmingCharacters(in: .whitespacesAndNewlines)
            || raw.contains(where: { $0.isWhitespace || !$0.isASCII })
            || raw.contains("/")
            || raw.contains("@")
            || raw.contains("\\")
            || raw.contains("://")
            || raw == "*" {
            throw NavigationAllowlistError.invalidPattern(raw)
        }
        if raw.utf8.count > 300 {
            throw NavigationAllowlistError.invalidPattern(raw)
        }

        var rest = raw
        var wildcard = false
        if rest.hasPrefix("*.") {
            wildcard = true
            rest.removeFirst(2)
        } else if rest.contains("*") {
            throw NavigationAllowlistError.invalidPattern(raw)
        }
        guard !rest.isEmpty else { throw NavigationAllowlistError.invalidPattern(raw) }

        var host = rest
        var port: Int?
        if let colon = rest.firstIndex(of: ":") {
            guard rest.lastIndex(of: ":") == colon else {
                throw NavigationAllowlistError.invalidPattern(raw)
            }
            host = String(rest[..<colon])
            let portText = String(rest[rest.index(after: colon)...])
            guard let parsed = parsePort(portText) else {
                throw NavigationAllowlistError.invalidPattern(raw)
            }
            port = parsed
        }
        guard !host.isEmpty else { throw NavigationAllowlistError.invalidPattern(raw) }

        if isDottedNumeric(host) {
            guard isValidIPv4(host), !wildcard else {
                throw NavigationAllowlistError.invalidPattern(raw)
            }
        } else if !isValidHostname(host) {
            throw NavigationAllowlistError.invalidPattern(raw)
        }

        return CompiledPattern(wildcard: wildcard, host: host.lowercased(), port: port)
    }
}

private func parsePort(_ text: String) -> Int? {
    guard !text.isEmpty, text.allSatisfy(\.isNumber), text.count <= 5 else { return nil }
    if text.count > 1 && text.hasPrefix("0") { return nil }
    guard let port = Int(text), (1...65_535).contains(port) else { return nil }
    return port
}

private func isDottedNumeric(_ host: String) -> Bool {
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    return labels.count == 4 && labels.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
}

private func isValidIPv4(_ host: String) -> Bool {
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count == 4 else { return false }
    for label in labels {
        guard !label.isEmpty, label.count <= 3, label.allSatisfy(\.isNumber) else { return false }
        if label.count > 1 && label.hasPrefix("0") { return false }
        guard let value = Int(label), (0...255).contains(value) else { return false }
    }
    return true
}

private func isValidHostname(_ host: String) -> Bool {
    guard !host.isEmpty, host.utf8.count <= 253 else { return false }
    guard !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else { return false }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard !labels.isEmpty else { return false }
    for label in labels {
        guard (1...63).contains(label.count) else { return false }
        guard let first = label.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        guard let last = label.last, last.isASCII, last.isLetter || last.isNumber else { return false }
        guard label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            return false
        }
    }
    return true
}

private func navigationHost(of url: URL) -> String? {
    let raw = url.host ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.host
    guard var host = raw?.lowercased(), !host.isEmpty else { return nil }
    if host.hasSuffix(".") { host.removeLast() }
    return host
}

private func effectiveNavigationPort(of url: URL) -> Int? {
    if let port = url.port { return port }
    if let port = URLComponents(url: url, resolvingAgainstBaseURL: false)?.port { return port }
    switch url.scheme?.lowercased() {
    case "http": return 80
    case "https": return 443
    default: return nil
    }
}
