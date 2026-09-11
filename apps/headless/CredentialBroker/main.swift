import CredentialBrokerCore
import Foundation
import HeadlessProtocol

private func printJSON(_ value: JSONValue) {
    guard let data = try? ProtocolCodec.encoder.encode(value) else {
        fputs("headless credential broker: output encoding failed\n", stderr)
        exit(70)
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

do {
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
