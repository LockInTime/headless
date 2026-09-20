import Foundation

public struct NetworkIdleSnapshot: Equatable, Sendable {
    public let activeRequestCount: Int
    public let quietMilliseconds: Int
    public let overflowed: Bool

    public var isIdle: Bool {
        !overflowed && activeRequestCount == 0
            && quietMilliseconds >= NetworkIdleTracker.quietPeriodMilliseconds
    }
}

/// Tracks only browser-owned request identifiers. Request metadata and page
/// URLs never leave the engine adapter or enter the wait response.
public final class NetworkIdleTracker: @unchecked Sendable {
    public static let quietPeriodMilliseconds = 500
    public static let maximumTrackedRequests = 4_096

    private static let persistentResourceTypes: Set<String> = ["eventsource", "websocket"]

    private let lock = NSLock()
    private let monotonicNow: @Sendable () -> TimeInterval
    private var activeRequestIDs: Set<String> = []
    private var lastActivity: TimeInterval
    private var overflowed = false

    public init(
        monotonicNow: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.monotonicNow = monotonicNow
        self.lastActivity = monotonicNow()
    }

    public func beginWait() -> TimeInterval {
        monotonicNow()
    }

    public func requestDidStart(identifier: String, resourceType: String?) {
        lock.lock()
        defer { lock.unlock() }

        let now = monotonicNow()
        let persistent = resourceType.map {
            Self.persistentResourceTypes.contains($0.lowercased())
        } ?? false
        if persistent {
            if activeRequestIDs.remove(identifier) != nil { lastActivity = now }
            return
        }

        lastActivity = now
        guard identifier.utf8.count <= 512 else {
            overflowed = true
            return
        }
        if activeRequestIDs.contains(identifier) { return }
        guard activeRequestIDs.count < Self.maximumTrackedRequests else {
            overflowed = true
            return
        }
        activeRequestIDs.insert(identifier)
    }

    public func requestDidFinish(identifier: String) {
        lock.lock()
        defer { lock.unlock() }
        if activeRequestIDs.remove(identifier) != nil {
            lastActivity = monotonicNow()
        }
    }

    public func snapshot(since waitStartedAt: TimeInterval) -> NetworkIdleSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let quietStart = max(waitStartedAt, lastActivity)
        let quietMilliseconds = max(0, Int((monotonicNow() - quietStart) * 1_000))
        return NetworkIdleSnapshot(
            activeRequestCount: activeRequestIDs.count,
            quietMilliseconds: quietMilliseconds,
            overflowed: overflowed
        )
    }
}
