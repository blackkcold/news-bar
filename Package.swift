// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NewsBar",
    platforms: [.macOS("15.0")],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "NewsBar",
            dependencies: [],
            path: "Sources/NewsBar"
        ),
        .testTarget(
            name: "NewsBarTests",
            dependencies: ["NewsBar"],
            path: "Tests/NewsBarTests"
        ),
    ]
)
