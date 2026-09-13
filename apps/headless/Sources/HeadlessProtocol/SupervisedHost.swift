import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Owner-pipe reads that mean the SDK/CLI is gone. EOF and unexpected data
/// close the host. `EINTR` / `EAGAIN` / `EWOULDBLOCK` must not, or a
/// spurious DispatchSource wakeup kills a live supervised session.
public func supervisedOwnerChannelClosed(readCount: Int, errnoValue: Int32) -> Bool {
    if readCount >= 0 { return true }
    return errnoValue != EINTR && errnoValue != EAGAIN && errnoValue != EWOULDBLOCK
}

public final class SupervisedHostOwnerMonitor: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var active = true

    public static func startIfRequested(
        onOwnerExit: @escaping @Sendable () -> Void
    ) -> SupervisedHostOwnerMonitor? {
        guard ProcessInfo.processInfo.environment["HEADLESS_SUPERVISED"] == "1" else {
            return nil
        }
        return SupervisedHostOwnerMonitor(onOwnerExit: onOwnerExit)
    }

    private init(onOwnerExit: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var byte: UInt8 = 0
            let count = withUnsafeMutableBytes(of: &byte) { buffer in
                read(STDIN_FILENO, buffer.baseAddress, 1)
            }
            if supervisedOwnerChannelClosed(readCount: count, errnoValue: errno) {
                self.stop()
                onOwnerExit()
            }
        }
        source.resume()
    }

    public func stop() {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        active = false
        source.cancel()
        lock.unlock()
    }

    deinit { stop() }
}
