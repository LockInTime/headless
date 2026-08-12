// swift-tools-version: 5.10

import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let fallbackProductVersion = try String(
    contentsOf: packageDirectory.appendingPathComponent("VERSION"), encoding: .utf8
).trimmingCharacters(in: .whitespacesAndNewlines)
let productVersion = ProcessInfo.processInfo.environment["HEADLESS_VERSION"] ?? fallbackProductVersion
let semanticVersionPattern = #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#
guard productVersion.range(of: semanticVersionPattern, options: .regularExpression) != nil else {
    fatalError("HEADLESS_VERSION must be a semantic version, received: \(productVersion)")
}

let package = Package(
    name: "Headless",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "headless", targets: ["HeadlessCLI"]),
        .executable(name: "headless-host", targets: ["HeadlessHost"]),
        .executable(name: "headless-linux-host", targets: ["HeadlessLinuxHost"]),
        .executable(name: "headless-mcp", targets: ["HeadlessMCP"]),
        .executable(name: "headless-mcp-tests", targets: ["HeadlessMCPTests"]),
        .executable(name: "headless-protocol-tests", targets: ["HeadlessProtocolTests"]),
        .library(name: "HeadlessProtocol", targets: ["HeadlessProtocol"]),
    ],
    targets: [
        .target(
            name: "CHeadlessVersion",
            path: "VersionSupport",
            publicHeadersPath: "include",
            cSettings: [.define("HEADLESS_PRODUCT_VERSION", to: "\"\(productVersion)\"")]
        ),
        .target(
            name: "HeadlessProtocol",
            dependencies: ["CHeadlessVersion"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "HeadlessCLI",
            dependencies: ["HeadlessProtocol"]
        ),
        .executableTarget(
            name: "HeadlessLinuxHost",
            dependencies: ["HeadlessProtocol"],
            path: "LinuxHost"
        ),
        .executableTarget(
            name: "HeadlessMCP",
            dependencies: ["HeadlessProtocol"],
            path: "MCP"
        ),
        .executableTarget(
            name: "HeadlessHost",
            dependencies: ["HeadlessProtocol"],
            path: ".",
            exclude: [
                "Package.swift", "Sources", "Tests", "tools", "VersionSupport", "VERSION", "build.sh",
                "package.json", "headless.entitlements", "build", "docs", "test.sh",
                "LinuxHost", "Dockerfile.linux", "Headless.app", "build-linux.sh", "install-linux.sh", "benchmark.sh", ".dockerignore",
                "MCP", "node_modules",
            ],
            sources: ["main.swift", "Host/AgentBridge.swift", "Host/QADiagnosticsBridge.swift"],
            linkerSettings: [
                .linkedFramework("Cocoa", .when(platforms: [.macOS])),
                .linkedFramework("WebKit", .when(platforms: [.macOS])),
                .linkedFramework("Security", .when(platforms: [.macOS])),
            ]
        ),
        .executableTarget(
            name: "HeadlessProtocolTests",
            dependencies: ["HeadlessProtocol"],
            path: "Tests/HeadlessProtocolTests"
        ),
        .executableTarget(
            name: "HeadlessMCPTests",
            dependencies: ["HeadlessProtocol"],
            path: "Tests/HeadlessMCPTests"
        ),
    ]
)
