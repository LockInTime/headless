// swift-tools-version: 5.10

import PackageDescription

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
        .target(name: "HeadlessProtocol"),
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
                "Package.swift", "Sources", "Tests", "tools", "build.sh",
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
