import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum CredentialTransactionKind: String, Codable, Sendable {
    case add
    case remove
}

public struct CredentialPendingTransaction: Codable, Equatable, Sendable {
    public let kind: CredentialTransactionKind
    public let record: CredentialRecord

    public init(kind: CredentialTransactionKind, record: CredentialRecord) {
        self.kind = kind
        self.record = record
    }
}

public struct CredentialMetadataState: Equatable, Sendable {
    public var records: [CredentialRecord]
    public var pending: [CredentialPendingTransaction]

    public init(
        records: [CredentialRecord] = [], pending: [CredentialPendingTransaction] = []
    ) {
        self.records = records
        self.pending = pending
    }
}

public final class CredentialMetadataTransaction {
    public var state: CredentialMetadataState
    private let persist: (CredentialMetadataState) throws -> Void

    fileprivate init(
        state: CredentialMetadataState,
        persist: @escaping (CredentialMetadataState) throws -> Void
    ) {
        self.state = state
        self.persist = persist
    }

    public func save() throws {
        try persist(state)
    }
}

private struct CredentialIndex: Codable {
    let schemaVersion: Int
    let records: [CredentialRecord]
    let pending: [CredentialPendingTransaction]?
}

public final class CredentialMetadataStore: @unchecked Sendable {
    public static let maximumIndexBytes = 1_048_576

    public let rootURL: URL
    private let indexURL: URL
    private let lockURL: URL

    public init(
        rootURL: URL = CredentialMetadataStore.defaultRootURL()
    ) {
        self.rootURL = rootURL.standardizedFileURL
        indexURL = self.rootURL.appendingPathComponent("credentials-index.json")
        lockURL = self.rootURL.appendingPathComponent("credentials-index.lock")
    }

    public static func defaultRootURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return home.appendingPathComponent(
            "Library/Application Support/com.headless.app/credential-vault", isDirectory: true
        )
        #else
        let base = home.appendingPathComponent(".local/share", isDirectory: true)
        return base.appendingPathComponent("headless/credential-vault", isDirectory: true)
        #endif
    }

    public func withLockedState<T>(
        _ body: (CredentialMetadataTransaction) throws -> T
    ) throws -> T {
        try preparePrivateDirectory(rootURL)
        let lock = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw CredentialVaultError.insecureMetadata }
        defer { close(lock) }
        try validatePrivateRegularFile(lock)
        guard flock(lock, LOCK_EX) == 0 else {
            throw CredentialVaultError.operationFailed("metadata lock")
        }
        defer { _ = flock(lock, LOCK_UN) }

        let transaction = CredentialMetadataTransaction(
            state: try readState(), persist: { [self] in try writeState($0) }
        )
        return try body(transaction)
    }

    private func readState() throws -> CredentialMetadataState {
        let descriptor = open(indexURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return CredentialMetadataState() }
            throw CredentialVaultError.insecureMetadata
        }
        defer { close(descriptor) }
        try validatePrivateRegularFile(descriptor)

        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= 0,
              info.st_size <= Self.maximumIndexBytes else {
            throw CredentialVaultError.corruptMetadata
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw CredentialVaultError.operationFailed("metadata read") }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= Self.maximumIndexBytes else { throw CredentialVaultError.corruptMetadata }
        }
        guard let index = try? JSONDecoder().decode(CredentialIndex.self, from: data),
              index.schemaVersion == 1 else {
            throw CredentialVaultError.corruptMetadata
        }
        let pending = index.pending ?? []
        let allRecords = index.records + pending.map(\.record)
        guard allRecords.count <= CredentialVaultController.maximumRecords,
              Set(allRecords.map(\.id)).count == allRecords.count,
              Set(allRecords.map {
                  "\($0.origin.rawValue)\u{0}\($0.alias.rawValue.lowercased())"
              }).count
                == allRecords.count else {
            throw CredentialVaultError.corruptMetadata
        }
        return CredentialMetadataState(records: index.records, pending: pending)
    }

    private func writeState(_ state: CredentialMetadataState) throws {
        let allRecords = state.records + state.pending.map(\.record)
        guard allRecords.count <= CredentialVaultController.maximumRecords,
              Set(allRecords.map(\.id)).count == allRecords.count,
              Set(allRecords.map {
                  "\($0.origin.rawValue)\u{0}\($0.alias.rawValue.lowercased())"
              }).count == allRecords.count else {
            throw CredentialVaultError.capacityExceeded
        }
        let data = try JSONEncoder.headlessCredentialEncoder.encode(
            CredentialIndex(schemaVersion: 1, records: state.records, pending: state.pending)
        )
        guard data.count <= Self.maximumIndexBytes else { throw CredentialVaultError.capacityExceeded }
        let temporary = rootURL.appendingPathComponent(".credentials-index.tmp-\(UUID().uuidString)")
        let descriptor = open(
            temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600
        )
        guard descriptor >= 0 else { throw CredentialVaultError.operationFailed("metadata creation") }
        var shouldRemove = true
        defer {
            close(descriptor)
            if shouldRemove { unlink(temporary.path) }
        }
        try validatePrivateRegularFile(descriptor)
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CredentialVaultError.operationFailed("metadata write") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw CredentialVaultError.operationFailed("metadata sync") }
        guard rename(temporary.path, indexURL.path) == 0 else {
            throw CredentialVaultError.operationFailed("metadata activation")
        }
        shouldRemove = false
        let directory = open(rootURL.path, O_RDONLY | O_CLOEXEC)
        if directory >= 0 {
            _ = fsync(directory)
            close(directory)
        }
    }

    private func preparePrivateDirectory(_ url: URL) throws {
        let parent = url.deletingLastPathComponent()
        if parent.path != url.path, !FileManager.default.fileExists(atPath: parent.path) {
            try preparePrivateDirectory(parent)
        }
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
                  (info.st_mode & 0o077) == 0 else {
                throw CredentialVaultError.insecureMetadata
            }
            return
        }
        guard errno == ENOENT, mkdir(url.path, 0o700) == 0 || errno == EEXIST else {
            throw CredentialVaultError.operationFailed("metadata directory creation")
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw CredentialVaultError.operationFailed("metadata directory permissions")
        }
    }

    private func validatePrivateRegularFile(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else {
            throw CredentialVaultError.insecureMetadata
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw CredentialVaultError.operationFailed("metadata permissions")
        }
    }
}

private extension JSONEncoder {
    static let headlessCredentialEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
