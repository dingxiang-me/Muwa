// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MuwaCLI",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "muwa-cli", targets: ["MuwaCLI"]),
        .library(name: "MuwaCLICore", targets: ["MuwaCLICore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(path: "../MuwaRepository"),
    ],
    targets: [
        .executableTarget(
            name: "MuwaCLI",
            dependencies: [
                "MuwaCLICore"
            ]
        ),
        .target(
            name: "MuwaCLICore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "MuwaRepository", package: "MuwaRepository"),
            ]
        ),
        .testTarget(
            name: "MuwaCLITests",
            dependencies: ["MuwaCLICore"]
        ),
    ]
)
