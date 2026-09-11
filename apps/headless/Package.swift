// swift-tools-version: 5.10

import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let fallbackProductVersion = try String(
    contentsOf: packageDirectory.appendingPathComponent("VERSION"), encoding: .utf8
).trimmingCharacters(in: .whitespacesAndNewlines)
let productVersion = ProcessInfo.processInfo.environment["HEADLESS_VERSION"] ?? fallbackProductVersion
let semanticVersionPattern = try String(
    contentsOf: packageDirectory.appendingPathComponent("VersionSupport/semver-pattern.txt"), encoding: .utf8
).trimmingCharacters(in: .whitespacesAndNewlines)
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
        .executable(name: "headless-credential-broker", targets: ["HeadlessCredentialBroker"]),
        .executable(name: "headless-mcp", targets: ["HeadlessMCP"]),
        .executable(name: "headless-mcp-tests", targets: ["HeadlessMCPTests"]),
        .executable(name: "headless-protocol-tests", targets: ["HeadlessProtocolTests"]),
        .library(name: "HeadlessProtocol", targets: ["HeadlessProtocol"]),
    ],
    targets: [
        .target(
            name: "CHeadlessVersion",
            path: "VersionSupport",
            exclude: ["semver-pattern.txt"],
            publicHeadersPath: "include",
            cSettings: [.define("HEADLESS_PRODUCT_VERSION", to: "\"\(productVersion)\"")]
        ),
        .target(
            name: "HeadlessProtocol",
            dependencies: ["CHeadlessSecurePrompt", "CHeadlessVersion"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "CHeadlessSecurePrompt",
            path: "SecurePrompt",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CredentialBrokerCore",
            dependencies: ["HeadlessProtocol", "CHeadlessSecurePrompt"],
            path: "CredentialBrokerCore",
            linkerSettings: [
                .linkedFramework("LocalAuthentication", .when(platforms: [.macOS])),
                .linkedFramework("Security", .when(platforms: [.macOS])),
            ]
        ),
        .executableTarget(
            name: "HeadlessCLI",
            dependencies: ["HeadlessProtocol"]
        ),
        .executableTarget(
            name: "HeadlessCredentialBroker",
            dependencies: ["CredentialBrokerCore", "HeadlessProtocol"],
            path: "CredentialBroker"
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
                "LinuxHost", "Dockerfile.linux", "Headless.app", "build-linux.sh", "install.sh", "install-linux.sh", "benchmark.sh", ".dockerignore",
                "MCP", "CredentialBroker", "CredentialBrokerCore", "SecurePrompt", "node_modules",
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
            dependencies: ["HeadlessProtocol", "CredentialBrokerCore"],
            path: "Tests/HeadlessProtocolTests"
        ),
        .executableTarget(
            name: "HeadlessMCPTests",
            dependencies: ["HeadlessProtocol"],
            path: "Tests/HeadlessMCPTests"
        ),
    ]
)
