// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Koe",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Koe", targets: ["Koe"]),
        .library(name: "KoeKit", targets: ["KoeKit"]),
    ],
    // 音声認識と既定の整形は OS 内蔵モデルを使い、外部依存はデータベースだけになる。
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0"),
    ],
    targets: [
        .target(
            name: "KoeKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
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
