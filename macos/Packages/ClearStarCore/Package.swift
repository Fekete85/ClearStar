// swift-tools-version: 6.2
import PackageDescription

// UI-independent processing core – the Swift counterpart of windows/src/ClearStar.Core.
let package = Package(
    name: "ClearStarCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ClearStarCore", targets: ["ClearStarCore"]),
    ],
    targets: [
        .target(
            name: "ClearStarCore",
            // Image processing is unusably slow unoptimised; the tests (Debug) run optimised code too.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))],
            linkerSettings: [.linkedLibrary("bz2")]
        ),
        .testTarget(name: "ClearStarCoreTests", dependencies: ["ClearStarCore"]),
    ]
)
