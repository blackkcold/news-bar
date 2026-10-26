// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NewsBar",
    platforms: [.macOS("15.0")],
    dependencies: [],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .executableTarget(
            name: "NewsBar",
            dependencies: ["CSQLite"],
            path: "Sources/NewsBar",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "NewsBarTests",
            dependencies: ["NewsBar"],
            path: "Tests/NewsBarTests"
        ),
    ]
)
