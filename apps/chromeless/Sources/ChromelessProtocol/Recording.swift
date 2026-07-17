import Foundation

public enum RecordingError: Error, CustomStringConvertible {
    case unavailable
    case alreadyActive
    case notActive
    case encoderFailed(Int32)
    case timedOut
    case captureFailed(String)

    public var description: String {
        switch self {
        case .unavailable: return "FFmpeg is required for browser recording but was not found"
        case .alreadyActive: return "A recording is already active for this session"
        case .notActive: return "No recording is active for this session"
        case .encoderFailed(let status): return "FFmpeg exited with status \(status)"
        case .timedOut: return "Recording did not stop before the deadline"
        case .captureFailed(let reason): return "Browser frame capture failed: \(reason)"
        }
    }
}

public final class BrowserRecording: @unchecked Sendable {
    public typealias CaptureFrame = () throws -> Data

    public let outputURL: URL
    public let fps: Double
    public let provider = "browser-ffmpeg"
    public let startedAt = Date()

    private let process: Process
    private let inputPipe: Pipe
    private let captureFrame: CaptureFrame
    private let queue = DispatchQueue(label: "com.chromeless.browser-recording", qos: .userInitiated)
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var stopRequested = false
    private var frameCount = 0
    private var droppedFrames = 0
    private var failure: Error?

    public init(outputURL: URL, fps: Double, captureFrame: @escaping CaptureFrame) throws {
        guard let executable = Self.resolveFFmpeg() else { throw RecordingError.unavailable }
        self.outputURL = outputURL
        self.fps = fps
        self.captureFrame = captureFrame
        inputPipe = Pipe()
        process = Process()
        process.executableURL = executable
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "image2pipe", "-framerate", String(format: "%.3f", fps),
            "-vcodec", "png", "-i", "pipe:0", "-an",
            "-c:v", "mpeg4", "-q:v", "4", "-pix_fmt", "yuv420p",
            "-movflags", "+faststart", outputURL.path,
        ]
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw RecordingError.captureFailed(error.localizedDescription) }
        queue.async { [weak self] in self?.captureLoop() }
    }

    public func status() -> JSONValue {
        lock.lock()
        let active = process.isRunning && !stopRequested && failure == nil
        let frames = frameCount
        let dropped = droppedFrames
        let error = failure.map(String.init(describing:))
        lock.unlock()
        var result: [String: JSONValue] = [
            "active": .bool(active), "provider": .string(provider),
            "path": .string(outputURL.path), "fps": .number(fps),
            "frames": .number(Double(frames)), "droppedFrames": .number(Double(dropped)),
            "durationMs": .number(Date().timeIntervalSince(startedAt) * 1_000),
        ]
        if let error { result["error"] = .string(error) }
        return .object(result)
    }

    public func stop(timeout: TimeInterval = 15) throws -> JSONValue {
        lock.lock(); stopRequested = true; lock.unlock()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            throw RecordingError.timedOut
        }
        lock.lock(); let stoppedFailure = failure; lock.unlock()
        if let stoppedFailure { throw stoppedFailure }
        guard process.terminationStatus == 0 else {
            throw RecordingError.encoderFailed(process.terminationStatus)
        }
        return status()
    }

    private func captureLoop() {
        let interval = 1.0 / fps
        var consecutiveFailures = 0
        while true {
            lock.lock(); let shouldStop = stopRequested; lock.unlock()
            if shouldStop { break }
            let began = Date()
            do {
                let frame = try captureFrame()
                try inputPipe.fileHandleForWriting.write(contentsOf: frame)
                lock.lock(); frameCount += 1; lock.unlock()
                consecutiveFailures = 0
            } catch {
                consecutiveFailures += 1
                lock.lock(); droppedFrames += 1; lock.unlock()
                if consecutiveFailures >= max(10, Int(fps * 3)) {
                    lock.lock(); failure = RecordingError.captureFailed(String(describing: error)); lock.unlock()
                    break
                }
            }
            let remaining = interval - Date().timeIntervalSince(began)
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        }
        try? inputPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        finished.signal()
    }

    public static func isAvailable() -> Bool { resolveFFmpeg() != nil }

    private static func resolveFFmpeg() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["CHROMELESS_FFMPEG_EXECUTABLE"],
            "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg",
        ].compactMap { $0 }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }
}
