// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UniversalControllerShared",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "UniversalControllerShared",
            targets: ["UniversalControllerShared"]
        ),
    ],
    targets: [
        .target(
            name: "UniversalControllerShared",
            path: "Shared"
        ),
        .testTarget(
            name: "UniversalControllerSharedTests",
            dependencies: ["UniversalControllerShared"],
            path: "Tests/UniversalControllerSharedTests"
        ),
    ]
)
