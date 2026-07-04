// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FreeFlow",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "FreeFlow",
            path: "Sources/FreeFlow",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
