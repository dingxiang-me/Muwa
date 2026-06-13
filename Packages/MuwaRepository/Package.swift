// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MuwaRepository",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MuwaRepository", targets: ["MuwaRepository"])
    ],
    targets: [
        .target(
            name: "MuwaRepository",
            path: ".",
            exclude: ["Tests"]
        ),
        .testTarget(
            name: "MuwaRepositoryTests",
            dependencies: ["MuwaRepository"],
            path: "Tests/MuwaRepositoryTests"
        ),
    ]
)
