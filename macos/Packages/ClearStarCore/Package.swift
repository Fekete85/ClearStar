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
        // The system's libbz2 (the offline star catalogue is published as .bz2).
        .systemLibrary(name: "CBZip2", path: "Sources/CBZip2"),
        .target(
            name: "ClearStarCore",
            dependencies: ["CBZip2"],
            // Image processing is unusably slow unoptimised; the tests (Debug) run optimised code too.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .testTarget(name: "ClearStarCoreTests", dependencies: ["ClearStarCore"], exclude: ["Fixtures"]),
    ]
)
