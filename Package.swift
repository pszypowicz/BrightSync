// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BrightSync",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "CPrivateAPIs"),
        .executableTarget(
            name: "BrightSync",
            dependencies: [
                "CPrivateAPIs",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOKit")],
            plugins: [.plugin(name: "BuildMetadata")]
        ),
        .plugin(
            name: "BuildMetadata",
            capability: .buildTool()
        ),
    ]
)
