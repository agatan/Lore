import FoundationModels
import Foundation

/// macOS 標準のオンデバイスモデルによる整形。ダウンロード不要で即使える構成の要(FR-9.3)。
public final class FoundationModelsLlm: LlmEngine {
    public let identifier = EngineIdentifier.foundationModels

    public init() {}

    public var modelName: String? { "Apple Foundation Models" }

    public func availability() async -> EngineAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            .ready
        case .unavailable(.appleIntelligenceNotEnabled):
            .unavailable("システム設定で Apple Intelligence を有効にしてください")
        case .unavailable(.modelNotReady):
            .needsDownload("システムモデルの準備中です。しばらく待ってから再確認してください")
        case .unavailable(.deviceNotEligible):
            .unavailable("この Mac は Apple Intelligence 非対応です")
        case .unavailable:
            .unavailable("システムモデルを利用できません")
        }
    }

    public func complete(prompt: FormattingPrompt, timeout: Duration) async throws -> String {
        guard case .ready = await availability() else {
            throw EngineError.notReady(await availability().message ?? "システムモデルを利用できません")
        }

        // 口述内容の整形は「変換」であってコンテンツ生成ではないため、
        // 変換向けの緩いガードレールを使う(強いガードレールは正当な発話まで弾く)。
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: prompt.system)

        // 再現性(NFR-4)のため greedy 固定。出力長は入力から見積もる。
        let options = GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: Self.responseTokenBudget(for: prompt.user)
        )

        return try await withEngineTimeout(timeout) {
            let response = try await session.respond(to: prompt.user, options: options)
            return response.content
        }
    }

    public func unload() async {
        // システム側がモデルのライフサイクルを管理するため、こちらから解放するものはない。
    }

    static func responseTokenBudget(for input: String) -> Int {
        // 日本語はおおよそ 1 文字 ≒ 1 トークン。整形で伸びる余地を見て 2 倍 + 下限。
        min(4_096, max(256, input.count * 2))
    }
}

/// 指定時間で打ち切る。整形のタイムアウトは異常系ではなくフォールバック経路の入口(FR-3.6)。
func withEngineTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw EngineError.timedOut
        }
        guard let result = try await group.next() else {
            throw EngineError.failed("処理が結果を返しませんでした")
        }
        group.cancelAll()
        return result
    }
}
