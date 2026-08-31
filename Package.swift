// swift-tools-version: 6.2
import PackageDescription
import Foundation

let appIntentsProtocols = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Scripts/app-intents-protocols.json")
    .path

let package = Package(
    name: "Koe",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Koe", targets: ["Koe"]),
        .executable(name: "koe-cli", targets: ["KoeCLI"]),
        .executable(name: "koe-mcp", targets: ["KoeMCP"]),
        .library(name: "KoeKit", targets: ["KoeKit"]),
    ],
    // 音声認識と既定の整形はOS内蔵モデルを使う。クラウド／ローカルLLMはURLSessionで接続する。
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0"),
    ],
    targets: [
        .target(
            name: "KoeKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "Koe",
            dependencies: ["KoeKit"],
            swiftSettings: [.unsafeFlags([
                "-emit-const-values",
                "-Xfrontend", "-const-gather-protocols-file",
                "-Xfrontend", appIntentsProtocols,
            ])]
        ),
        .executableTarget(name: "KoeCLI", dependencies: ["KoeKit"]),
        .executableTarget(name: "KoeMCP", dependencies: ["KoeKit"]),
        .testTarget(
            name: "KoeKitTests",
            dependencies: ["KoeKit"]
        ),
    ]
)
