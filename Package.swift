// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MountKeep",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MountKeepCore", targets: ["MountKeepCore"]),
        .executable(name: "MountKeep", targets: ["MountKeep"])
    ],
    targets: [
        .target(
            name: "MountKeepCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("NetFS"),
                .linkedFramework("Network"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "MountKeep",
            dependencies: ["MountKeepCore"]
        ),
        .testTarget(
            name: "MountKeepTests",
            dependencies: ["MountKeepCore"]
        )
    ]
)
