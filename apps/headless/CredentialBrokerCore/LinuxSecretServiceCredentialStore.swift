#if os(Linux)
import CHeadlessSecurePrompt
import Dispatch
import Foundation
import Glibc

public final class LinuxSecretServiceCredentialStore: CredentialSecretStore {
    public let backendName = "linux-secret-service"
    private let executableURL: URL
    private let runtimeDirectory: String
    private let busAddress: String

    public init() throws {
        guard let executable = Self.approvedExecutable() else {
            throw CredentialVaultError.vaultUnavailable
        }
        executableURL = executable
        guard let sessionBus = Self.validatedSessionBus() else {
            throw CredentialVaultError.vaultUnavailable
        }
        runtimeDirectory = sessionBus.runtimeDirectory
        busAddress = sessionBus.address
    }

    public func store(_ secret: SensitiveBytes, for record: CredentialRecord) throws {
        try run([
            "store", "--label=Headless saved credential",
            "application", "com.headless.credentials.v1", "credential-id", record.id,
        ], secret: secret)
    }

    public func load(recordID: String) throws -> SensitiveBytes {
        try lookup([
            "lookup", "application", "com.headless.credentials.v1", "credential-id", recordID,
        ])
    }

    public func remove(recordID: String) throws {
        try run([
            "clear", "application", "com.headless.credentials.v1", "credential-id", recordID,
        ], secret: nil)
    }

    private func run(_ arguments: [String], secret: SensitiveBytes?) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = Self.sanitizedEnvironment(
            ProcessInfo.processInfo.environment,
            runtimeDirectory: runtimeDirectory,
            busAddress: busAddress
        )
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        let errorCapture = BoundedErrorCapture()
        process.standardError = errorPipe
        errorCapture.start(reading: errorPipe.fileHandleForReading)
        let input = Pipe()
        process.standardInput = input
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        do {
            try process.run()
        } catch {
            errorPipe.fileHandleForWriting.closeFile()
            _ = errorCapture.text()
            throw CredentialVaultError.vaultUnavailable
        }
        errorPipe.fileHandleForWriting.closeFile()

        if let secret {
            do {
                try secret.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    var offset = 0
                    while offset < bytes.count {
                        let count = Glibc.write(
                            input.fileHandleForWriting.fileDescriptor,
                            base.advanced(by: offset), bytes.count - offset
                        )
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else {
                            throw CredentialVaultError.operationFailed("Secret Service input")
                        }
                        offset += count
                    }
                }
            } catch {
                input.fileHandleForWriting.closeFile()
                process.terminate()
                process.waitUntilExit()
                _ = errorCapture.text()
                throw CredentialVaultError.operationFailed("Secret Service input")
            }
        }
        input.fileHandleForWriting.closeFile()
        guard completion.wait(timeout: .now() + 15) == .success else {
            if process.isRunning { process.terminate() }
            if completion.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            _ = errorCapture.text()
            throw CredentialVaultError.operationFailed("Secret Service timeout")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Self.classifiedBackendError(errorCapture.text())
        }
        _ = errorCapture.text()
    }

    private func lookup(_ arguments: [String]) throws -> SensitiveBytes {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = Self.sanitizedEnvironment(
            ProcessInfo.processInfo.environment,
            runtimeDirectory: runtimeDirectory,
            busAddress: busAddress
        )
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let outputCapture = BoundedSecretCapture(maximumBytes: 4_097)
        let errorCapture = BoundedErrorCapture()
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        outputCapture.start(reading: output.fileHandleForReading)
        errorCapture.start(reading: errors.fileHandleForReading)
        do { try process.run() }
        catch {
            output.fileHandleForWriting.closeFile()
            errors.fileHandleForWriting.closeFile()
            _ = try? outputCapture.data()
            _ = errorCapture.text()
            throw CredentialVaultError.vaultUnavailable
        }
        output.fileHandleForWriting.closeFile()
        errors.fileHandleForWriting.closeFile()
        guard completion.wait(timeout: .now() + 15) == .success else {
            if process.isRunning { process.terminate() }
            if completion.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            _ = try? outputCapture.data()
            _ = errorCapture.text()
            throw CredentialVaultError.operationFailed("Secret Service timeout")
        }
        var data = try outputCapture.data()
        defer { data.resetBytes(in: 0..<data.count) }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Self.classifiedBackendError(errorCapture.text())
        }
        _ = errorCapture.text()
        guard !data.isEmpty, data.count <= 4_097 else {
            throw CredentialVaultError.operationFailed("invalid Secret Service value")
        }
        var bytes = Array(data)
        if bytes.last == 0x0A { bytes.removeLast() }
        guard !bytes.isEmpty, bytes.count <= 4_096 else {
            throw CredentialVaultError.operationFailed("invalid Secret Service value")
        }
        return SensitiveBytes(bytes)
    }

    private static func approvedExecutable() -> URL? {
        for path in ["/usr/bin/secret-tool"] {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let safeMode = (info.st_mode & 0o022) == 0
            if (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == 0, safeMode,
               access(path, X_OK) == 0 {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static func validatedSessionBus() -> (runtimeDirectory: String, address: String)? {
        let runtimeDirectory = "/run/user/\(getuid())"
        let socketPath = "\(runtimeDirectory)/bus"
        var directoryInfo = stat()
        var socketInfo = stat()
        guard lstat(runtimeDirectory, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == getuid(), (directoryInfo.st_mode & 0o077) == 0,
              lstat(socketPath, &socketInfo) == 0,
              (socketInfo.st_mode & S_IFMT) == S_IFSOCK,
              socketInfo.st_uid == getuid() else {
            return nil
        }
        return (runtimeDirectory, "unix:path=\(socketPath)")
    }

    private static func sanitizedEnvironment(
        _ source: [String: String], runtimeDirectory: String, busAddress: String
    ) -> [String: String] {
        let exact = [
            "HOME", "USER", "LOGNAME", "DISPLAY", "WAYLAND_DISPLAY",
        ]
        var result = source.filter { exact.contains($0.key) }
        result["PATH"] = "/usr/bin:/bin"
        result["LANG"] = "C"
        result["XDG_RUNTIME_DIR"] = runtimeDirectory
        result["DBUS_SESSION_BUS_ADDRESS"] = busAddress
        return result
    }

    private static func classifiedBackendError(_ text: String) -> CredentialVaultError {
        let normalized = text.lowercased()
        if normalized.contains("locked") { return .vaultLocked }
        if normalized.contains("denied") || normalized.contains("dismissed")
            || normalized.contains("cancelled") || normalized.contains("canceled")
            || normalized.contains("permission") {
            return .userDenied
        }
        return .vaultUnavailable
    }
}

private final class BoundedSecretCapture: @unchecked Sendable {
    private let maximumBytes: Int
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var overflowed = false

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func start(reading handle: FileHandle) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave() }
            while true {
                let data = handle.readData(ofLength: 4_096)
                if data.isEmpty { return }
                lock.lock()
                let remaining = max(0, maximumBytes - bytes.count)
                bytes.append(contentsOf: data.prefix(remaining))
                if data.count > remaining { overflowed = true }
                lock.unlock()
            }
        }
    }

    func data() throws -> Data {
        group.wait()
        lock.lock()
        defer {
            bytes.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                headless_secure_clear(base.assumingMemoryBound(to: UInt8.self), buffer.count)
            }
            bytes.removeAll(keepingCapacity: false)
            lock.unlock()
        }
        guard !overflowed else {
            throw CredentialVaultError.operationFailed("invalid Secret Service value")
        }
        return Data(bytes)
    }
}

private final class BoundedErrorCapture: @unchecked Sendable {
    private static let maximumBytes = 8_192
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    func start(reading handle: FileHandle) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave() }
            while true {
                let data = handle.readData(ofLength: 4_096)
                if data.isEmpty { return }
                lock.lock()
                let remaining = max(0, Self.maximumBytes - bytes.count)
                bytes.append(contentsOf: data.prefix(remaining))
                lock.unlock()
            }
        }
    }

    func text() -> String {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }
}
#endif
