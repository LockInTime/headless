import Foundation

public func makePlatformCredentialSecretStore() throws -> CredentialSecretStore {
    #if os(macOS)
    return try MacOSKeychainCredentialStore()
    #elseif os(Linux)
    return try LinuxSecretServiceCredentialStore()
    #else
    throw CredentialVaultError.vaultUnavailable
    #endif
}
