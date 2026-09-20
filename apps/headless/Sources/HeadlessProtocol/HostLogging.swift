import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum HostLogError: Error, CustomStringConvertible {
    case invalidOverride
    case insecureParent
    case insecureFile
    case operationFailed(String)

    public var description: String {
        switch self {
        case .invalidOverride:
            return "HEADLESS_HOST_LOG must be an absolute file path"
        case .insecureParent:
            return "Host log parent is not a permitted directory"
        case .insecureFile:
            return "Host log is not a private regular file owned by the current user"
        case .operationFailed(let operation):
            return "Host log \(operation) failed: \(String(cString: strerror(errno)))"
        }
    }
}

public struct HostLogStore {
    public static let maximumFileBytes = 1_048_576
    public static let maximumLineBytes = 8_192

    public let url: URL
    public let archiveURL: URL
    public let lockURL: URL
    public let maximumBytes: Int

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maximumBytes: Int = HostLogStore.maximumFileBytes
    ) throws {
        guard maximumBytes >= HostLogStore.maximumLineBytes,
              maximumBytes <= HostLogStore.maximumFileBytes else {
            throw HostLogError.operationFailed("size configuration")
        }
        if let override = environment["HEADLESS_HOST_LOG"] {
            guard override.hasPrefix("/") else { throw HostLogError.invalidOverride }
            let supplied = URL(fileURLWithPath: override).standardizedFileURL
            let parentPath = supplied.deletingLastPathComponent().path
            guard let resolvedPointer = realpath(parentPath, nil) else {
                throw HostLogError.insecureParent
            }
            defer { free(resolvedPointer) }
            let resolvedParent = URL(fileURLWithPath: String(cString: resolvedPointer), isDirectory: true)
            url = resolvedParent.appendingPathComponent(supplied.lastPathComponent, isDirectory: false)
        } else {
            try LocalRuntime.preparePrivateDirectory()
            url = LocalRuntime.directoryURL.appendingPathComponent("host.log", isDirectory: false)
        }
        guard url.lastPathComponent != ".", url.lastPathComponent != "..",
              url.deletingLastPathComponent().path != url.path else {
            throw HostLogError.invalidOverride
        }
        archiveURL = URL(fileURLWithPath: url.path + ".1")
        lockURL = URL(fileURLWithPath: url.path + ".lock")
        self.maximumBytes = maximumBytes
    }

    public func prepare() throws {
        try withLock {
            let descriptor = try openPrivateLog(append: true)
            guard systemClose(descriptor) == 0 else { throw HostLogError.operationFailed("close") }
        }
    }

    public func consume(_ input: FileHandle) throws {
        var pending = Data()
        var deferredError: Error?

        func append(_ line: Data) {
            guard deferredError == nil else { return }
            do { try appendStructuredLine(line) }
            catch { deferredError = error }
        }

        while true {
            let chunk = try input.read(upToCount: 16_384) ?? Data()
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                append(Data(line))
            }
            if pending.count > Self.maximumLineBytes * 2 {
                append(Data(pending.prefix(Self.maximumLineBytes)))
                pending.removeAll(keepingCapacity: true)
            }
        }
        if !pending.isEmpty { append(pending) }
        if let deferredError { throw deferredError }
    }

    public func diagnosticTail(maximumBytes: Int = 8_192) -> String? {
        guard maximumBytes > 0 else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1,
              (info.st_mode & 0o077) == 0 else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { _ = systemClose(descriptor) }
        guard fstat(descriptor, &info) == 0, info.st_size >= 0 else { return nil }
        let count = min(maximumBytes, Int(info.st_size))
        guard lseek(descriptor, off_t(-count), SEEK_END) >= 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let readCount = bytes.withUnsafeMutableBytes { buffer in
                systemRead(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
            }
            if readCount < 0 && errno == EINTR { continue }
            guard readCount > 0 else { break }
            offset += readCount
        }
        guard offset > 0 else { return nil }
        let text = String(decoding: bytes.prefix(offset), as: UTF8.self)
        if let newline = text.firstIndex(of: "\n"), count == maximumBytes {
            return String(text[text.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendStructuredLine(_ raw: Data) throws {
        let messageLimit = 3_500
        var message = String(decoding: raw.prefix(messageLimit), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        message = Self.redacted(message)
        if raw.count > messageLimit { message += " [truncated]" }
        let record: [String: String] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "source": "host",
            "message": message,
        ]
        var encoded = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        encoded.append(0x0A)
        guard encoded.count <= Self.maximumLineBytes else {
            throw HostLogError.operationFailed("record encoding")
        }
        try withLock {
            try rotateIfNeeded(incomingBytes: encoded.count)
            let descriptor = try openPrivateLog(append: true)
            defer { _ = systemClose(descriptor) }
            try writeAll(encoded, to: descriptor)
        }
    }

    private func rotateIfNeeded(incomingBytes: Int) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw HostLogError.operationFailed("status")
        }
        try validatePrivateRegularFile(info)
        guard Int(info.st_size) + incomingBytes > maximumBytes else { return }

        if lstat(archiveURL.path, &info) == 0 {
            try validatePrivateRegularFile(info)
            guard unlink(archiveURL.path) == 0 else { throw HostLogError.operationFailed("archive removal") }
        } else if errno != ENOENT {
            throw HostLogError.operationFailed("archive status")
        }
        guard rename(url.path, archiveURL.path) == 0 else {
            throw HostLogError.operationFailed("rotation")
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try validateParent()
        let descriptor = open(
            lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)
        )
        guard descriptor >= 0 else { throw HostLogError.operationFailed("lock open") }
        defer { _ = systemClose(descriptor) }
        try validatePrivateRegularDescriptor(descriptor)
        guard flock(descriptor, LOCK_EX) == 0 else { throw HostLogError.operationFailed("lock") }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func validateParent() throws {
        var info = stat()
        let parent = url.deletingLastPathComponent().path
        guard lstat(parent, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw HostLogError.insecureParent
        }
        if parent == LocalRuntime.directoryURL.path {
            guard info.st_uid == geteuid(), (info.st_mode & 0o077) == 0 else {
                throw HostLogError.insecureParent
            }
        }
    }

    private func openPrivateLog(append: Bool) throws -> Int32 {
        let flags = O_CREAT | O_WRONLY | O_CLOEXEC | O_NOFOLLOW | (append ? O_APPEND : O_TRUNC)
        let descriptor = open(url.path, flags, mode_t(0o600))
        guard descriptor >= 0 else { throw HostLogError.operationFailed("open") }
        do { try validatePrivateRegularDescriptor(descriptor) }
        catch {
            _ = systemClose(descriptor)
            throw error
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            _ = systemClose(descriptor)
            throw HostLogError.operationFailed("permissions")
        }
        return descriptor
    }

    private func validatePrivateRegularDescriptor(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw HostLogError.operationFailed("validation") }
        try validatePrivateRegularFile(info)
    }

    private func validatePrivateRegularFile(_ info: stat) throws {
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              (info.st_mode & 0o077) == 0 else {
            throw HostLogError.insecureFile
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = systemWrite(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw HostLogError.operationFailed("write") }
                offset += count
            }
        }
    }

    private static func redacted(_ source: String) -> String {
        var result = source
        let replacements = [
            (
                #"(?i)(["']?(?:authorization|cookie|set-cookie)["']?\s*[:=]\s*).*$"#,
                "$1[REDACTED]"
            ),
            (
                #"(?i)(["']?(?:password|passwd|token|secret)["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;]+)"#,
                "$1[REDACTED]"
            ),
            (#"(?i)(https?://)[^\s/@:]+:[^\s/@]+@"#, "$1[REDACTED]@"),
        ]
        for (pattern, replacement) in replacements {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: replacement
            )
        }
        return result
    }
}

private func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.read(descriptor, buffer, count)
    #else
    return Glibc.read(descriptor, buffer, count)
    #endif
}

private func systemWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.write(descriptor, buffer, count)
    #else
    return Glibc.write(descriptor, buffer, count)
    #endif
}

private func systemClose(_ descriptor: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(descriptor)
    #else
    return Glibc.close(descriptor)
    #endif
}
