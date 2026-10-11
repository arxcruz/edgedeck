// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "EdgeDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EdgeDeck",
            path: "Sources/EdgeDeck",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ApplicationServices"), .linkedLibrary("sqlite3")]
        )
    ]
)
