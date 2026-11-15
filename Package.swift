// swift-tools-version: 6.2
import PackageDescription
import Foundation

let appIntentsProtocols = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Scripts/app-intents-protocols.json")
    .path

let package = Package(
    name: "Lore",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Lore", targets: ["Lore"]),
        .executable(name: "lore-cli", targets: ["LoreCLI"]),
        .executable(name: "lore-mcp", targets: ["LoreMCP"]),
        .library(name: "LoreKit", targets: ["LoreKit"]),
    ],
    // 音声認識はOS内蔵のSpeechAnalyzerか、選択時だけローカルのwhisper.cppを使う。
    // クラウド／ローカルLLMはURLSessionで接続する。
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0"),
    ],
    targets: [
        .target(
            name: "LoreKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "WhisperFramework",
            ],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "Lore",
            dependencies: ["LoreKit"],
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
            name: "LoreCLI",
            dependencies: ["LoreKit"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath",
                "-Xlinker", "@executable_path/../Frameworks",
            ])]
        ),
        .executableTarget(
            name: "LoreMCP",
            dependencies: ["LoreKit"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath",
                "-Xlinker", "@executable_path/../Frameworks",
            ])]
        ),
        .testTarget(
            name: "LoreKitTests",
            dependencies: ["LoreKit"]
        ),
        .binaryTarget(
            name: "WhisperFramework",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b4938/whisper-b4938-xcframework.zip",
            checksum: "dcc6cdc6d6902d11893434ceda70c23a2a64450f65a1b570035c9908988dfedd"
        ),
    ]
)
