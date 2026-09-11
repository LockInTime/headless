import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum AuthenticationCredentialFrame {
    private static let magic = Data("HEADLESS-AUTH-1\n".utf8)
    public static let maximumBytes = 4_512

    public static func encode(_ credential: AuthenticationCredential) throws -> Data {
        let account = Data(credential.account.utf8)
        var secret = credential.password.withUnsafeBytes { Data($0) }
        defer { secret.resetBytes(in: 0..<secret.count) }
        guard account.count <= 320, !secret.isEmpty, secret.count <= 4_096 else {
            throw AuthenticationError.invalidBrokerResponse
        }
        var data = magic
        append(UInt32(account.count), to: &data)
        append(UInt32(secret.count), to: &data)
        data.append(account)
        data.append(secret)
        guard data.count <= maximumBytes else { throw AuthenticationError.invalidBrokerResponse }
        return data
    }

    public static func decode(_ data: Data) throws -> AuthenticationCredential {
        guard data.count <= maximumBytes, data.starts(with: magic) else {
            throw AuthenticationError.invalidBrokerResponse
        }
        var offset = magic.count
        let accountLength = Int(try readUInt32(data, offset: &offset))
        let secretLength = Int(try readUInt32(data, offset: &offset))
        guard accountLength <= 320, secretLength > 0, secretLength <= 4_096,
              offset + accountLength + secretLength == data.count else {
            throw AuthenticationError.invalidBrokerResponse
        }
        let accountData = data[offset..<(offset + accountLength)]
        offset += accountLength
        guard let account = String(data: accountData, encoding: .utf8) else {
            throw AuthenticationError.invalidBrokerResponse
        }
        return try AuthenticationCredential(
            account: account,
            password: AuthenticationSecret(Array(data[offset..<(offset + secretLength)]))
        )
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ data: Data, offset: inout Int) throws -> UInt32 {
        guard offset + 4 <= data.count else { throw AuthenticationError.invalidBrokerResponse }
        let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        return value
    }
}

public final class CredentialBrokerProcessClient: @unchecked Sendable, AuthenticationBroker {
    private let executableURL: URL

    public convenience init() throws {
        try self.init(executableURL: Self.resolveExecutable())
    }

    public init(executableURL: URL) throws {
        let resolved = executableURL.resolvingSymlinksInPath().standardizedFileURL
        var info = stat()
        guard lstat(resolved.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, (info.st_uid == getuid() || info.st_uid == 0),
              (info.st_mode & 0o022) == 0,
              FileManager.default.isExecutableFile(atPath: resolved.path) else {
            throw AuthenticationError.vaultUnavailable
        }
        self.executableURL = resolved
    }

    public func aliases(for origin: CredentialOrigin) throws -> [AuthenticationAlias] {
        let output = try run(
            ["credentials", "list", "--origin", origin.rawValue, "--json"],
            maximumOutputBytes: 256_000
        )
        guard let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              object["ok"] as? Bool == true,
              let result = object["result"] as? [String: Any],
              let values = result["credentials"] as? [[String: Any]], values.count <= 500 else {
            throw AuthenticationError.invalidBrokerResponse
        }
        return try values.map { value in
            guard let rawAlias = value["alias"] as? String,
                  let account = value["username"] as? String else {
                throw AuthenticationError.invalidBrokerResponse
            }
            return try AuthenticationAlias(
                alias: CredentialAlias(rawValue: rawAlias), account: account
            )
        }
    }

    public func credential(
        for origin: CredentialOrigin, alias: CredentialAlias
    ) throws -> AuthenticationCredential {
        var output = try run(
            ["__resolve", "--origin", origin.rawValue, "--alias", alias.rawValue],
            maximumOutputBytes: AuthenticationCredentialFrame.maximumBytes
        )
        defer { output.resetBytes(in: 0..<output.count) }
        return try AuthenticationCredentialFrame.decode(output)
    }

    public func store(
        _ credential: AuthenticationCredential, for origin: CredentialOrigin, alias: CredentialAlias
    ) throws {
        var frame = try AuthenticationCredentialFrame.encode(credential)
        defer { frame.resetBytes(in: 0..<frame.count) }
        _ = try run(
            ["__store", "--origin", origin.rawValue, "--alias", alias.rawValue],
            maximumOutputBytes: 1, input: frame
        )
    }

    private func run(
        _ arguments: [String], maximumOutputBytes: Int, input: Data? = nil
    ) throws -> Data {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = Self.sanitizedEnvironment(ProcessInfo.processInfo.environment)
        let inputPipe = input.map { _ in Pipe() }
        if let inputPipe {
            process.standardInput = inputPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        do { try process.run() }
        catch { throw AuthenticationError.vaultUnavailable }
        if let input, let inputPipe {
            inputPipe.fileHandleForWriting.write(input)
            try? inputPipe.fileHandleForWriting.close()
        }
        let capture = BoundedBrokerOutput(maximumBytes: maximumOutputBytes)
        capture.start(output.fileHandleForReading)
        guard completion.wait(timeout: .now() + 30) == .success else {
            if process.isRunning { process.terminate() }
            if completion.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            _ = try? capture.finish()
            throw AuthenticationError.brokerFailed("timeout")
        }
        let data = try capture.finish()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            switch process.terminationStatus {
            case 77: throw AuthenticationError.userPresenceDenied
            case 78: throw AuthenticationError.vaultUnavailable
            case 79: throw AuthenticationError.accountNotFound
            case 80: throw AuthenticationError.vaultLocked
            case 81: throw AuthenticationError.userPresenceUnavailable
            default: throw AuthenticationError.brokerFailed("request")
            }
        }
        return data
    }

    private static func resolveExecutable() throws -> URL {
        let executable = try runningExecutableURL()
        let directory = executable.deletingLastPathComponent()
        let candidates: [URL]
        #if os(macOS)
        candidates = [
            directory.deletingLastPathComponent().appendingPathComponent(
                "Resources/bin/headless-credential-broker"
            ),
            directory.appendingPathComponent("headless-credential-broker"),
        ]
        #else
        candidates = [directory.appendingPathComponent("headless-credential-broker")]
        #endif
        guard let candidate = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else { throw AuthenticationError.vaultUnavailable }
        return candidate
    }

    private static func runningExecutableURL() throws -> URL {
        #if os(macOS)
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard buffer.withUnsafeMutableBufferPointer({
            _NSGetExecutablePath($0.baseAddress, &size)
        }) == 0 else { throw AuthenticationError.vaultUnavailable }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        #else
        guard let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") else {
            throw AuthenticationError.vaultUnavailable
        }
        return URL(fileURLWithPath: path).standardizedFileURL
        #endif
    }

    private static func sanitizedEnvironment(_ source: [String: String]) -> [String: String] {
        let allowed = [
            "HOME", "USER", "LOGNAME", "DISPLAY", "WAYLAND_DISPLAY", "LANG",
            "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "__CF_USER_TEXT_ENCODING",
        ]
        var result = source.filter { allowed.contains($0.key) || $0.key.hasPrefix("LC_") }
        result["PATH"] = "/usr/bin:/bin"
        return result
    }
}

private final class BoundedBrokerOutput: @unchecked Sendable {
    private let maximumBytes: Int
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var data = Data()
    private var overflowed = false

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func start(_ handle: FileHandle) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave() }
            while true {
                let chunk = handle.readData(ofLength: 4_096)
                if chunk.isEmpty { return }
                lock.lock()
                let remaining = max(0, maximumBytes - data.count)
                data.append(chunk.prefix(remaining))
                if chunk.count > remaining { overflowed = true }
                lock.unlock()
            }
        }
    }

    func finish() throws -> Data {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        guard !overflowed else { throw AuthenticationError.invalidBrokerResponse }
        let result = data
        data.resetBytes(in: 0..<data.count)
        data.removeAll(keepingCapacity: false)
        return result
    }
}
