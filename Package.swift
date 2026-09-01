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
    // 通常音声入力はOS内蔵認識を使い、Life Logでは選択時だけローカルwhisper.cppを使う。
    // クラウド／ローカルLLMはURLSessionで接続する。
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0"),
    ],
    targets: [
        .target(
            name: "KoeKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "WhisperFramework",
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
            ])],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath",
                "-Xlinker", "@executable_path/../Frameworks",
            ])]
        ),
        .executableTarget(
            name: "KoeCLI",
            dependencies: ["KoeKit"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath",
                "-Xlinker", "@executable_path/../Frameworks",
            ])]
        ),
        .executableTarget(
            name: "KoeMCP",
            dependencies: ["KoeKit"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath",
                "-Xlinker", "@executable_path/../Frameworks",
            ])]
        ),
        .testTarget(
            name: "KoeKitTests",
            dependencies: ["KoeKit"]
        ),
        .binaryTarget(
            name: "WhisperFramework",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b4938/whisper-b4938-xcframework.zip",
            checksum: "dcc6cdc6d6902d11893434ceda70c23a2a64450f65a1b570035c9908988dfedd"
        ),
    ]
)
