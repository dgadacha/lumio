// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lumio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Lumio", path: "Sources/Lumio")
    ]
)
