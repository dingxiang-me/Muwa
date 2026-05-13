// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OsaurusAppCLI",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "osaurus-cli", targets: ["OsaurusAppCLI"]),
        .library(name: "OsaurusAppCLICore", targets: ["OsaurusAppCLICore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(path: "../OsaurusRepository"),
    ],
    targets: [
        .executableTarget(
            name: "OsaurusAppCLI",
            dependencies: [
                "OsaurusAppCLICore"
            ]
        ),
        .target(
            name: "OsaurusAppCLICore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "OsaurusRepository", package: "OsaurusRepository"),
            ]
        ),
        .testTarget(
            name: "OsaurusAppCLITests",
            dependencies: ["OsaurusAppCLICore"]
        ),
    ]
)
