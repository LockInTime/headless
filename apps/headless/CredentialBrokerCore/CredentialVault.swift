import CHeadlessSecurePrompt
import Foundation
import HeadlessProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct CredentialRecord: Codable, Equatable, Sendable {
    public let id: String
    public let origin: CredentialOrigin
    public let alias: CredentialAlias
    public let account: String
    public let createdAt: Double

    public init(
        id: String = UUID().uuidString.lowercased(),
        origin: CredentialOrigin,
        alias: CredentialAlias,
        account: String,
        createdAt: Double = Date().timeIntervalSince1970
    ) throws {
        guard UUID(uuidString: id) != nil else { throw CredentialVaultError.corruptMetadata }
        self.id = id.lowercased()
        self.origin = origin
        self.alias = alias
        self.account = try validatedCredentialAccount(account)
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, origin, alias, account, createdAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            origin: container.decode(CredentialOrigin.self, forKey: .origin),
            alias: container.decode(CredentialAlias.self, forKey: .alias),
            account: container.decode(String.self, forKey: .account),
            createdAt: container.decode(Double.self, forKey: .createdAt)
        )
    }

    public var publicValue: JSONValue {
        .object([
            "origin": .string(origin.rawValue),
            "alias": .string(alias.rawValue),
            "username": .string(account),
        ])
    }
}

public func validatedCredentialAccount(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 320,
          !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
        throw CredentialVaultError.invalidAccount
    }
    return trimmed
}

public enum CredentialVaultError: Error, Equatable, CustomStringConvertible {
    case invalidAccount
    case duplicateAlias
    case notFound
    case capacityExceeded
    case vaultUnavailable
    case vaultLocked
    case userPresenceUnavailable
    case userDenied
    case corruptMetadata
    case insecureMetadata
    case terminalRequired
    case promptFailed
    case operationFailed(String)

    public var code: String {
        switch self {
        case .invalidAccount: return "INVALID_ACCOUNT"
        case .duplicateAlias: return "CREDENTIAL_ALIAS_EXISTS"
        case .notFound: return "CREDENTIAL_NOT_FOUND"
        case .capacityExceeded: return "CREDENTIAL_LIMIT_REACHED"
        case .vaultUnavailable: return "VAULT_UNAVAILABLE"
        case .vaultLocked: return "VAULT_LOCKED"
        case .userPresenceUnavailable: return "USER_PRESENCE_UNAVAILABLE"
        case .userDenied: return "USER_PRESENCE_DENIED"
        case .corruptMetadata: return "VAULT_METADATA_CORRUPT"
        case .insecureMetadata: return "VAULT_METADATA_INSECURE"
        case .terminalRequired: return "SECURE_TERMINAL_REQUIRED"
        case .promptFailed: return "SECURE_PROMPT_FAILED"
        case .operationFailed: return "VAULT_OPERATION_FAILED"
        }
    }

    public var description: String {
        switch self {
        case .invalidAccount:
            return "Account identity must be 1-320 characters without control characters."
        case .duplicateAlias:
            return "That credential alias already exists for this origin."
        case .notFound:
            return "No credential matches that exact origin and alias."
        case .capacityExceeded:
            return "The credential vault has reached its 1,000-record limit."
        case .vaultUnavailable:
            return "An approved operating-system credential vault is unavailable."
        case .vaultLocked:
            return "The operating-system credential vault is locked."
        case .userPresenceUnavailable:
            return "A trusted per-use user-presence mechanism is unavailable."
        case .userDenied:
            return "The user denied credential-vault authorization."
        case .corruptMetadata:
            return "Credential index metadata is corrupt or uses an unsupported schema."
        case .insecureMetadata:
            return "Credential index metadata is not a private regular file owned by this user."
        case .terminalRequired:
            return "Interactive credential entry requires an attached terminal; piped input is rejected."
        case .promptFailed:
            return "Secure terminal input failed. Terminal echo was restored."
        case .operationFailed(let operation):
            return "Credential vault operation failed: \(operation)."
        }
    }
}

public final class SensitiveBytes: @unchecked Sendable {
    private var storage: [UInt8]

    public init(_ bytes: [UInt8]) {
        storage = bytes
    }

    deinit { clear() }

    public var isEmpty: Bool { storage.isEmpty }

    public func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        try storage.withUnsafeBytes(body)
    }

    public func matches(_ other: SensitiveBytes) -> Bool {
        guard storage.count == other.storage.count else { return false }
        var difference: UInt8 = 0
        for index in storage.indices { difference |= storage[index] ^ other.storage[index] }
        return difference == 0
    }

    public func clear() {
        storage.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            headless_secure_clear(base.assumingMemoryBound(to: UInt8.self), buffer.count)
        }
        storage.removeAll(keepingCapacity: false)
    }
}

public protocol CredentialSecretStore {
    var backendName: String { get }
    func store(_ secret: SensitiveBytes, for record: CredentialRecord) throws
    func load(recordID: String) throws -> SensitiveBytes
    func remove(recordID: String) throws
}

public protocol CredentialPrompting {
    func readAccount() throws -> String
    func readPassword() throws -> SensitiveBytes
    func readPasswordConfirmation() throws -> SensitiveBytes
}

public struct SecureTerminalPrompt: CredentialPrompting {
    public init() {}

    public func readAccount() throws -> String {
        try validatedCredentialAccount(read(prompt: "Account username/email: ", hidden: false, maximum: 320))
    }

    public func readPassword() throws -> SensitiveBytes {
        SensitiveBytes(Array(try readBytes(prompt: "Password: ", hidden: true, maximum: 4_096)))
    }

    public func readPasswordConfirmation() throws -> SensitiveBytes {
        SensitiveBytes(Array(try readBytes(
            prompt: "Confirm password: ", hidden: true, maximum: 4_096
        )))
    }

    private func read(prompt: String, hidden: Bool, maximum: Int) throws -> String {
        let bytes = try readBytes(prompt: prompt, hidden: hidden, maximum: maximum)
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw CredentialVaultError.promptFailed
        }
        return value
    }

    private func readBytes(prompt: String, hidden: Bool, maximum: Int) throws -> [UInt8] {
        var pointer: UnsafeMutablePointer<UInt8>?
        var count = 0
        let result = prompt.withCString {
            headless_read_tty_line($0, hidden ? 1 : 0, &pointer, &count)
        }
        guard result == Int32(HEADLESS_PROMPT_SUCCESS.rawValue), let pointer else {
            if result == Int32(HEADLESS_PROMPT_NOT_TTY.rawValue)
                || result == Int32(HEADLESS_PROMPT_OPEN_FAILED.rawValue)
                || result == Int32(HEADLESS_PROMPT_NOT_FOREGROUND.rawValue) {
                throw CredentialVaultError.terminalRequired
            }
            throw CredentialVaultError.promptFailed
        }
        defer { headless_clear_and_free(pointer, count + 1) }
        guard count <= maximum else { throw CredentialVaultError.promptFailed }
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
}

public final class CredentialVaultController {
    public static let maximumRecords = 1_000
    public static let maximumListedRecords = 500

    private let metadata: CredentialMetadataStore
    private let secrets: CredentialSecretStore
    private let prompt: CredentialPrompting

    public init(
        metadata: CredentialMetadataStore,
        secrets: CredentialSecretStore,
        prompt: CredentialPrompting = SecureTerminalPrompt()
    ) {
        self.metadata = metadata
        self.secrets = secrets
        self.prompt = prompt
    }

    public func list(origin: CredentialOrigin?) throws -> JSONValue {
        try withRecoveredState { transaction in
            let matching = transaction.state.records.filter { origin == nil || $0.origin == origin }
                .sorted { ($0.origin.rawValue, $0.alias.rawValue) < ($1.origin.rawValue, $1.alias.rawValue) }
            let listed = Array(matching.prefix(Self.maximumListedRecords))
            return .object([
                "credentials": .array(listed.map(\.publicValue)),
                "total": .number(Double(matching.count)),
                "omitted": .number(Double(matching.count - listed.count)),
                "truncated": .bool(listed.count < matching.count),
                "passwordsExposed": .bool(false),
            ])
        }
    }

    public func aliases(origin: CredentialOrigin) throws -> [AuthenticationAlias] {
        let records = try withRecoveredState { transaction in
            transaction.state.records.filter { $0.origin == origin }.sorted {
                $0.alias.rawValue < $1.alias.rawValue
            }
        }
        return try records.map { try AuthenticationAlias(alias: $0.alias, account: $0.account) }
    }

    public func resolve(
        origin: CredentialOrigin, alias: CredentialAlias
    ) throws -> AuthenticationCredential {
        let record = try withRecoveredState { transaction -> CredentialRecord in
            guard let record = transaction.state.records.first(where: {
                $0.origin == origin
                    && $0.alias.rawValue.caseInsensitiveCompare(alias.rawValue) == .orderedSame
            }) else { throw CredentialVaultError.notFound }
            return record
        }
        let secret = try secrets.load(recordID: record.id)
        defer { secret.clear() }
        return try AuthenticationCredential(
            account: record.account,
            password: AuthenticationSecret(secret.withUnsafeBytes { Array($0) })
        )
    }

    public func add(origin: CredentialOrigin, alias: CredentialAlias) throws -> JSONValue {
        try withRecoveredState { transaction in
            guard transaction.state.records.count < Self.maximumRecords else {
                throw CredentialVaultError.capacityExceeded
            }
            guard !transaction.state.records.contains(where: {
                $0.origin == origin
                    && $0.alias.rawValue.caseInsensitiveCompare(alias.rawValue) == .orderedSame
            }) else { throw CredentialVaultError.duplicateAlias }
        }
        let account = try prompt.readAccount()
        let secret = try prompt.readPassword()
        defer { secret.clear() }
        guard !secret.isEmpty else { throw CredentialVaultError.promptFailed }
        let confirmation = try prompt.readPasswordConfirmation()
        defer { confirmation.clear() }
        guard secret.matches(confirmation) else {
            throw CredentialVaultError.operationFailed("password confirmation did not match")
        }

        return try withRecoveredState { transaction in
            guard transaction.state.records.count < Self.maximumRecords else {
                throw CredentialVaultError.capacityExceeded
            }
            guard !transaction.state.records.contains(where: {
                $0.origin == origin
                    && $0.alias.rawValue.caseInsensitiveCompare(alias.rawValue) == .orderedSame
            }) else {
                throw CredentialVaultError.duplicateAlias
            }
            let record = try CredentialRecord(origin: origin, alias: alias, account: account)
            let pending = CredentialPendingTransaction(kind: .add, record: record)
            transaction.state.pending.append(pending)
            try transaction.save()
            do {
                try secrets.store(secret, for: record)
            } catch {
                do {
                    try secrets.remove(recordID: record.id)
                    transaction.state.pending.removeAll { $0.record.id == record.id }
                    try transaction.save()
                } catch { throw CredentialVaultError.operationFailed("add rollback") }
                throw error
            }
            transaction.state.records.append(record)
            transaction.state.pending.removeAll { $0.record.id == record.id }
            do {
                try transaction.save()
            } catch {
                do {
                    try secrets.remove(recordID: record.id)
                    transaction.state.records.removeAll { $0.id == record.id }
                    try transaction.save()
                } catch { throw CredentialVaultError.operationFailed("add rollback") }
                throw error
            }
            return .object([
                "saved": .bool(true),
                "credential": record.publicValue,
                "backend": .string(secrets.backendName),
                "passwordExposed": .bool(false),
            ])
        }
    }

    public func rename(
        origin: CredentialOrigin, alias: CredentialAlias, to newAlias: CredentialAlias
    ) throws -> JSONValue {
        try withRecoveredState { transaction in
            guard let index = transaction.state.records.firstIndex(where: {
                $0.origin == origin
                    && $0.alias.rawValue.caseInsensitiveCompare(alias.rawValue) == .orderedSame
            }) else {
                throw CredentialVaultError.notFound
            }
            guard alias.rawValue.caseInsensitiveCompare(newAlias.rawValue) == .orderedSame
                || !transaction.state.records.contains(where: {
                $0.origin == origin
                    && $0.alias.rawValue.caseInsensitiveCompare(newAlias.rawValue) == .orderedSame
            }) else { throw CredentialVaultError.duplicateAlias }
            if alias.rawValue == newAlias.rawValue {
                return .object([
                    "renamed": .bool(false), "credential": transaction.state.records[index].publicValue,
                ])
            }
            let previous = transaction.state.records[index]
            let renamed = try CredentialRecord(
                id: previous.id, origin: previous.origin, alias: newAlias,
                account: previous.account, createdAt: previous.createdAt
            )
            transaction.state.records[index] = renamed
            try transaction.save()
            return .object(["renamed": .bool(true), "credential": renamed.publicValue])
        }
    }

    public func remove(origin: CredentialOrigin, alias: CredentialAlias) throws -> JSONValue {
        try withRecoveredState { transaction in
            guard let index = transaction.state.records.firstIndex(where: {
                $0.origin == origin
                    && $0.alias.rawValue.caseInsensitiveCompare(alias.rawValue) == .orderedSame
            }) else {
                throw CredentialVaultError.notFound
            }
            let previous = transaction.state
            let removed = transaction.state.records.remove(at: index)
            transaction.state.pending.append(
                CredentialPendingTransaction(kind: .remove, record: removed)
            )
            try transaction.save()
            do {
                try secrets.remove(recordID: removed.id)
            } catch {
                do {
                    transaction.state = previous
                    try transaction.save()
                }
                catch { throw CredentialVaultError.operationFailed("delete rollback") }
                throw error
            }
            transaction.state.pending.removeAll { $0.record.id == removed.id }
            try transaction.save()
            return .object([
                "removed": .bool(true),
                "origin": .string(origin.rawValue),
                "alias": .string(alias.rawValue),
            ])
        }
    }

    private func withRecoveredState<T>(
        _ body: (CredentialMetadataTransaction) throws -> T
    ) throws -> T {
        try metadata.withLockedState { transaction in
            while let pending = transaction.state.pending.first {
                switch pending.kind {
                case .add, .remove:
                    try secrets.remove(recordID: pending.record.id)
                }
                transaction.state.pending.removeFirst()
                try transaction.save()
            }
            return try body(transaction)
        }
    }
}
