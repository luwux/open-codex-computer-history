// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "OpenCodexComputerHistory",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "open-history", targets: ["OpenHistory"]),
        .executable(name: "open-history-menu", targets: ["OpenHistoryMenu"]),
        .executable(name: "open-history-fixture", targets: ["OpenHistoryFixture"]),
        .executable(
            name: "open-history-fixture-driver",
            targets: ["OpenHistoryFixtureDriver"]
        ),
        .library(name: "HistoryCore", targets: ["HistoryCore"]),
    ],
    targets: [
        .target(name: "HistoryCore"),
        .executableTarget(
            name: "OpenHistory",
            dependencies: ["HistoryCore"]
        ),
        .executableTarget(
            name: "OpenHistoryMenu",
            dependencies: ["HistoryCore"]
        ),
        .executableTarget(name: "OpenHistoryFixture"),
        .executableTarget(name: "OpenHistoryFixtureDriver"),
        .testTarget(
            name: "HistoryCoreTests",
            dependencies: ["HistoryCore"]
        ),
    ]
)
