// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "brightsync",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "CPrivateAPIs"),
        .executableTarget(
            name: "brightsync",
            dependencies: [
                "CPrivateAPIs",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
    ]
)
