// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Chromeless",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "chromeless", targets: ["ChromelessCLI"]),
        .executable(name: "chromeless-host", targets: ["ChromelessHost"]),
        .executable(name: "chromeless-linux-host", targets: ["ChromelessLinuxHost"]),
        .executable(name: "chromeless-mcp", targets: ["ChromelessMCP"]),
        .executable(name: "chromeless-protocol-tests", targets: ["ChromelessProtocolTests"]),
        .library(name: "ChromelessProtocol", targets: ["ChromelessProtocol"]),
    ],
    targets: [
        .target(name: "ChromelessProtocol"),
        .executableTarget(
            name: "ChromelessCLI",
            dependencies: ["ChromelessProtocol"]
        ),
        .executableTarget(
            name: "ChromelessLinuxHost",
            dependencies: ["ChromelessProtocol"],
            path: "LinuxHost"
        ),
        .executableTarget(
            name: "ChromelessMCP",
            dependencies: ["ChromelessProtocol"],
            path: "MCP"
        ),
        .executableTarget(
            name: "ChromelessHost",
            dependencies: ["ChromelessProtocol"],
            path: ".",
            exclude: [
                "Package.swift", "Sources", "Tests", "tools", "build.sh",
                "package.json", "chromeless.entitlements", "build", "docs", "test.sh",
                "LinuxHost", "Dockerfile.linux", "Chromeless.app", "build-linux.sh", "install-linux.sh", "benchmark.sh", ".dockerignore",
                "MCP",
            ],
            sources: ["main.swift", "Host/AgentBridge.swift", "Host/QADiagnosticsBridge.swift"],
            linkerSettings: [
                .linkedFramework("Cocoa", .when(platforms: [.macOS])),
                .linkedFramework("WebKit", .when(platforms: [.macOS])),
                .linkedFramework("Security", .when(platforms: [.macOS])),
            ]
        ),
        .executableTarget(
            name: "ChromelessProtocolTests",
            dependencies: ["ChromelessProtocol"],
            path: "Tests/ChromelessProtocolTests"
        ),
    ]
)
