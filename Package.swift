// swift-tools-version: 6.0
// Kansio is built with SwiftPM only (no Xcode project): `Tools/build-app.sh` wraps the
// `Kansio` executable into a signed .app bundle. See CLAUDE.md.
import PackageDescription

let package = Package(
    name: "Kansio",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "Packages/FileSystemKit"),
    ],
    targets: [
        .executableTarget(
            name: "Kansio",
            dependencies: [.product(name: "FileSystemKit", package: "FileSystemKit")],
            path: "App/Kansio",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "kansio-bench",
            dependencies: [.product(name: "FileSystemKit", package: "FileSystemKit")],
            path: "Tools/Bench",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
