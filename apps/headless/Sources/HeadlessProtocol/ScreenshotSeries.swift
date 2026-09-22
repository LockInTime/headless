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
    public let sliceTop: Double?
    public let sliceHeight: Double?

    public init(
        y: Double, label: String, kind: String,
        sliceTop: Double? = nil, sliceHeight: Double? = nil
    ) {
        self.y = y
        self.label = label
        self.kind = kind
        self.sliceTop = sliceTop
        self.sliceHeight = sliceHeight
    }
}

public struct ScreenshotRegionGeometry: Equatable, Sendable {
    public static let maximumDocumentExtent = 100_000_000.0
    public static let maximumCaptureWidth = 4_096.0

    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(_ object: [String: JSONValue]) throws {
        guard let x = object["x"]?.numberValue, let y = object["y"]?.numberValue,
              let width = object["width"]?.numberValue,
              let height = object["height"]?.numberValue,
              x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              x >= 0, y >= 0, width > 0, height > 0,
              x <= Self.maximumDocumentExtent, y <= Self.maximumDocumentExtent,
              width <= Self.maximumCaptureWidth,
              height <= Self.maximumDocumentExtent else {
            throw ScreenshotSeriesError.invalidPlan
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var parameters: [String: JSONValue] {
        [
            "x": .number(x), "y": .number(y),
            "width": .number(width), "height": .number(height),
        ]
    }
}

public struct ScreenshotSeriesPlan: Equatable, Sendable {
    public let document: String
    public let initialY: Double
    public let points: [ScreenshotSeriesPoint]
    public let truncated: Bool
    public let totalPoints: Int
    public let region: ScreenshotRegionGeometry?

    public init(
        document: String, initialY: Double, points: [ScreenshotSeriesPoint], truncated: Bool,
        totalPoints: Int, region: ScreenshotRegionGeometry? = nil
    ) {
        self.document = document
        self.initialY = initialY
        self.points = points
        self.truncated = truncated
        self.totalPoints = totalPoints
        self.region = region
    }
}

public func parseScreenshotSeriesPlan(
    _ plan: JSONValue, regionReference: String? = nil
) throws -> ScreenshotSeriesPlan {
    guard case .object(let object) = plan,
          case .array(let values)? = object["points"] else {
        throw ScreenshotSeriesError.invalidPlan
    }
    guard let document = object["document"]?.stringValue,
          document.count == 32,
          document.allSatisfy({ $0.isHexDigit }) else {
        throw ScreenshotSeriesError.invalidPlan
    }
    let initialY = object["initialY"]?.numberValue ?? 0
    guard initialY.isFinite, initialY >= 0 else { throw ScreenshotSeriesError.invalidPlan }
    let region: ScreenshotRegionGeometry?
    if case .object(let rawRegion)? = object["region"] {
        region = try ScreenshotRegionGeometry(rawRegion)
    } else {
        region = nil
    }
    guard (regionReference != nil) == (region != nil) else {
        throw ScreenshotSeriesError.invalidPlan
    }
    guard values.count <= 80 else { throw ScreenshotSeriesError.invalidPlan }
    let points = try values.map { value -> ScreenshotSeriesPoint in
        guard case .object(let item) = value,
              let y = item["y"]?.numberValue, y.isFinite else {
            throw ScreenshotSeriesError.invalidPlan
        }
        let sliceTop = item["sliceTop"]?.numberValue
        let sliceHeight = item["sliceHeight"]?.numberValue
        guard (sliceTop == nil) == (sliceHeight == nil) else {
            throw ScreenshotSeriesError.invalidPlan
        }
        if let region, let sliceTop, let sliceHeight {
            guard sliceTop.isFinite, sliceHeight.isFinite,
                  sliceTop >= region.y, sliceHeight > 0,
                  sliceTop + sliceHeight <= region.y + region.height + 0.5 else {
                throw ScreenshotSeriesError.invalidPlan
            }
            _ = try BoundedScreenshotRectangle([
                "x": .number(region.x), "y": .number(sliceTop),
                "width": .number(region.width), "height": .number(sliceHeight),
            ])
        } else if region != nil || sliceTop != nil {
            throw ScreenshotSeriesError.invalidPlan
        }
        return ScreenshotSeriesPoint(
            y: y,
            label: String((item["label"]?.stringValue ?? "viewport").prefix(80)),
            kind: String((item["kind"]?.stringValue ?? "viewport").prefix(32)),
            sliceTop: sliceTop, sliceHeight: sliceHeight
        )
    }
    guard !points.isEmpty else { throw ScreenshotSeriesError.emptyPlan }
    guard let truncated = object["truncated"]?.boolValue,
          let totalPointsValue = object["totalPoints"]?.numberValue else {
        throw ScreenshotSeriesError.invalidPlan
    }
    guard totalPointsValue.isFinite, totalPointsValue.rounded(.towardZero) == totalPointsValue,
          totalPointsValue >= Double(points.count), totalPointsValue <= 100_000_000 else {
        throw ScreenshotSeriesError.invalidPlan
    }
    guard truncated == (totalPointsValue > Double(points.count)) else {
        throw ScreenshotSeriesError.invalidPlan
    }
    if let region {
        try validateRegionTiling(
            points: points, region: region,
            truncated: truncated, totalPoints: Int(totalPointsValue)
        )
    }
    return ScreenshotSeriesPlan(
        document: document, initialY: initialY,
        points: points,
        truncated: truncated,
        totalPoints: Int(totalPointsValue),
        region: region
    )
}

private func validateRegionTiling(
    points: [ScreenshotSeriesPoint], region: ScreenshotRegionGeometry,
    truncated: Bool, totalPoints: Int
) throws {
    let tolerance = 0.5
    guard let firstHeight = points.first?.sliceHeight,
          let firstTop = points.first?.sliceTop,
          abs(firstTop - region.y) <= tolerance,
          firstHeight > 0 else {
        throw ScreenshotSeriesError.invalidPlan
    }
    let leadingCount = max(0, points.count - 1)
    guard !truncated || (points.count == 80 && totalPoints > points.count) else {
        throw ScreenshotSeriesError.invalidPlan
    }
    for index in 0..<leadingCount {
        guard let top = points[index].sliceTop,
              let height = points[index].sliceHeight,
              abs(height - firstHeight) <= tolerance else {
            throw ScreenshotSeriesError.invalidPlan
        }
        if index == 0 {
            guard abs(top - region.y) <= tolerance else {
                throw ScreenshotSeriesError.invalidPlan
            }
        } else if let previousTop = points[index - 1].sliceTop,
                  let previousHeight = points[index - 1].sliceHeight {
            guard abs(top - (previousTop + previousHeight)) <= tolerance else {
                throw ScreenshotSeriesError.invalidPlan
            }
        } else {
            throw ScreenshotSeriesError.invalidPlan
        }
    }
    guard let lastTop = points.last?.sliceTop,
          let lastHeight = points.last?.sliceHeight,
          abs(lastTop + lastHeight - (region.y + region.height)) <= tolerance,
          lastHeight <= firstHeight + tolerance else {
        throw ScreenshotSeriesError.invalidPlan
    }
    let expectedTotal = Int(ceil(region.height / firstHeight))
    guard totalPoints == expectedTotal else { throw ScreenshotSeriesError.invalidPlan }
    if truncated {
        guard let previousTop = points[points.count - 2].sliceTop,
              let previousHeight = points[points.count - 2].sliceHeight,
              lastTop > previousTop + previousHeight else {
            throw ScreenshotSeriesError.invalidPlan
        }
    } else if points.count > 1,
              let previousTop = points[points.count - 2].sliceTop,
              let previousHeight = points[points.count - 2].sliceHeight {
        guard abs(lastTop - (previousTop + previousHeight)) <= tolerance else {
            throw ScreenshotSeriesError.invalidPlan
        }
    }
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
    artifacts: [JSONValue],
    truncated: Bool = false,
    totalPoints: Int? = nil
) -> JSONValue {
    let positions = points.enumerated().map { index, point in
        var position: [String: JSONValue] = [
            "index": .number(Double(index + 1)), "kind": .string(point.kind),
        ]
        if mode != "region" {
            position["y"] = .number(point.y)
            position["label"] = .string(point.label)
        }
        return JSONValue.object(position)
    }
    return .object([
        "series": .string(mode),
        "count": .number(Double(artifacts.count)),
        "artifacts": .array(artifacts),
        "positions": .array(positions),
        "truncated": .bool(truncated),
        "totalPoints": .number(Double(totalPoints ?? points.count)),
        "untrustedContent": .bool(mode == "section" || mode == "region"),
    ])
}

public func reserveScreenshotSeriesArtifacts(
    store: ArtifactStore,
    points: [ScreenshotSeriesPoint],
    prefix: String,
    mode: String,
    format: ScreenshotFormat
) throws -> [URL] {
    var reserved: [URL] = []
    do {
        for (index, point) in points.enumerated() {
            let name = try screenshotSeriesArtifactName(
                prefix: prefix, mode: mode, index: index + 1, count: points.count,
                point: point, format: format
            )
            reserved.append(try store.reserve(
                requestedName: name, extension: format.fileExtension, prefix: prefix
            ))
        }
        return reserved
    } catch {
        store.discardReserved(reserved)
        throw error
    }
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
