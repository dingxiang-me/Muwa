// swift-tools-version: 6.2
import PackageDescription

// Muwa Plugin Test Kit
//
// External-facing test kit for Muwa plugin authors. Provides a Swift
// mirror of the v4 `osr_host_api` C struct and helper recorders so a
// plugin's `Tests/` target can drive `muwa_plugin_entry_v2(host)`
// against a controllable mock host without depending on MuwaCore (or
// the Muwa app itself).
//
// Authors add this as a test-target dependency in their plugin's own
// `Package.swift`:
//
//     .package(url: "https://github.com/muwa-ai/muwa", from: "0.18.0"),
//
//     .testTarget(
//         name: "MyPluginTests",
//         dependencies: [
//             .product(name: "MuwaPluginTestKit", package: "muwa")
//         ]
//     )
//
// See the package README for the recipe.

let package = Package(
    name: "MuwaPluginTestKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MuwaPluginTestKit", targets: ["MuwaPluginTestKit"])
    ],
    targets: [
        .target(
            name: "MuwaPluginTestKit",
            path: "Sources/MuwaPluginTestKit"
        ),
        .testTarget(
            name: "MuwaPluginTestKitTests",
            dependencies: ["MuwaPluginTestKit"],
            path: "Tests/MuwaPluginTestKitTests"
        ),
    ]
)
