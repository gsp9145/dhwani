// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Dhwani",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Dhwani",
            path: "Sources/Dhwani",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
