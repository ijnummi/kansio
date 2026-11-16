// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileSystemKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FileSystemKit", targets: ["FileSystemKit"]),
    ],
    targets: [
        .target(
            name: "FileSystemKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FileSystemKitTests",
            dependencies: ["FileSystemKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
