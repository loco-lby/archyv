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
        // Scale Foundation 01: a `swift run`-able (not `swift test`-able)
        // synthetic-archive benchmark harness — see its own doc comment.
        // A plain executable deliberately, not another XCTest target:
        // RepositoryTests already established that XCTest bundles crash
        // under this machine's command-line toolchain for unrelated,
        // pre-existing reasons (see README) — a `swift run` executable
        // never launches an xctest bundle at all, sidestepping that
        // entirely while still using the same real SwiftData-capable
        // toolchain.
        .executableTarget(
            name: "ArkyvBench",
            dependencies: ["ArkyvKit"]
        ),
    ]
)
