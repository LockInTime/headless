import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum CDPError: Error, CustomStringConvertible {
    case invalidResponse(String)
    case commandFailed(String)
    case timedOut
    case rootNotSupported

    var description: String {
        switch self {
        case .invalidResponse(let value): return "Invalid Chromium response: \(value)"
        case .commandFailed(let value): return "Chromium command failed: \(value)"
        case .timedOut: return "Chromium operation timed out"
        case .rootNotSupported: return "Headless refuses to disable Chromium's sandbox. Run it as a non-root user."
        }
    }
}

private final class PendingCDPResponse: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var response: Result<[String: Any], Error>?

    func complete(_ value: Result<[String: Any], Error>) {
        lock.lock()
        guard case nil = response else { lock.unlock(); return }
        response = value
        lock.unlock()
        ready.signal()
    }

    func wait(timeout: DispatchTime) -> Result<[String: Any], Error>? {
        guard ready.wait(timeout: timeout) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return response
    }
}

final class CDPConnection: @unchecked Sendable {
    private let transport: CDPTransport
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let eventLock = NSLock()
    private let readerQueue = DispatchQueue(label: "com.headless.cdp-reader", qos: .userInitiated)
    private var nextID = 1
    private var pending: [Int: PendingCDPResponse] = [:]
    private var closed = false
    private var eventHandler: (@Sendable ([String: Any]) -> Void)?

    init(inputDescriptor: Int32, outputDescriptor: Int32) {
        transport = RawDevToolsPipe(inputDescriptor: inputDescriptor, outputDescriptor: outputDescriptor)
        readerQueue.async { [weak self] in self?.readLoop() }
    }

    func setEventHandler(_ handler: @escaping @Sendable ([String: Any]) -> Void) {
        eventLock.lock(); eventHandler = handler; eventLock.unlock()
    }

    func command(
        _ method: String,
        parameters: [String: Any] = [:],
        sessionID: String? = nil,
        timeoutMilliseconds: Int32 = 125_000
    ) throws -> [String: Any] {
        let response = PendingCDPResponse()
        let id = try reserveID(response: response)
        do { try send(id: id, method: method, parameters: parameters, sessionID: sessionID) }
        catch {
            stateLock.lock(); pending.removeValue(forKey: id); stateLock.unlock()
            throw error
        }
        let timeout = DispatchTime.now() + .milliseconds(Int(timeoutMilliseconds))
        guard let result = response.wait(timeout: timeout) else {
            stateLock.lock(); pending.removeValue(forKey: id); stateLock.unlock()
            throw CDPError.timedOut
        }
        return try result.get()
    }

    /// Sends an acknowledgement that does not need a result. The dedicated
    /// reader consumes and discards its response while other commands remain
    /// independently addressable by id.
    func sendWithoutWaiting(
        _ method: String,
        parameters: [String: Any] = [:],
        sessionID: String? = nil
    ) throws {
        let id = try reserveID(response: nil)
        try send(id: id, method: method, parameters: parameters, sessionID: sessionID)
    }

    func close() {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        let waiting = Array(pending.values)
        pending.removeAll()
        stateLock.unlock()
        transport.close()
        let error = CDPError.invalidResponse("DevTools pipe closed")
        waiting.forEach { $0.complete(.failure(error)) }
    }

    private func reserveID(response: PendingCDPResponse?) throws -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !closed else { throw CDPError.invalidResponse("DevTools pipe closed") }
        let id = nextID
        nextID += 1
        if let response { pending[id] = response }
        return id
    }

    private func send(
        id: Int, method: String, parameters: [String: Any], sessionID: String?
    ) throws {
        var payload: [String: Any] = ["id": id, "method": method, "params": parameters]
        if let sessionID { payload["sessionId"] = sessionID }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw CDPError.invalidResponse("could not encode command")
        }
        writeLock.lock(); defer { writeLock.unlock() }
        try transport.send(text: text)
    }

    private func readLoop() {
        while true {
            do {
                let text = try transport.receiveText(timeoutMilliseconds: 1_000)
                let data = Data(text.utf8)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                if let id = (object["id"] as? NSNumber)?.intValue {
                    stateLock.lock(); let response = pending.removeValue(forKey: id); stateLock.unlock()
                    guard let response else { continue }
                    if let error = object["error"] as? [String: Any] {
                        response.complete(.failure(CDPError.commandFailed(
                            error["message"] as? String ?? String(describing: error)
                        )))
                    } else {
                        response.complete(.success(object["result"] as? [String: Any] ?? [:]))
                    }
                } else {
                    eventLock.lock(); let handler = eventHandler; eventLock.unlock()
                    handler?(object)
                }
            } catch CDPError.timedOut {
                stateLock.lock(); let shouldStop = closed; stateLock.unlock()
                if shouldStop { return }
            } catch {
                failPending(error)
                return
            }
        }
    }

    private func failPending(_ error: Error) {
        stateLock.lock()
        closed = true
        let waiting = Array(pending.values)
        pending.removeAll()
        stateLock.unlock()
        transport.close()
        waiting.forEach { $0.complete(.failure(error)) }
    }
}

private protocol CDPTransport: AnyObject, Sendable {
    func send(text: String) throws
    func receiveText(timeoutMilliseconds: Int32) throws -> String
    func close()
}

private final class RawDevToolsPipe: CDPTransport, @unchecked Sendable {
    private let inputDescriptor: Int32
    private let outputDescriptor: Int32
    private let stateLock = NSLock()
    private var pending: [UInt8] = []
    private var closed = false
    // Page.captureScreenshot returns base64 in a CDP response. This is an
    // internal browser pipe (not the 1 MiB agent socket), so it needs room for
    // the bounded 64 MP capture while remaining finite against a hostile page.
    private let maximumMessageBytes = 128 * 1_048_576

    init(inputDescriptor: Int32, outputDescriptor: Int32) {
        self.inputDescriptor = inputDescriptor
        self.outputDescriptor = outputDescriptor
    }

    deinit { close() }

    func close() {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        stateLock.unlock()
        systemClose(inputDescriptor)
        systemClose(outputDescriptor)
    }

    func send(text: String) throws {
        var bytes = Array(text.utf8)
        guard bytes.count <= maximumMessageBytes else {
            throw CDPError.invalidResponse("DevTools pipe message too large")
        }
        bytes.append(0)
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                try waitUntilReady(descriptor: outputDescriptor, events: Int16(POLLOUT))
                let count = systemPipeWrite(outputDescriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CDPError.invalidResponse("DevTools pipe write: \(lastSystemError())")
                }
                guard count > 0 else { throw CDPError.invalidResponse("DevTools pipe closed during write") }
                offset += count
            }
        }
    }

    func receiveText(timeoutMilliseconds: Int32) throws -> String {
        while true {
            if let terminator = pending.firstIndex(of: 0) {
                let message = Array(pending[..<terminator])
                pending.removeFirst(terminator + 1)
                guard let text = String(bytes: message, encoding: .utf8) else {
                    throw CDPError.invalidResponse("non-UTF8 DevTools pipe message")
                }
                return text
            }
            guard pending.count <= maximumMessageBytes else {
                throw CDPError.invalidResponse("DevTools pipe message too large")
            }
            try waitUntilReady(
                descriptor: inputDescriptor,
                events: Int16(POLLIN),
                timeoutMilliseconds: timeoutMilliseconds
            )
            var buffer = [UInt8](repeating: 0, count: 8_192)
            let count = systemRead(inputDescriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw CDPError.invalidResponse("DevTools pipe read: \(lastSystemError())")
            }
            guard count > 0 else { throw CDPError.invalidResponse("DevTools pipe closed") }
            pending.append(contentsOf: buffer[..<count])
        }
    }

    private func waitUntilReady(
        descriptor: Int32,
        events: Int16,
        timeoutMilliseconds: Int32 = 125_000
    ) throws {
        var descriptorState = pollfd(fd: descriptor, events: events, revents: 0)
        let result = systemPoll(&descriptorState, timeoutMilliseconds)
        if result == 0 { throw CDPError.timedOut }
        if result < 0 {
            if errno == EINTR { return try waitUntilReady(descriptor: descriptor, events: events) }
            throw CDPError.invalidResponse("DevTools pipe poll: \(lastSystemError())")
        }
        guard (descriptorState.revents & (Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL))) == 0 else {
            throw CDPError.invalidResponse("DevTools pipe closed")
        }
    }
}

private func lastSystemError() -> String { String(cString: strerror(errno)) }

#if canImport(Darwin)
private func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { Darwin.read(fd, buffer, count) }
private func systemPipeWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { Darwin.write(fd, buffer, count) }
private func systemClose(_ fd: Int32) { _ = Darwin.close(fd) }
private func systemPoll(_ descriptor: UnsafeMutablePointer<pollfd>, _ timeout: Int32) -> Int32 { Darwin.poll(descriptor, 1, timeout) }
#else
private func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { Glibc.read(fd, buffer, count) }
private func systemPipeWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { Glibc.write(fd, buffer, count) }
private func systemClose(_ fd: Int32) { _ = Glibc.close(fd) }
private func systemPoll(_ descriptor: UnsafeMutablePointer<pollfd>, _ timeout: Int32) -> Int32 { Glibc.poll(descriptor, 1, timeout) }
#endif
