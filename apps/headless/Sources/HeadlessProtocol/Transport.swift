import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum LocalTransportError: Error, CustomStringConvertible {
    case pathTooLong
    case invalidRuntimeDirectory
    case socketFailure(String)
    case connectionFailed
    case timedOut
    case connectionClosed
    case messageTooLarge
    case alreadyRunning

    public var description: String {
        switch self {
        case .pathTooLong: return "Local socket path is too long"
        case .invalidRuntimeDirectory: return "Local runtime directory is not private to the current user"
        case .socketFailure(let operation): return "Local socket \(operation) failed: \(systemErrorMessage())"
        case .connectionFailed: return "Headless host is not running"
        case .timedOut: return "Headless host did not respond before the deadline"
        case .connectionClosed: return "Headless host closed the connection"
        case .messageTooLarge: return "Headless host message exceeded the size limit"
        case .alreadyRunning: return "Another Headless host is already using the local socket"
        }
    }
}

public enum LocalRuntime {
    public static var directoryURL: URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("headless-\(currentUserID())", isDirectory: true)
    }

    public static var socketURL: URL {
        if let override = ProcessInfo.processInfo.environment["HEADLESS_SOCKET"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override)
        }
        return directoryURL.appendingPathComponent("host.sock")
    }

    public static func preparePrivateDirectory() throws {
        let path = directoryURL.path
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == currentUserID(),
                  (info.st_mode & 0o077) == 0 else {
                throw LocalTransportError.invalidRuntimeDirectory
            }
            return
        }
        guard errno == ENOENT else { throw LocalTransportError.socketFailure("runtime directory check") }
        if mkdir(path, 0o700) != 0 {
            if errno == EEXIST {
                // Re-run the full ownership/type/permission validation after a
                // creation race instead of chmodding an attacker-created path.
                try preparePrivateDirectory()
                return
            }
            throw LocalTransportError.socketFailure("runtime directory creation")
        }
        guard chmod(path, 0o700) == 0 else {
            throw LocalTransportError.socketFailure("runtime directory permissions")
        }
    }
}

public final class LocalSocketClient {
    public let socketPath: String

    public init(socketPath: String = LocalRuntime.socketURL.path) {
        self.socketPath = socketPath
    }

    public func send(_ request: CommandRequest, timeout: TimeInterval = 10) throws -> CommandResponse {
        try request.validate()
        let fd = try makeSocket()
        defer { systemClose(fd) }
        try configureTimeout(fd: fd, seconds: timeout)
        var address = try unixAddress(path: socketPath)
        let result = withUnsafePointer(to: &address.value) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                systemConnect(fd, $0, address.length)
            }
        }
        guard result == 0 else {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                throw LocalTransportError.timedOut
            }
            throw LocalTransportError.connectionFailed
        }

        try writeAll(try ProtocolCodec.encodeLine(request), to: fd)
        let responseData = try readLine(from: fd)
        return try ProtocolCodec.decodeLine(CommandResponse.self, from: responseData)
    }
}

public final class LocalSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (CommandRequest) -> CommandResponse

    public let socketPath: String
    private let queue = DispatchQueue(label: "com.headless.socket-server", qos: .userInitiated)
    // Accepting a connection must remain independent from executing a browser
    // command. A browser action can legitimately take seconds, and a shutdown
    // request must still be able to reach the host during that time.
    private let clientQueue = DispatchQueue(
        label: "com.headless.socket-clients", qos: .userInitiated, attributes: .concurrent
    )
    // Browser hosts mutate session state, so ordinary requests retain their
    // original one-at-a-time execution semantics.
    private let requestQueue = DispatchQueue(label: "com.headless.socket-requests", qos: .userInitiated)
    private let stateLock = NSLock()
    private var listeningDescriptor: Int32 = -1
    private var running = false

    public init(socketPath: String = LocalRuntime.socketURL.path) {
        self.socketPath = socketPath
    }

    deinit { stop() }

    public func start(handler: @escaping Handler) throws {
        try LocalRuntime.preparePrivateDirectory()
        let socketParent = URL(fileURLWithPath: socketPath).deletingLastPathComponent().standardizedFileURL
        guard socketParent.path == LocalRuntime.directoryURL.standardizedFileURL.path else {
            throw LocalTransportError.invalidRuntimeDirectory
        }
        let fd = try makeSocket()
        var didBind = false
        do {
            try removeStaleSocketIfSafe(at: socketPath)
            var address = try unixAddress(path: socketPath)
            let bindResult = withUnsafePointer(to: &address.value) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    systemBind(fd, $0, address.length)
                }
            }
            guard bindResult == 0 else { throw LocalTransportError.socketFailure("bind") }
            didBind = true
            guard chmod(socketPath, 0o600) == 0 else {
                throw LocalTransportError.socketFailure("permission setup")
            }
            guard systemListen(fd, 16) == 0 else { throw LocalTransportError.socketFailure("listen") }
        } catch {
            systemClose(fd)
            if didBind { _ = systemUnlink(socketPath) }
            throw error
        }

        stateLock.lock()
        listeningDescriptor = fd
        running = true
        stateLock.unlock()
        queue.async { [weak self] in self?.acceptLoop(handler: handler) }
    }

    public func stop() {
        stateLock.lock()
        guard running else { stateLock.unlock(); return }
        running = false
        let fd = listeningDescriptor
        listeningDescriptor = -1
        stateLock.unlock()
        if fd >= 0 {
            systemShutdown(fd)
            systemClose(fd)
        }
        _ = systemUnlink(socketPath)
    }

    private func acceptLoop(handler: @escaping Handler) {
        while isRunning {
            let client = systemAccept(currentDescriptor)
            if client < 0 {
                if !isRunning { return }
                if errno == EINTR { continue }
                continue
            }
            clientQueue.async { [weak self] in
                guard let self else { systemClose(client); return }
                #if canImport(Darwin)
                autoreleasepool { self.handleClient(client, handler: handler) }
                #else
                self.handleClient(client, handler: handler)
                #endif
                systemClose(client)
            }
        }
    }

    private func handleClient(_ fd: Int32, handler: Handler) {
        do {
            try configureNoSigPipe(fd: fd)
            guard try peerUserID(fd: fd) == currentUserID() else {
                let response = CommandResponse.failure(id: "unknown", code: "PEER_DENIED", message: "Socket peer user is not authorized.")
                try writeAll(try ProtocolCodec.encodeLine(response), to: fd)
                return
            }
            try configureTimeout(fd: fd, seconds: 5)
            let data = try readLine(from: fd)
            let request = try ProtocolCodec.decodeLine(CommandRequest.self, from: data)
            try request.validate()
            try configureTimeout(fd: fd, seconds: 125)
            // `shutdown` only signals the host's main loop and does not mutate
            // a browser session. Let it bypass an in-flight normal request so
            // an operator can always stop a stalled browser action.
            let response: CommandResponse
            if request.command == .shutdown {
                response = handler(request)
            } else {
                response = requestQueue.sync { handler(request) }
            }
            try writeAll(try ProtocolCodec.encodeLine(response), to: fd)
        } catch {
            let response = CommandResponse.failure(
                id: "unknown",
                code: "INVALID_REQUEST",
                message: String(describing: error)
            )
            try? writeAll(try ProtocolCodec.encodeLine(response), to: fd)
        }
    }

    private var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    private var currentDescriptor: Int32 {
        stateLock.lock(); defer { stateLock.unlock() }
        return listeningDescriptor
    }
}

private func currentUserID() -> uid_t { getuid() }

private func makeSocket() throws -> Int32 {
    #if canImport(Darwin)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #else
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard fd >= 0 else { throw LocalTransportError.socketFailure("creation") }
    try configureNoSigPipe(fd: fd)
    return fd
}

private func configureNoSigPipe(fd: Int32) throws {
    #if canImport(Darwin)
    var enabled: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw LocalTransportError.socketFailure("SIGPIPE protection")
    }
    #else
    _ = fd // Linux writes use MSG_NOSIGNAL below.
    #endif
}

private struct UnixAddress {
    var value: sockaddr_un
    let length: socklen_t
}

private func unixAddress(path: String) throws -> UnixAddress {
    let bytes = Array(path.utf8)
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else { throw LocalTransportError.pathTooLong }
    address.sun_family = sa_family_t(AF_UNIX)
    #if canImport(Darwin)
    address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + bytes.count + 1)
    #endif
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
    }
    return UnixAddress(value: address, length: socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1))
}

private func removeStaleSocketIfSafe(at path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0 else {
        if errno == ENOENT { return }
        throw LocalTransportError.socketFailure("existing socket check")
    }
    guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == currentUserID() else {
        throw LocalTransportError.invalidRuntimeDirectory
    }
    let probe = try makeSocket()
    defer { systemClose(probe) }
    var address = try unixAddress(path: path)
    let connected = withUnsafePointer(to: &address.value) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            systemConnect(probe, $0, address.length)
        }
    }
    if connected == 0 { throw LocalTransportError.alreadyRunning }
    guard errno == ECONNREFUSED || errno == ENOENT else {
        throw LocalTransportError.socketFailure("existing socket probe")
    }
    guard systemUnlink(path) == 0 else { throw LocalTransportError.socketFailure("stale socket removal") }
}

private func configureTimeout(fd: Int32, seconds: TimeInterval) throws {
    let whole = Int(seconds)
    let micros = Int((seconds - Double(whole)) * 1_000_000)
    #if canImport(Darwin)
    var timeout = timeval(tv_sec: whole, tv_usec: Int32(micros))
    #else
    var timeout = timeval(tv_sec: whole, tv_usec: micros)
    #endif
    let length = socklen_t(MemoryLayout<timeval>.size)
    guard withUnsafePointer(to: &timeout, { setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, length) }) == 0,
          withUnsafePointer(to: &timeout, { setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, length) }) == 0 else {
        throw LocalTransportError.socketFailure("timeout configuration")
    }
}

private func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var written = 0
        while written < rawBuffer.count {
            let count = systemWrite(fd, base.advanced(by: written), rawBuffer.count - written)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw LocalTransportError.timedOut }
                throw LocalTransportError.socketFailure("write")
            }
            guard count > 0 else { throw LocalTransportError.connectionClosed }
            written += count
        }
    }
}

private func readLine(from fd: Int32) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 8_192)
    while result.count <= headlessMaximumMessageBytes {
        let count = systemRead(fd, &buffer, buffer.count)
        if count < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw LocalTransportError.timedOut }
            throw LocalTransportError.socketFailure("read")
        }
        guard count > 0 else { throw LocalTransportError.connectionClosed }
        if let newline = buffer[..<count].firstIndex(of: 0x0A) {
            result.append(contentsOf: buffer[..<newline])
            result.append(0x0A)
            return result
        }
        result.append(contentsOf: buffer[..<count])
    }
    throw LocalTransportError.messageTooLarge
}

private func peerUserID(fd: Int32) throws -> uid_t {
    #if canImport(Darwin)
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0 else { throw LocalTransportError.socketFailure("peer credential check") }
    return uid
    #else
    struct PeerCredentials { var pid: pid_t = 0; var uid: uid_t = 0; var gid: gid_t = 0 }
    var credentials = PeerCredentials()
    var length = socklen_t(MemoryLayout<PeerCredentials>.size)
    let soPeerCred: Int32 = 17
    guard withUnsafeMutablePointer(to: &credentials, {
        getsockopt(fd, SOL_SOCKET, soPeerCred, $0, &length)
    }) == 0 else { throw LocalTransportError.socketFailure("peer credential check") }
    return credentials.uid
    #endif
}

private func systemErrorMessage() -> String {
    String(cString: strerror(errno))
}

#if canImport(Darwin)
private func systemConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 { Darwin.connect(fd, address, length) }
private func systemBind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 { Darwin.bind(fd, address, length) }
private func systemListen(_ fd: Int32, _ backlog: Int32) -> Int32 { Darwin.listen(fd, backlog) }
private func systemAccept(_ fd: Int32) -> Int32 { Darwin.accept(fd, nil, nil) }
private func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { Darwin.read(fd, buffer, count) }
private func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { Darwin.send(fd, buffer, count, 0) }
private func systemShutdown(_ fd: Int32) { _ = Darwin.shutdown(fd, SHUT_RDWR) }
private func systemClose(_ fd: Int32) { _ = Darwin.close(fd) }
private func systemUnlink(_ path: String) -> Int32 { Darwin.unlink(path) }
#else
private func systemConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 { Glibc.connect(fd, address, length) }
private func systemBind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 { Glibc.bind(fd, address, length) }
private func systemListen(_ fd: Int32, _ backlog: Int32) -> Int32 { Glibc.listen(fd, backlog) }
private func systemAccept(_ fd: Int32) -> Int32 { Glibc.accept(fd, nil, nil) }
private func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { Glibc.read(fd, buffer, count) }
private func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { Glibc.send(fd, buffer, count, Int32(MSG_NOSIGNAL)) }
private func systemShutdown(_ fd: Int32) { _ = Glibc.shutdown(fd, Int32(SHUT_RDWR)) }
private func systemClose(_ fd: Int32) { _ = Glibc.close(fd) }
private func systemUnlink(_ path: String) -> Int32 { Glibc.unlink(path) }
#endif
