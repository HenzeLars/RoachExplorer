// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RoachExplorer",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "RoachExplorer",
            path: "Sources/RoachExplorer"
        ),
        .testTarget(
            name: "RoachExplorerTests",
            dependencies: ["RoachExplorer"],
            path: "Tests/RoachExplorerTests"
        ),
    ]
)
