// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KeyNav",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "KeyNav", targets: ["KeyNav"]),
        .executable(name: "KeyNavFixture", targets: ["KeyNavFixture"])
    ],
    dependencies: [
        // Updates: checks keynav.app's signed feed, then downloads, verifies and installs new versions.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        // Pure, deterministic logic: keys, gestures, routing, motion, labels, config.
        .target(name: "KeyNavCore"),
        // macOS integration: event tap, CoreGraphics output, Accessibility, overlays.
        .target(name: "KeyNavSystem", dependencies: ["KeyNavCore"]),
        // The application shell: lifecycle, menus, Settings window.
        .executableTarget(name: "KeyNav", dependencies: ["KeyNavCore", "KeyNavSystem", .product(name: "Sparkle", package: "Sparkle")]),
        // A controllable window for live tests. Never shipped inside KeyNav.app.
        .executableTarget(name: "KeyNavFixture"),
        .testTarget(name: "KeyNavCoreTests", dependencies: ["KeyNavCore"])
    ]
)
