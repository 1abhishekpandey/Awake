// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Awake",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Awake",
            path: "Sources/Awake"
        ),
        .testTarget(
            name: "AwakeTests",
            dependencies: ["Awake"],
            path: "Tests/AwakeTests"
        ),
    ]
)
