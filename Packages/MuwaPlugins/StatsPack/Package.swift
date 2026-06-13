// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MuwaStatsPack",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MuwaStatsPack", targets: ["MuwaStatsPack"])
    ],
    dependencies: [
        .package(path: "../../MuwaCore")
    ],
    targets: [
        .target(
            name: "MuwaStatsPack",
            dependencies: [
                .product(name: "MuwaCore", package: "MuwaCore")
            ],
            path: "Sources/MuwaStatsPack"
        ),
        .testTarget(
            name: "MuwaStatsPackTests",
            dependencies: ["MuwaStatsPack"],
            path: "Tests/MuwaStatsPackTests"
        ),
    ]
)
