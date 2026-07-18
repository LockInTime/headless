import Foundation

public enum ChromiumRuntimeSource: String, Sendable {
    case override
    case bundled
    case system
}

public struct ChromiumRuntimeSelection: Sendable {
    public let executableURL: URL
    public let source: ChromiumRuntimeSource

    public init(executableURL: URL, source: ChromiumRuntimeSource) {
        self.executableURL = executableURL
        self.source = source
    }

    public var diagnostic: JSONValue {
        .object([
            "engine": .string("chromium"),
            "executable": .string(executableURL.path),
            "source": .string(source.rawValue),
            "transport": .string("inherited-devtools-pipe"),
            "supported": .bool(true),
        ])
    }
}

public enum ChromiumRuntimeError: Error, CustomStringConvertible, Sendable {
    case invalidOverride(path: String, reason: String)
    case unsupportedSnap(path: String)
    case notFound

    public var description: String {
        let guidance = "Use the bundled Docker runtime or a native distribution Chromium binary. "
            + "HEADLESS_CHROMIUM_EXECUTABLE must name an absolute, non-Snap executable."
        switch self {
        case .invalidOverride(let path, let reason):
            return "Invalid Chromium executable override at \(path): \(reason). \(guidance)"
        case .unsupportedSnap(let path):
            return "Unsupported Chromium runtime at \(path): Ubuntu Snap Chromium is not reliable with the inherited DevTools pipe. \(guidance)"
        case .notFound:
            return "No supported Chromium runtime was found. Ubuntu Snap Chromium is not supported for the inherited DevTools pipe. \(guidance)"
        }
    }
}

/// Selects a local Chromium runtime without opening a remote-debugging socket.
/// Bundled and native binary locations are preferred over PATH wrappers. An
/// explicit override is authoritative and therefore fails closed when invalid.
public struct ChromiumRuntimeResolver {
    private let environment: [String: String]
    private let hostExecutablePath: String
    private let systemCandidates: [String]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hostExecutablePath: String = CommandLine.arguments[0]
    ) {
        self.environment = environment
        self.hostExecutablePath = hostExecutablePath
        self.systemCandidates = Self.defaultSystemCandidates(environment: environment)
    }

    /// Candidate injection keeps runtime selection regression-testable without
    /// launching Chromium or weakening the production selection policy.
    public init(
        environment: [String: String],
        hostExecutablePath: String,
        systemCandidates: [String]
    ) {
        self.environment = environment
        self.hostExecutablePath = hostExecutablePath
        self.systemCandidates = systemCandidates
    }

    public func resolve() throws -> ChromiumRuntimeSelection {
        if let override = environment["HEADLESS_CHROMIUM_EXECUTABLE"] {
            guard !override.isEmpty, override.hasPrefix("/") else {
                throw ChromiumRuntimeError.invalidOverride(
                    path: override.isEmpty ? "<empty>" : override,
                    reason: "the path must be absolute"
                )
            }
            if Self.isSnapPath(override) { throw ChromiumRuntimeError.unsupportedSnap(path: override) }
            do {
                return try selection(path: override, source: .override)
            } catch let error as ChromiumRuntimeError {
                throw error
            } catch {
                throw ChromiumRuntimeError.invalidOverride(path: override, reason: String(describing: error))
            }
        }

        var sawSnap: String?
        for candidate in bundledCandidates().map({ ($0, ChromiumRuntimeSource.bundled) })
            + systemCandidates.map({ ($0, ChromiumRuntimeSource.system) }) {
            guard !candidate.0.isEmpty, candidate.0.hasPrefix("/") else { continue }
            if Self.isSnapPath(candidate.0) {
                if FileManager.default.isExecutableFile(atPath: candidate.0) { sawSnap = candidate.0 }
                continue
            }
            do {
                return try selection(path: candidate.0, source: candidate.1)
            } catch ChromiumRuntimeError.unsupportedSnap(let path) {
                sawSnap = path
            } catch {
                continue
            }
        }
        if let sawSnap { throw ChromiumRuntimeError.unsupportedSnap(path: sawSnap) }
        throw ChromiumRuntimeError.notFound
    }

    private func selection(path: String, source: ChromiumRuntimeSource) throws -> ChromiumRuntimeSelection {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: path) else {
            throw ChromiumRuntimeError.invalidOverride(path: path, reason: "the file is missing or not executable")
        }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        if Self.isSnapPath(resolved.path) { throw ChromiumRuntimeError.unsupportedSnap(path: path) }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: resolved.path)
        } catch {
            throw ChromiumRuntimeError.invalidOverride(path: path, reason: "the resolved file cannot be inspected")
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ChromiumRuntimeError.invalidOverride(path: path, reason: "the resolved path is not a regular file")
        }
        if Self.isSnapWrapper(resolved) { throw ChromiumRuntimeError.unsupportedSnap(path: path) }
        return ChromiumRuntimeSelection(executableURL: resolved, source: source)
    }

    private func bundledCandidates() -> [String] {
        let host = URL(fileURLWithPath: hostExecutablePath).standardizedFileURL
        let bin = host.deletingLastPathComponent()
        return [
            bin.appendingPathComponent("chromium-runtime/chromium").path,
            bin.deletingLastPathComponent()
                .appendingPathComponent("lib/headless/chromium/chromium").path,
        ]
    }

    private static func defaultSystemCandidates(environment: [String: String]) -> [String] {
        var candidates = [
            "/usr/lib/chromium/chromium",
            "/usr/lib64/chromium/chromium",
            "/usr/lib64/chromium-browser/chromium-browser",
            "/opt/google/chrome/chrome",
            "/opt/google/chrome/google-chrome",
            "/usr/bin/chromium",
            "/usr/bin/chromium-browser",
            "/usr/bin/google-chrome-stable",
            "/usr/bin/google-chrome",
        ]
        let names = ["chromium", "chromium-browser", "google-chrome-stable", "google-chrome"]
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let path = String(directory)
            guard path.hasPrefix("/") else { continue }
            candidates.append(contentsOf: names.map { URL(fileURLWithPath: path).appendingPathComponent($0).path })
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func isSnapPath(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized == "/usr/bin/snap"
            || standardized == "/snap"
            || standardized.hasPrefix("/snap/")
            || standardized == "/var/lib/snapd/snap"
            || standardized.hasPrefix("/var/lib/snapd/snap/")
    }

    private static func isSnapWrapper(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384), data.starts(with: Data("#!".utf8)),
              let script = String(data: data, encoding: .utf8) else { return false }
        return script.contains("/snap/bin/")
            || script.contains("/usr/bin/snap")
            || script.contains("snap run ")
    }
}
