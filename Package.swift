// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "AgentBrowserCompanion",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentBrowserCompanion", targets: ["AgentBrowserCompanion"])
    ],
    targets: [
        .executableTarget(
            name: "AgentBrowserCompanion",
            path: "Sources/AgentBrowserCompanion"
        ),
        .testTarget(
            name: "AgentBrowserCompanionTests",
            dependencies: ["AgentBrowserCompanion"],
            path: "Tests/AgentBrowserCompanionTests"
        )
    ]
)
