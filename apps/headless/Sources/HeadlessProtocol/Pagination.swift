import Foundation

public enum PaginationDirection: Sendable {
    case fromStart
    case newestBatchFirst
}

public struct PaginationPage: Sendable {
    public let values: [JSONValue]
    public let nextCursor: String?
    public let consumed: Int
    public let total: Int

    public var truncated: Bool { nextCursor != nil }
}

/// Keeps opaque cursors in the owning host process. Tokens carry no collection
/// state, and the bounded registry disappears on restart.
public final class PaginationCursorStore: @unchecked Sendable {
    private struct Record {
        let context: String
        let fingerprint: String
        let position: Int
        let direction: PaginationDirection
        let issuedAt: TimeInterval
        let expiresAt: TimeInterval
    }

    public static let maximumLimit = 250
    public static let cursorMaximumBytes = 64
    public static let lifetimeSeconds: TimeInterval = 300
    private static let maximumRecords = 512
    private static let maximumPageValueBytes = 768 * 1_024

    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private var records: [String: Record] = [:]

    public init(now: @escaping @Sendable () -> TimeInterval = {
        ProcessInfo.processInfo.systemUptime
    }) {
        self.now = now
    }

    public func page(
        values: [JSONValue], context: String, limit: Int, cursor: String?,
        direction: PaginationDirection
    ) throws -> PaginationPage {
        let boundedLimit = max(1, min(limit, Self.maximumLimit))
        let fingerprint = Self.fingerprint(values)
        let currentTime = now()
        let position: Int
        if let cursor {
            position = try resolve(
                cursor, context: context, fingerprint: fingerprint,
                direction: direction, currentTime: currentTime
            )
        } else {
            position = direction == .fromStart ? 0 : values.count
        }

        let pageValues: [JSONValue]
        let nextPosition: Int?
        switch direction {
        case .fromStart:
            let start = min(position, values.count)
            let requestedEnd = min(values.count, start + boundedLimit)
            pageValues = try Self.valuesWithinBudget(
                Array(values[start..<requestedEnd]), keepingNewest: false
            )
            let end = start + pageValues.count
            nextPosition = end < values.count ? end : nil
        case .newestBatchFirst:
            let end = min(position, values.count)
            let requestedStart = max(0, end - boundedLimit)
            pageValues = try Self.valuesWithinBudget(
                Array(values[requestedStart..<end]), keepingNewest: true
            )
            let start = end - pageValues.count
            nextPosition = start > 0 ? start : nil
        }

        let nextCursor = nextPosition.map {
            issue(
                context: context, fingerprint: fingerprint, position: $0,
                direction: direction, currentTime: currentTime
            )
        }
        return PaginationPage(
            values: pageValues, nextCursor: nextCursor,
            consumed: nextPosition ?? (direction == .fromStart ? values.count : 0),
            total: values.count
        )
    }

    private func resolve(
        _ cursor: String, context: String, fingerprint: String,
        direction: PaginationDirection, currentTime: TimeInterval
    ) throws -> Int {
        guard cursor.utf8.count <= Self.cursorMaximumBytes,
              let uuid = UUID(uuidString: cursor),
              uuid.uuidString.caseInsensitiveCompare(cursor) == .orderedSame else {
            throw HostError(code: .paginationCursorInvalid, message: "Pagination cursor is invalid.")
        }
        let key = uuid.uuidString.lowercased()
        lock.lock()
        defer { lock.unlock() }
        guard let record = records[key] else {
            throw HostError(code: .paginationCursorInvalid, message: "Pagination cursor is unknown.")
        }
        guard record.expiresAt > currentTime else {
            records.removeValue(forKey: key)
            throw HostError(code: .paginationCursorExpired, message: "Pagination cursor has expired.")
        }
        guard record.context == context, record.direction == direction else {
            throw HostError(
                code: .paginationCursorScopeMismatch,
                message: "Pagination cursor does not belong to this command and filter set."
            )
        }
        guard record.fingerprint == fingerprint else {
            throw HostError(
                code: .paginationCursorStale,
                message: "The paginated collection changed after the cursor was issued."
            )
        }
        return record.position
    }

    private func issue(
        context: String, fingerprint: String, position: Int,
        direction: PaginationDirection, currentTime: TimeInterval
    ) -> String {
        let token = UUID().uuidString.lowercased()
        lock.lock()
        records = records.filter { $0.value.expiresAt > currentTime }
        if records.count >= Self.maximumRecords,
           let oldest = records.min(by: { $0.value.issuedAt < $1.value.issuedAt })?.key {
            records.removeValue(forKey: oldest)
        }
        records[token] = Record(
            context: context, fingerprint: fingerprint, position: position,
            direction: direction, issuedAt: currentTime,
            expiresAt: currentTime + Self.lifetimeSeconds
        )
        lock.unlock()
        return token
    }

    private static func fingerprint(_ values: [JSONValue]) -> String {
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x9e3779b185ebca87
        for value in values {
            let bytes = (try? ProtocolCodec.encoder.encode(value)) ?? Data()
            var length = UInt64(bytes.count).littleEndian
            withUnsafeBytes(of: &length) { update($0, first: &first, second: &second) }
            bytes.withUnsafeBytes { update($0, first: &first, second: &second) }
        }
        return String(format: "%016llx%016llx-%d", first, second, values.count)
    }

    private static func valuesWithinBudget(
        _ values: [JSONValue], keepingNewest: Bool
    ) throws -> [JSONValue] {
        var kept: [JSONValue] = []
        var encodedBytes = 2
        let candidates = keepingNewest ? Array(values.reversed()) : values
        for value in candidates {
            let size = try ProtocolCodec.encoder.encode(value).count + (kept.isEmpty ? 0 : 1)
            guard size + 2 <= maximumPageValueBytes else {
                if kept.isEmpty {
                    throw HostError(
                        code: .operationFailed,
                        message: "A pagination item exceeds the response budget."
                    )
                }
                break
            }
            guard encodedBytes + size <= maximumPageValueBytes else { break }
            kept.append(value)
            encodedBytes += size
        }
        return keepingNewest ? Array(kept.reversed()) : kept
    }

    private static func update(
        _ bytes: UnsafeRawBufferPointer, first: inout UInt64, second: inout UInt64
    ) {
        for byte in bytes {
            first = (first ^ UInt64(byte)) &* 0x100000001b3
            second = (second ^ UInt64(byte)) &* 0x9e3779b185ebca87
        }
    }
}
