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
    dependencies: [
        // Used from Phase 2 onward (Auth, Postgres, Storage, Realtime).
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.20.0"),
    ],
    targets: [
        .target(
            name: "ArkyvKit",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
        .testTarget(
            name: "ArkyvKitTests",
            dependencies: ["ArkyvKit"]
        ),
    ]
)
