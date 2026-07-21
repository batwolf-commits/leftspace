// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StorageCleaner",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "StorageCleanerKit", targets: ["StorageCleanerKit"]),
        .executable(name: "storagecleaner", targets: ["storagecleaner-cli"]),
        .executable(name: "StorageCleanerApp", targets: ["StorageCleanerApp"]),
    ],
    targets: [
        .target(
            name: "StorageCleanerKit"
        ),
        .executableTarget(
            name: "storagecleaner-cli",
            dependencies: ["StorageCleanerKit"]
        ),
        .executableTarget(
            name: "StorageCleanerApp",
            dependencies: ["StorageCleanerKit"]
        ),
        .testTarget(
            name: "StorageCleanerKitTests",
            dependencies: ["StorageCleanerKit"]
        ),
    ]
)
