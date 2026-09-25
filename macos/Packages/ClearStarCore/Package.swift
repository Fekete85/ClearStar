// swift-tools-version: 6.0
import PackageDescription

// UI-független feldolgozó mag – a windows/src/ClearStar.Core Swift megfelelője.
let package = Package(
    name: "ClearStarCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClearStarCore", targets: ["ClearStarCore"]),
    ],
    targets: [
        .target(name: "ClearStarCore"),
        .testTarget(name: "ClearStarCoreTests", dependencies: ["ClearStarCore"]),
    ]
)
