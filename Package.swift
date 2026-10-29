// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "EdgeDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EdgeDeck",
            dependencies: ["EdgeTouch", "EdgeDisplay", "EdgeSensors", "EdgeMarkets", "EdgeAgents", "EdgeLink"],
            path: "Sources/EdgeDeck",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ApplicationServices"), .linkedLibrary("sqlite3")]
        ),
        // The Edge's touch reports and the gesture state machine (pure, unit-tested). Came from Edgetap.
        .target(name: "EdgeTouch", path: "Sources/EdgeTouch"),
        .testTarget(name: "EdgeTouchTests", dependencies: ["EdgeTouch"], path: "Tests/EdgeTouchTests"),
        // Which display mode is the Edge's Native mode, and how often to try to restore it (pure, unit-tested).
        .target(name: "EdgeDisplay", path: "Sources/EdgeDisplay"),
        .testTarget(name: "EdgeDisplayTests", dependencies: ["EdgeDisplay"], path: "Tests/EdgeDisplayTests"),
        // Temperature units, heat levels and fan readings (pure, unit-tested).
        .target(name: "EdgeSensors", path: "Sources/EdgeSensors"),
        .testTarget(name: "EdgeSensorsTests", dependencies: ["EdgeSensors"], path: "Tests/EdgeSensorsTests"),
        // Alerts, Currency pairs, Quotes and Yahoo Finance parsing (pure, unit-tested).
        .target(name: "EdgeMarkets", path: "Sources/EdgeMarkets"),
        .testTarget(name: "EdgeMarketsTests", dependencies: ["EdgeMarkets"], path: "Tests/EdgeMarketsTests"),
        // Quota and event parsing for the Codex and Antigravity agents (pure, unit-tested).
        .target(name: "EdgeAgents", path: "Sources/EdgeAgents"),
        .testTarget(name: "EdgeAgentsTests", dependencies: ["EdgeAgents"], path: "Tests/EdgeAgentsTests"),
        // Why a connection to another Mac failed, in words for the Edge (pure, unit-tested).
        .target(name: "EdgeLink", path: "Sources/EdgeLink"),
        .testTarget(name: "EdgeLinkTests", dependencies: ["EdgeLink"], path: "Tests/EdgeLinkTests"),
        // Hardware exploration: dumps the touch controller's HID descriptors and raw reports.
        .executableTarget(name: "touch-probe", path: "Sources/touch-probe"),
    ]
)
