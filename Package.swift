// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DiskManager",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DiskManagerCore"),
        .executableTarget(
            name: "DiskManager",
            dependencies: ["DiskManagerCore"]
        ),
        .testTarget(
            name: "DiskManagerCoreTests",
            dependencies: ["DiskManagerCore"]
        ),
    ]
)
