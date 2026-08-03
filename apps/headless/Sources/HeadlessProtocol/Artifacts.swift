import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ArtifactError: Error, CustomStringConvertible {
    case invalidRoot
    case invalidName(String)
    case alreadyExists(String)
    case missing(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .invalidRoot: return "Artifact directory must be a private directory owned by the current user"
        case .invalidName(let name): return "Invalid artifact filename: \(name)"
        case .alreadyExists(let name): return "Artifact already exists: \(name)"
        case .missing(let name): return "Artifact does not exist: \(name)"
        case .writeFailed(let reason): return "Artifact operation failed: \(reason)"
        }
    }
}

public final class ArtifactStore: @unchecked Sendable {
    public let rootURL: URL
    private let lock = NSLock()

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        if let override = environment["HEADLESS_ARTIFACT_DIR"] {
            guard override.hasPrefix("/") else { throw ArtifactError.invalidRoot }
            rootURL = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        } else {
            #if os(macOS)
            rootURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Headless/Artifacts", isDirectory: true)
            #else
            let base: URL
            if let stateHome = environment["XDG_STATE_HOME"], stateHome.hasPrefix("/") {
                base = URL(fileURLWithPath: stateHome, isDirectory: true)
            } else {
                base = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/state", isDirectory: true)
            }
            rootURL = base.appendingPathComponent("headless/artifacts", isDirectory: true)
            #endif
        }
        try prepareRoot()
    }

    public func reserve(
        requestedName: String?, extension expectedExtension: String, prefix: String
    ) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let url = try destinationLocked(
            requestedName: requestedName,
            extension: expectedExtension,
            prefix: prefix
        )
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw ArtifactError.alreadyExists(url.lastPathComponent) }
            throw ArtifactError.writeFailed(String(cString: strerror(errno)))
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            let reason = String(cString: strerror(errno))
            _ = close(descriptor)
            _ = unlink(url.path)
            throw ArtifactError.writeFailed(reason)
        }
        _ = close(descriptor)
        return url
    }

    private func destinationLocked(
        requestedName: String?, extension expectedExtension: String, prefix: String
    ) throws -> URL {
        let name: String
        if let requestedName {
            do { try validateArtifactName(requestedName, expectedExtension: expectedExtension) }
            catch { throw ArtifactError.invalidName(requestedName) }
            name = requestedName
        } else {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            name = "\(prefix)-\(stamp)-\(UUID().uuidString.prefix(8)).\(expectedExtension)"
        }
        let url = rootURL.appendingPathComponent(name, isDirectory: false)
        guard url.deletingLastPathComponent().standardizedFileURL == rootURL.standardizedFileURL else {
            throw ArtifactError.invalidName(name)
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ArtifactError.alreadyExists(name)
        }
        return url
    }

    public func write(
        _ data: Data, requestedName: String?, extension expectedExtension: String, prefix: String
    ) throws -> JSONValue {
        let url = try reserve(requestedName: requestedName, extension: expectedExtension, prefix: prefix)
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            return try metadata(for: url)
        } catch {
            _ = unlink(url.path)
            throw ArtifactError.writeFailed(error.localizedDescription)
        }
    }

    public func writeReserved(_ data: Data, to url: URL) throws -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        guard url.deletingLastPathComponent().standardizedFileURL == rootURL.standardizedFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            throw ArtifactError.invalidName(url.lastPathComponent)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            return try metadata(for: url)
        } catch {
            throw ArtifactError.writeFailed(error.localizedDescription)
        }
    }

    public func discardReserved(_ urls: [URL]) {
        lock.lock(); defer { lock.unlock() }
        for url in urls where url.deletingLastPathComponent().standardizedFileURL == rootURL.standardizedFileURL {
            _ = unlink(url.path)
        }
    }

    public func finalize(_ source: URL, renameTo requestedName: String?) throws -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        var finalURL = source
        if let requestedName, requestedName != source.lastPathComponent {
            do { try validateArtifactName(requestedName, expectedExtension: source.pathExtension) }
            catch { throw ArtifactError.invalidName(requestedName) }
            let destination = rootURL.appendingPathComponent(requestedName)
            guard destination.deletingLastPathComponent().standardizedFileURL == rootURL.standardizedFileURL else {
                throw ArtifactError.invalidName(requestedName)
            }
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw ArtifactError.alreadyExists(requestedName)
            }
            do { try FileManager.default.moveItem(at: source, to: destination) }
            catch { throw ArtifactError.writeFailed(error.localizedDescription) }
            finalURL = destination
        }
        guard chmod(finalURL.path, 0o600) == 0 else {
            throw ArtifactError.writeFailed(String(cString: strerror(errno)))
        }
        return try metadata(for: finalURL)
    }

    public func list() throws -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )
        let artifacts = try urls.compactMap { url -> JSONValue? in
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  Self.listedExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            return try metadata(for: url)
        }.sorted { left, right in
            guard case .object(let lhs) = left, case .object(let rhs) = right else { return false }
            return (lhs["createdAt"]?.numberValue ?? 0) > (rhs["createdAt"]?.numberValue ?? 0)
        }
        return .object(["directory": .string(rootURL.path), "artifacts": .array(artifacts)])
    }

    private static let listedExtensions: Set<String> =
        ScreenshotFormat.artifactExtensions
        .union(RecordingFormat.artifactExtensions)
        .union(["json"])

    private func metadata(for url: URL) throws -> JSONValue {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? NSNumber)?.doubleValue ?? 0
        let created = (attributes[.creationDate] as? Date ?? Date()).timeIntervalSince1970
        return .object([
            "name": .string(url.lastPathComponent),
            "path": .string(url.path),
            "kind": .string(url.pathExtension.lowercased()),
            "bytes": .number(bytes),
            "createdAt": .number(created),
        ])
    }

    /// Reads only a regular artifact owned by this store. Callers never receive
    /// a path supplied by the agent, preventing an artifact command from
    /// becoming an arbitrary-file read primitive.
    public func read(name: String, expectedExtension: String, maximumBytes: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        do { try validateArtifactName(name, expectedExtension: expectedExtension) }
        catch { throw ArtifactError.invalidName(name) }
        let url = rootURL.appendingPathComponent(name, isDirectory: false)
        guard url.deletingLastPathComponent().standardizedFileURL == rootURL.standardizedFileURL else {
            throw ArtifactError.invalidName(name)
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ArtifactError.missing(name) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0,
              info.st_size <= off_t(maximumBytes) else {
            throw ArtifactError.writeFailed("Artifact is not a permitted regular file")
        }
        do { return try Data(contentsOf: url, options: [.mappedIfSafe]) }
        catch { throw ArtifactError.writeFailed(error.localizedDescription) }
    }

    private func prepareRoot() throws {
        do {
            try FileManager.default.createDirectory(
                at: rootURL, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch { throw ArtifactError.writeFailed(error.localizedDescription) }
        var info = stat()
        guard lstat(rootURL.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid() else { throw ArtifactError.invalidRoot }
        guard chmod(rootURL.path, 0o700) == 0 else { throw ArtifactError.invalidRoot }
    }
}
