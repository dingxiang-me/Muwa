// swift-tools-version: 6.2
//
// MuwaEvals
//
// Standalone package for catalog-driven behaviour / integration tests
// that hit a real model (Foundation, MLX, remote provider). NOT part of
// CI — `swift test` from `Packages/MuwaCore` does not touch this
// package, and the CLI is invoked manually for local tuning + new-model
// triage.
//
// See `README.md` for usage. The runner sets the core model via
// `ChatConfigurationStore` per-run, so `--model` only affects the eval
// process and never persists across runs (see `ModelOverride.swift`).
//
import PackageDescription

let package = Package(
    name: "MuwaEvals",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MuwaEvalsKit", targets: ["MuwaEvalsKit"]),
        .executable(name: "muwa-evals", targets: ["MuwaEvalsCLI"]),
    ],
    dependencies: [
        .package(path: "../MuwaCore")
    ],
    targets: [
        .target(
            name: "MuwaEvalsKit",
            dependencies: [
                .product(name: "MuwaCore", package: "MuwaCore")
            ],
            path: "Sources/MuwaEvalsKit"
        ),
        .executableTarget(
            name: "MuwaEvalsCLI",
            dependencies: [
                "MuwaEvalsKit"
            ],
            path: "Sources/MuwaEvalsCLI"
        ),
        .testTarget(
            name: "MuwaEvalsKitTests",
            dependencies: [
                "MuwaEvalsKit"
            ],
            path: "Tests/MuwaEvalsKitTests"
        ),
    ]
)
