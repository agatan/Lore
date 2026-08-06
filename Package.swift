// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Koe",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Koe", targets: ["Koe"]),
        .library(name: "KoeKit", targets: ["KoeKit"]),
    ],
    // 推論は OS 内蔵のモデルだけを使う(設計 D-1 / C-52 / C-74)。
    // 追加のモデルを持たないので、依存はデータベースだけになる。
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
