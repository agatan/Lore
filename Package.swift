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
    // 通常音声入力はOS内蔵認識を使い、Life Logでは選択時だけローカルWhisperKitを使う。
    // クラウド／ローカルLLMはURLSessionで接続する。
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "KoeKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
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
