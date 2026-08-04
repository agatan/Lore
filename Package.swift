// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Koe",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Koe", targets: ["Koe"]),
        .library(name: "KoeKit", targets: ["KoeKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.14.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples.git", from: "2.25.0"),
    ],
    targets: [
        .target(
            name: "KoeKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
            ]
        ),
        .executableTarget(
            name: "Koe",
            dependencies: ["KoeKit"]
        ),
        .testTarget(
            name: "KoeKitTests",
            dependencies: ["KoeKit"]
        ),
    ]
)
