// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "EdgeDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EdgeDeck",
            dependencies: ["EdgeTouch"],
            path: "Sources/EdgeDeck",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ApplicationServices"), .linkedLibrary("sqlite3")]
        ),
        // The Edge's touch reports and the gesture state machine (pure, unit-tested). Came from Edgetap.
        .target(name: "EdgeTouch", path: "Sources/EdgeTouch"),
        .testTarget(name: "EdgeTouchTests", dependencies: ["EdgeTouch"], path: "Tests/EdgeTouchTests"),
        // Hardware exploration: dumps the touch controller's HID descriptors and raw reports.
        .executableTarget(name: "touch-probe", path: "Sources/touch-probe"),
    ]
)
