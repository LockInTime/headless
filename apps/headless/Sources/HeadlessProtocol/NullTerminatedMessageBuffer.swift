/// Incrementally frames NUL-terminated byte messages without rescanning bytes
/// that were already inspected. Consumed prefixes are compacted only after a
/// complete message, keeping large chunked payloads linear in their size.
package struct NullTerminatedMessageBuffer {
    private var storage: [UInt8] = []
    private var messageStart = 0
    private var scanOffset = 0

    package init() {}

    package var bufferedByteCount: Int { storage.count - messageStart }
    package var unscannedByteCount: Int { storage.count - scanOffset }

    package mutating func append(contentsOf bytes: ArraySlice<UInt8>) {
        storage.append(contentsOf: bytes)
    }

    package mutating func popFirst() -> [UInt8]? {
        guard let terminator = storage[scanOffset...].firstIndex(of: 0) else {
            scanOffset = storage.endIndex
            return nil
        }
        let message = Array(storage[messageStart..<terminator])
        messageStart = terminator + 1
        scanOffset = messageStart
        compactConsumedPrefix()
        return message
    }

    private mutating func compactConsumedPrefix() {
        if messageStart == storage.count {
            storage.removeAll(keepingCapacity: true)
            messageStart = 0
            scanOffset = 0
        } else if messageStart >= 65_536, messageStart >= storage.count / 2 {
            let removed = messageStart
            storage.removeFirst(removed)
            messageStart = 0
            scanOffset -= removed
        }
    }
}
