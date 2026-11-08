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
        .executableTarget(
            name: "WeiboLabelCLI",
            path: "Sources/WeiboLabelCLI"
        ),
        .testTarget(
            name: "NewsBarTests",
            dependencies: ["NewsBar"],
            path: "Tests/NewsBarTests",
            // Tests read these from #filePath; excluding them from the bundle
            // keeps the build free of "unhandled resource" warnings.
            exclude: ["Fixtures"]
        ),
    ]
)
