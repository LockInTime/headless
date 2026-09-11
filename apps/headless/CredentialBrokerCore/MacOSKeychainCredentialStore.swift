#if os(macOS)
import Foundation
import Security

public final class MacOSKeychainCredentialStore: CredentialSecretStore {
    private static let service = "com.headless.credentials.v1"

    public let backendName = "macos-login-keychain"

    public init() throws {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ] as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw mappedKeychainError(status)
        }
    }

    public func store(_ secret: SensitiveBytes, for record: CredentialRecord) throws {
        let access = try passwordProtectedAccess()
        var password = secret.withUnsafeBytes { Data($0) }
        defer { password.resetBytes(in: 0..<password.count) }
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: record.id,
            kSecAttrLabel as String: "Headless saved credential",
            kSecAttrAccess as String: access,
            kSecValueData as String: password,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw mappedKeychainError(status) }
    }

    public func remove(recordID: String) throws {
        let status = SecItemDelete(baseQuery(recordID: recordID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw mappedKeychainError(status)
        }
    }

    private func baseQuery(recordID: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: recordID,
        ]
    }

    private func passwordProtectedAccess() throws -> SecAccess {
        let label = "Headless saved credential" as CFString
        let trustedApplications = [] as CFArray
        var access: SecAccess?
        let createStatus = SecAccessCreate(label, trustedApplications, &access)
        guard createStatus == errSecSuccess, let access else {
            throw mappedKeychainError(createStatus)
        }
        var aclList: CFArray?
        let listStatus = SecAccessCopyACLList(access, &aclList)
        guard listStatus == errSecSuccess, let acls = aclList as? [SecACL], !acls.isEmpty else {
            throw mappedKeychainError(listStatus)
        }
        guard let decryptACL = acls.first(where: { acl in
            let authorizations = SecACLCopyAuthorizations(acl) as? [String] ?? []
            return authorizations.contains(kSecACLAuthorizationDecrypt as String)
        }) else {
            throw CredentialVaultError.operationFailed("Keychain decrypt ACL")
        }
        let status = SecACLSetContents(
            decryptACL, trustedApplications, label, [.requirePassphase]
        )
        guard status == errSecSuccess else { throw mappedKeychainError(status) }
        return access
    }
}

private func mappedKeychainError(_ status: OSStatus) -> CredentialVaultError {
    switch status {
    case errSecDuplicateItem: return .duplicateAlias
    case errSecItemNotFound: return .notFound
    case errSecUserCanceled: return .userDenied
    case errSecAuthFailed: return .userDenied
    case errSecInteractionNotAllowed: return .vaultLocked
    case errSecNotAvailable, errSecNoDefaultKeychain: return .vaultUnavailable
    case errSecMissingEntitlement: return .vaultUnavailable
    default: return .operationFailed("Keychain status \(status)")
    }
}
#endif
