// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "osaurus-cli",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Osaurus", targets: ["Osaurus"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.88.0"),
        .package(url: "https://github.com/orlandos-nl/IkigaJSON", from: "2.3.2"),
        // Pins match osaurus's Packages/OsaurusCore/Package.swift. Bump in
        // lockstep with osaurus when validating a new upstream commit.
        .package(
            url: "https://github.com/osaurus-ai/mlx-swift",
            revision: "0a56f9041d56b4b8161f67a6cbd540ae66efc9fd"
        ),
        .package(
            url: "https://github.com/osaurus-ai/vmlx-swift-lm",
            revision: "ad1d23199b056ed502124717e6ca8877f2fb303a"
        ),
        .package(
            url: "https://github.com/osaurus-ai/Jinja.git",
            revision: "58d21aa5b69fdd9eb7e23ce2c3730f47db8e0c9d"
        ),
        .package(
            url: "https://github.com/osaurus-ai/swift-transformers",
            revision: "087a66b17e482220b94909c5cf98688383ae481a"
        ),
    ],
    targets: [
        .target(
            name: "Osaurus",
            dependencies: [
                .product(name: "IkigaJSON", package: "IkigaJSON"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "vmlx-swift-lm"),
                .product(name: "MLXVLM", package: "vmlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "vmlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Jinja", package: "jinja"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources",
            resources: [.process("OsaurusEngine/Resources")]
        ),
        .testTarget(
            name: "OsaurusEngineTests",
            dependencies: [
                "Osaurus",
                .product(name: "MLXLMCommon", package: "vmlx-swift-lm"),
            ],
            path: "Tests/OsaurusEngineTests"
        ),
        .testTarget(
            name: "OsaurusServerKitTests",
            dependencies: [
                "Osaurus",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Tests/OsaurusServerKitTests"
        ),
    ]
)
