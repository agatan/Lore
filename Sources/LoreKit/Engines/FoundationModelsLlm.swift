import FoundationModels
import Foundation

/// macOS 標準のオンデバイスモデルによる整形。ダウンロード不要で即使える構成の要(FR-9.3)。
public final class FoundationModelsLlm: LlmEngine {
    public let identifier = EngineIdentifier.foundationModels

    public init() {}

    public var modelName: String? { "Apple Foundation Models" }

    /// システムモデルのコンテキスト窓は 4,096 トークンで、instructions・prompt・応答が
    /// **その 1 枠を共有する**。日本語はおおよそ 1 文字 ≒ 1 トークンなので、
    /// 応答と内部トークンの分を残した保守的な入力枠をここで宣言する。
    static let contextWindowTokens = 4_096
    public var inputCharacterBudget: Int { 2_200 }

    public func availability() async -> EngineAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            .ready
        case .unavailable(.appleIntelligenceNotEnabled):
            .unavailable(String(lore: "システム設定で Apple Intelligence を有効にしてください"))
        case .unavailable(.modelNotReady):
            .needsDownload(String(lore: "システムモデルの準備中です。しばらく待ってから再確認してください"))
        case .unavailable(.deviceNotEligible):
            .unavailable(String(lore: "この Mac は Apple Intelligence 非対応です"))
        case .unavailable:
            .unavailable(String(lore: "システムモデルを利用できません"))
        }
    }

    public func complete(prompt: FormattingPrompt, timeout: Duration) async throws -> String {
        guard case .ready = await availability() else {
            throw EngineError.notReady(await availability().message ?? String(lore: "システムモデルを利用できません"))
        }

        // 口述内容の整形は「変換」であってコンテンツ生成ではないため、
        // 変換向けの緩いガードレールを使う(強いガードレールは正当な発話まで弾く)。
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: prompt.system)

        // 再現性(NFR-4)のため greedy 固定。出力長はプロンプトの申告から見積もる。
        let options = GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: Self.responseTokenBudget(for: prompt)
        )

        return try await withEngineTimeout(timeout) {
            let response = try await session.respond(to: prompt.user, options: options)
            return response.content
        }
    }

    public func unload() async {
        // システム側がモデルのライフサイクルを管理するため、こちらから解放するものはない。
    }

    /// 応答に許すトークン数。
    ///
    /// 日本語はおおよそ 1 文字 ≒ 1 トークン。整形なら入力の 2 倍を見込むが、
    /// **コンテキスト窓は入力と応答で共有する**ので、入力が食った分を必ず差し引く。
    /// 差し引かないと「入力 2,000 字 + 応答枠 4,000」のように窓を超え、
    /// モデルが入力を読む前に失敗する。
    static func responseTokenBudget(for prompt: FormattingPrompt) -> Int {
        let expected = prompt.user.count * 2
        let consumed = prompt.system.count + prompt.user.count
        return max(128, min(expected, contextWindowTokens - consumed))
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
            throw EngineError.failed(String(lore: "処理が結果を返しませんでした"))
        }
        group.cancelAll()
        return result
    }
}
