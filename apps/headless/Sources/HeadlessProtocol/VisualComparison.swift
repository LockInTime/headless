import Foundation

public enum VisualComparisonError: Error, CustomStringConvertible {
    case toolUnavailable
    case failed(String)

    public var description: String {
        switch self {
        case .toolUnavailable: return "ffmpeg is required for visual comparison"
        case .failed(let detail): return "Visual comparison failed: \(detail)"
        }
    }
}

/// Image comparison is intentionally delegated to ffmpeg, which is already a
/// required recording dependency. It provides a deterministic difference image
/// without adding a second image parser to either host.
public enum VisualComparison {
    public static func compare(before: URL, after: URL, difference: URL) throws -> JSONValue {
        let executable = "/usr/bin/env"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["ffmpeg", "-hide_banner", "-y", "-i", before.path, "-i", after.path,
                             "-filter_complex", "[0:v][1:v]blend=all_mode=difference,format=rgba",
                             "-frames:v", "1", difference.path]
        let error = Pipe()
        process.standardError = error
        process.standardOutput = Pipe()
        do { try process.run() }
        catch { throw VisualComparisonError.toolUnavailable }
        process.waitUntilExit()
        let output = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw VisualComparisonError.failed(String(output.suffix(600)))
        }
        return .object([
            "engine": .string("ffmpeg-blend-difference"),
            "differenceGenerated": .bool(true),
            "note": .string("Inspect the private difference PNG; a transparent/black image means no visible pixel difference."),
        ])
    }
}
