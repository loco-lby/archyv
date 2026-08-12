// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ArkyvKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ArkyvKit", targets: ["ArkyvKit"]),
    ],
    targets: [
        .target(
            name: "ArkyvKit"
        ),
        .testTarget(
            name: "ArkyvKitTests",
            dependencies: ["ArkyvKit"]
        ),
    ]
)
