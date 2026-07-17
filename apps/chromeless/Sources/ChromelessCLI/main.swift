import ChromelessProtocol
import Foundation

private func printJSON(_ value: JSONValue) {
    do {
        let data = try ProtocolCodec.encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    } catch {
        fputs("chromeless: failed to encode output: \(error)\n", stderr)
        exit(70)
    }
}

private func printResponse(_ response: CommandResponse) throws {
    FileHandle.standardOutput.write(try ProtocolCodec.encodeLine(response))
}

private struct HostLauncher {
    let client = LocalSocketClient()

    func ping() -> CommandResponse? {
        try? client.send(CommandRequest(command: .ping), timeout: 0.5)
    }

    func start() throws -> CommandResponse {
        if let response = ping(), response.ok { return response }
        let executable = try resolveHostExecutable()
        let process = Process()
        process.executableURL = executable
        process.arguments = []
        var environment = ProcessInfo.processInfo.environment
        environment["CHROMELESS_AGENT_HOST"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(8)
        repeat {
            if let response = ping(), response.ok { return response }
            if !process.isRunning {
                throw HostLaunchError.exited(process.terminationStatus)
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        throw HostLaunchError.timedOut
    }

    private func resolveHostExecutable() throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["CHROMELESS_HOST_EXECUTABLE"] {
            candidates.append(URL(fileURLWithPath: override))
        }

        let cli = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let siblingDirectory = cli.deletingLastPathComponent()
        candidates.append(siblingDirectory.appendingPathComponent("chromeless-host"))
        candidates.append(
            siblingDirectory.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("MacOS/Chromeless")
        )
        candidates.append(
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("Chromeless.app/Contents/MacOS/Chromeless")
        )

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw HostLaunchError.notFound
    }
}

private enum HostLaunchError: Error, CustomStringConvertible {
    case notFound
    case timedOut
    case exited(Int32)

    var description: String {
        switch self {
        case .notFound: return "Could not find chromeless-host. Run the Chromeless build first."
        case .timedOut: return "Chromeless host did not become ready within 8 seconds."
        case .exited(let status): return "Chromeless host exited during startup (status \(status))."
        }
    }
}

private func requestTimeout(_ request: CommandRequest) -> TimeInterval {
    if let milliseconds = request.parameters["timeoutMs"]?.numberValue {
        return min(125, max(10, milliseconds / 1_000 + 5))
    }
    if request.command == .tour { return 125 }
    if request.command == .recordStop { return 30 }
    if request.command == .screenshot { return 30 }
    return 15
}

do {
    let invocation = try CLIParser().parse(Array(CommandLine.arguments.dropFirst()))
    if let local = invocation.local {
        switch local {
        case .help:
            print(agentHelp)
        case .capabilities:
            printJSON(capabilitiesDocument)
        case .start:
            try printResponse(try HostLauncher().start())
        }
    } else if let request = invocation.request {
        let launcher = HostLauncher()
        let response: CommandResponse
        do {
            response = try launcher.client.send(request, timeout: requestTimeout(request))
        } catch LocalTransportError.connectionFailed where request.command != .ping && request.command != .shutdown {
            _ = try launcher.start()
            response = try launcher.client.send(request, timeout: requestTimeout(request))
        }
        try printResponse(response)
        if !response.ok { exit(1) }
    }
} catch let error as CLIParseError {
    fputs("chromeless: \(error.description)\n", stderr)
    exit(64)
} catch let error as ProtocolValidationError {
    fputs("chromeless: \(error.description)\n", stderr)
    exit(64)
} catch let error as LocalTransportError {
    let response = CommandResponse.failure(
        id: "unknown",
        code: "HOST_UNAVAILABLE",
        message: error.description,
        suggestion: "Run `chromeless start`."
    )
    try? printResponse(response)
    exit(69)
} catch let error as HostLaunchError {
    let response = CommandResponse.failure(id: "unknown", code: "HOST_START_FAILED", message: error.description)
    try? printResponse(response)
    exit(69)
} catch {
    fputs("chromeless: \(error)\n", stderr)
    exit(70)
}
