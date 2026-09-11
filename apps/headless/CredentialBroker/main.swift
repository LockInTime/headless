import CredentialBrokerCore
import Foundation
import HeadlessProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private func printJSON(_ value: JSONValue) {
    guard let data = try? ProtocolCodec.encoder.encode(value) else {
        fputs("headless credential broker: output encoding failed\n", stderr)
        exit(70)
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

private func trustedHostIsParent() -> Bool {
    let broker = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let parentPath: String?
    #if os(macOS)
    var buffer = [CChar](repeating: 0, count: 4_096)
    let count = proc_pidpath(getppid(), &buffer, UInt32(buffer.count))
    parentPath = count > 0 ? String(cString: buffer) : nil
    let expected = [
        broker.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacOS/Headless"),
        broker.deletingLastPathComponent().appendingPathComponent("headless-host"),
    ]
    #else
    parentPath = try? FileManager.default.destinationOfSymbolicLink(
        atPath: "/proc/\(getppid())/exe"
    )
    let expected = [broker.deletingLastPathComponent().appendingPathComponent("headless-host")]
    #endif
    guard let parentPath else { return false }
    let parent = URL(fileURLWithPath: parentPath).resolvingSymlinksInPath().standardizedFileURL
    return expected.contains {
        parent == $0.resolvingSymlinksInPath().standardizedFileURL
    }
}

private func runInternalResolve(_ arguments: [String]) throws {
    guard trustedHostIsParent() else { throw CredentialVaultError.userDenied }
    #if os(Linux)
    // An unlocked Secret Service can answer without prompting. Until the Linux
    // host has a trusted confirmation UI, saved use must fail closed.
    throw CredentialVaultError.userPresenceUnavailable
    #else
    var values = arguments
    func option(_ name: String) throws -> String {
        guard let index = values.firstIndex(of: name), index + 1 < values.count else {
            throw CredentialCommandError.invalidArguments
        }
        let value = values.remove(at: index + 1)
        values.remove(at: index)
        return value
    }
    let origin = try CredentialOrigin(rawValue: option("--origin"))
    let alias = try CredentialAlias(rawValue: option("--alias"))
    guard values.isEmpty else { throw CredentialCommandError.invalidArguments }
    let controller = CredentialVaultController(
        metadata: CredentialMetadataStore(), secrets: try makePlatformCredentialSecretStore()
    )
    let credential = try controller.resolve(origin: origin, alias: alias)
    defer { credential.password.clear() }
    var frame = try AuthenticationCredentialFrame.encode(credential)
    FileHandle.standardOutput.write(frame)
    frame.resetBytes(in: 0..<frame.count)
    #endif
}

do {
    if CommandLine.arguments.dropFirst().first == "__resolve" {
        try runInternalResolve(Array(CommandLine.arguments.dropFirst(2)))
        exit(0)
    }
    let invocation = try CLIParser().parse(Array(CommandLine.arguments.dropFirst()))
    guard case .credentials(let command)? = invocation.local, invocation.request == nil else {
        throw CredentialCommandError.invalidArguments
    }
    let controller = CredentialVaultController(
        metadata: CredentialMetadataStore(),
        secrets: try makePlatformCredentialSecretStore()
    )
    let result: JSONValue
    switch command {
    case .list(let origin):
        result = try controller.list(origin: origin)
    case .add(let origin, let alias):
        result = try controller.add(origin: origin, alias: alias)
    case .rename(let origin, let alias, let newAlias):
        result = try controller.rename(origin: origin, alias: alias, to: newAlias)
    case .remove(let origin, let alias):
        result = try controller.remove(origin: origin, alias: alias)
    }
    printJSON(.object(["ok": .bool(true), "result": result]))
} catch let error as CredentialVaultError {
    if CommandLine.arguments.dropFirst().first == "__resolve" {
        switch error {
        case .userDenied: exit(77)
        case .vaultUnavailable: exit(78)
        case .notFound: exit(79)
        case .vaultLocked: exit(80)
        case .userPresenceUnavailable: exit(81)
        default: exit(70)
        }
    }
    printJSON(.object([
        "ok": .bool(false),
        "error": .object(["code": .string(error.code), "message": .string(error.description)]),
    ]))
    exit(error == .terminalRequired ? 64 : 69)
} catch let error as CredentialCommandError {
    printJSON(.object([
        "ok": .bool(false),
        "error": .object(["code": .string("INVALID_CREDENTIAL_COMMAND"), "message": .string(error.description)]),
    ]))
    exit(64)
} catch let error as CLIParseError {
    printJSON(.object([
        "ok": .bool(false),
        "error": .object(["code": .string("INVALID_CREDENTIAL_COMMAND"), "message": .string(error.description)]),
    ]))
    exit(64)
} catch {
    printJSON(.object([
        "ok": .bool(false),
        "error": .object([
            "code": .string("VAULT_OPERATION_FAILED"),
            "message": .string("Credential vault operation failed without exposing sensitive details."),
        ]),
    ]))
    exit(70)
}
