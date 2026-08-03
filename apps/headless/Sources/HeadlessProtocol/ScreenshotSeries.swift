import Foundation

public enum ScreenshotSeriesError: Error, CustomStringConvertible {
    case invalidPlan
    case emptyPlan

    public var description: String {
        switch self {
        case .invalidPlan: return "Browser returned an invalid screenshot series plan"
        case .emptyPlan: return "Browser returned no screenshot positions"
        }
    }
}

public struct ScreenshotSeriesPoint: Equatable, Sendable {
    public let y: Double
    public let label: String
    public let kind: String

    public init(y: Double, label: String, kind: String) {
        self.y = y
        self.label = label
        self.kind = kind
    }
}

public func screenshotSeriesPoints(from plan: JSONValue) throws -> [ScreenshotSeriesPoint] {
    guard case .object(let object) = plan,
          case .array(let values)? = object["points"] else {
        throw ScreenshotSeriesError.invalidPlan
    }
    let points = try values.prefix(80).map { value -> ScreenshotSeriesPoint in
        guard case .object(let item) = value,
              let y = item["y"]?.numberValue, y.isFinite else {
            throw ScreenshotSeriesError.invalidPlan
        }
        return ScreenshotSeriesPoint(
            y: y,
            label: String((item["label"]?.stringValue ?? "viewport").prefix(80)),
            kind: String((item["kind"]?.stringValue ?? "viewport").prefix(32))
        )
    }
    guard !points.isEmpty else { throw ScreenshotSeriesError.emptyPlan }
    return points
}

public func screenshotSeriesPrefix(parameters: [String: JSONValue], mode: String) throws -> String {
    if let requested = parameters["outputPrefix"]?.stringValue {
        try validateArtifactPrefix(requested)
        return requested
    }
    let unique = UUID().uuidString.prefix(8).lowercased()
    let prefix = "screenshot-\(mode)-\(unique)"
    try validateArtifactPrefix(prefix)
    return prefix
}

public func screenshotSeriesArtifactName(
    prefix: String,
    mode: String,
    index: Int,
    count: Int,
    point: ScreenshotSeriesPoint,
    format: ScreenshotFormat = .png
) throws -> String {
    let width = max(3, String(count).count)
    let ordinal = String(format: "%0\(width)d", index)
    let name: String
    if mode == "section" {
        name = "\(prefix)-\(ordinal)-\(screenshotSeriesSlug(point.label, fallback: point.kind)).\(format.fileExtension)"
    } else {
        name = "\(prefix)-\(ordinal).\(format.fileExtension)"
    }
    try validateArtifactName(name, expectedExtensions: format.artifactExtensions)
    return name
}

public func screenshotSeriesSummary(
    mode: String,
    points: [ScreenshotSeriesPoint],
    artifacts: [JSONValue]
) -> JSONValue {
    let positions = points.enumerated().map { index, point in
        JSONValue.object([
            "index": .number(Double(index + 1)),
            "y": .number(point.y),
            "label": .string(point.label),
            "kind": .string(point.kind),
        ])
    }
    return .object([
        "series": .string(mode),
        "count": .number(Double(artifacts.count)),
        "artifacts": .array(artifacts),
        "positions": .array(positions),
    ])
}

private func screenshotSeriesSlug(_ value: String, fallback: String) -> String {
    let source = value.isEmpty ? fallback : value
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
    var output = ""
    var previousDash = false
    for scalar in source.lowercased().unicodeScalars {
        if allowed.contains(scalar) {
            output.unicodeScalars.append(scalar)
            previousDash = false
        } else if !previousDash {
            output.append("-")
            previousDash = true
        }
        if output.count >= 32 { break }
    }
    let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "section" : trimmed
}
