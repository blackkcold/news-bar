// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NewsBar",
    platforms: [.macOS("15.0")],
    dependencies: [
        // Sparkle 2 drives in-place updates: appcast discovery, EdDSA
        // verification, delta application and the standard update UI.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(
            name: "NewsBarAgentProtocol",
            path: "Sources/NewsBarAgentProtocol"
        ),
        .executableTarget(
            name: "NewsBar",
            dependencies: ["CSQLite", "NewsBarAgentProtocol", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/NewsBar",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "WeiboLabelCLI",
            path: "Sources/WeiboLabelCLI"
        ),
        .executableTarget(
            name: "newsbarctl",
            dependencies: ["NewsBarAgentProtocol"],
            path: "Sources/newsbarctl"
        ),
        .testTarget(
            name: "NewsBarTests",
            dependencies: ["NewsBar", "NewsBarAgentProtocol"],
            path: "Tests/NewsBarTests",
            // Tests read these from #filePath; excluding them from the bundle
            // keeps the build free of "unhandled resource" warnings.
            exclude: ["Fixtures"]
        ),
    ]
)
