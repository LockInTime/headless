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
    public let format: RecordingFormat
    public let quality: RecordingQuality
    public let provider = "browser-ffmpeg"
    public let startedAt = Date()

    private let process: Process
    private let inputPipe: Pipe
    private let captureFrame: CaptureFrame
    private let queue = DispatchQueue(label: "com.headless.browser-recording", qos: .userInitiated)
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var stopRequested = false
    private var frameCount = 0
    private var droppedFrames = 0
    private var failure: Error?
    private var processExited = false

    public init(
        outputURL: URL,
        fps: Double,
        format: RecordingFormat = .mp4,
        quality: RecordingQuality = .balanced,
        captureFrame: @escaping CaptureFrame
    ) throws {
        guard let executable = Self.ffmpegExecutable() else { throw RecordingError.unavailable }
        self.outputURL = outputURL
        self.fps = fps
        self.format = format
        self.quality = quality
        self.captureFrame = captureFrame
        inputPipe = Pipe()
        process = Process()
        process.executableURL = executable
        process.arguments = Self.ffmpegArguments(
            fps: fps,
            format: format,
            quality: quality,
            outputPath: outputURL.path
        )
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.processExited = true; self.lock.unlock()
        }
        var firstFrame: Data?
        var firstFrameError: Error?
        let initialCaptureAttempts = 6
        for attempt in 0..<initialCaptureAttempts where firstFrame == nil {
            do { firstFrame = try captureFrame() }
            catch {
                firstFrameError = error
                if attempt < initialCaptureAttempts - 1 {
                    Thread.sleep(forTimeInterval: 0.05 * pow(2, Double(attempt)))
                }
            }
        }
        guard let firstFrame else {
            throw RecordingError.captureFailed(
                "initial browser frame was unavailable after \(initialCaptureAttempts) attempts: \(firstFrameError.map(String.init(describing:)) ?? "unknown error")"
            )
        }
        do { try process.run() }
        catch { throw RecordingError.captureFailed(error.localizedDescription) }
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: firstFrame)
            frameCount = 1
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            process.terminate()
            process.waitUntilExit()
            throw RecordingError.captureFailed(error.localizedDescription)
        }
        queue.async { [weak self] in self?.captureLoop() }
    }

    private static func ffmpegArguments(
        fps: Double,
        format: RecordingFormat,
        quality: RecordingQuality,
        outputPath: String
    ) -> [String] {
        let input = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "image2pipe", "-framerate", String(format: "%.3f", fps),
            "-vcodec", "png", "-i", "pipe:0", "-an",
        ]

        switch format {
        case .mp4, .mov:
            let qscale: String
            switch quality {
            case .fast: qscale = "6"
            case .balanced: qscale = "4"
            case .high: qscale = "2"
            }
            return input + [
                "-c:v", "mpeg4", "-q:v", qscale, "-pix_fmt", "yuv420p",
                "-movflags", "+faststart", outputPath,
            ]
        case .webm:
            let crf: String
            switch quality {
            case .fast: crf = "40"
            case .balanced: crf = "34"
            case .high: crf = "28"
            }
            return input + [
                "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", crf,
                "-deadline", quality == .high ? "good" : "realtime",
                "-pix_fmt", "yuv420p", outputPath,
            ]
        case .gif:
            let scale: String
            switch quality {
            case .fast: scale = "960:-1"
            case .balanced: scale = "1280:-1"
            case .high: scale = "-1:-1"
            }
            return input + [
                "-vf", "fps=\(String(format: "%.3f", fps)),scale=\(scale):flags=lanczos",
                "-loop", "0", outputPath,
            ]
        }
    }

    public func status() -> JSONValue {
        lock.lock()
        let active = !processExited && !stopRequested && failure == nil
        let frames = frameCount
        let dropped = droppedFrames
        let error = failure.map(String.init(describing:))
        lock.unlock()
        var result: [String: JSONValue] = [
            "active": .bool(active), "provider": .string(provider),
            "path": .string(outputURL.path), "fps": .number(fps),
            "format": .string(format.rawValue),
            "container": .string(format.container),
            "videoCodec": .string(format.videoCodec),
            "quality": .string(quality.rawValue),
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
            lock.lock(); let shouldStop = stopRequested || processExited; lock.unlock()
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
        lock.lock(); processExited = true; lock.unlock()
        finished.signal()
    }

    public static func isAvailable() -> Bool { ffmpegExecutable() != nil }

    /// Resolve only an absolute regular executable. Recording and visual
    /// comparison are local tools, but neither should be redirected by a
    /// page-controlled or inherited PATH entry.
    public static func ffmpegExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        systemCandidates: [String] = [
            "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg",
        ]
    ) -> URL? {
        let candidates = [environment["HEADLESS_FFMPEG_EXECUTABLE"]].compactMap { $0 }
            + systemCandidates
        let manager = FileManager.default
        for candidate in candidates where candidate.hasPrefix("/") {
            let executable = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().standardizedFileURL
            guard manager.isExecutableFile(atPath: executable.path),
                  let attributes = try? manager.attributesOfItem(atPath: executable.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                continue
            }
            return executable
        }
        return nil
    }
}
