import Foundation

public enum CaptureFormatError: Error, CustomStringConvertible {
    case unsupportedScreenshotFormat(String)
    case unsupportedRecordingFormat(String)
    case unsupportedRecordingQuality(String)
    case mismatchedOutputFormat(expected: String, actual: String)

    public var description: String {
        switch self {
        case .unsupportedScreenshotFormat(let value):
            return "Unsupported screenshot format: \(value)"
        case .unsupportedRecordingFormat(let value):
            return "Unsupported recording format: \(value)"
        case .unsupportedRecordingQuality(let value):
            return "Unsupported recording quality: \(value)"
        case .mismatchedOutputFormat(let expected, let actual):
            return "Output format .\(actual) does not match the active .\(expected) recording"
        }
    }
}

public enum ScreenshotFormat: String, CaseIterable, Sendable {
    case png
    case jpeg
    case pdf

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .pdf: return "pdf"
        }
    }

    public var artifactExtensions: Set<String> {
        switch self {
        case .png: return ["png"]
        case .jpeg: return ["jpg", "jpeg"]
        case .pdf: return ["pdf"]
        }
    }

    public var browserScreenshotFormat: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpeg"
        case .pdf: return "png"
        }
    }

    public var isImage: Bool { self != .pdf }

    public static let artifactExtensions: Set<String> = Set(
        ScreenshotFormat.allCases.flatMap(\.artifactExtensions)
    )

    public static func parse(_ value: String) throws -> ScreenshotFormat {
        switch value.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "pdf": return .pdf
        default: throw CaptureFormatError.unsupportedScreenshotFormat(value)
        }
    }
}

public func screenshotFormat(explicit: String?, output: String?) throws -> ScreenshotFormat {
    if let explicit { return try ScreenshotFormat.parse(explicit) }
    if let output, let ext = artifactExtension(output), !ext.isEmpty {
        return try ScreenshotFormat.parse(ext)
    }
    return .png
}

public enum RecordingFormat: String, CaseIterable, Sendable {
    case mp4
    case mov
    case webm
    case gif

    public var fileExtension: String { rawValue }

    public var videoCodec: String {
        switch self {
        case .mp4, .mov: return "mpeg4"
        case .webm: return "libvpx-vp9"
        case .gif: return "gif"
        }
    }

    public var container: String { rawValue }

    public static let artifactExtensions: Set<String> = Set(
        RecordingFormat.allCases.map(\.fileExtension)
    )

    public static func parse(_ value: String) throws -> RecordingFormat {
        guard let format = RecordingFormat(rawValue: value.lowercased()) else {
            throw CaptureFormatError.unsupportedRecordingFormat(value)
        }
        return format
    }
}

public enum RecordingQuality: String, CaseIterable, Sendable {
    case fast
    case balanced
    case high

    public static func parse(_ value: String) throws -> RecordingQuality {
        guard let quality = RecordingQuality(rawValue: value.lowercased()) else {
            throw CaptureFormatError.unsupportedRecordingQuality(value)
        }
        return quality
    }
}

public func recordingFormat(explicit: String?, output: String?) throws -> RecordingFormat {
    if let explicit { return try RecordingFormat.parse(explicit) }
    if let output, let ext = artifactExtension(output), !ext.isEmpty {
        return try RecordingFormat.parse(ext)
    }
    return .mp4
}

public func artifactExtension(_ value: String) -> String? {
    let ext = URL(fileURLWithPath: value).pathExtension.lowercased()
    return ext.isEmpty ? nil : ext
}
