// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "notetaked",
    platforms: [.macOS("26.0"), .iOS("26.0"), .watchOS("26.0")],
    products: [
        .library(name: "NotetakeCore", targets: ["NotetakeCore"]),
        .executable(name: "notetaked", targets: ["notetaked"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "NotetakeCore"),
        .executableTarget(
            name: "notetaked",
            dependencies: [
                "NotetakeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            exclude: ["Info.plist"]
        ),
        .testTarget(name: "NotetakeCoreTests", dependencies: ["NotetakeCore"]),
    ]
)
