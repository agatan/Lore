import Foundation
import Testing

@testable import KoeKit

// MARK: - コンテキスト予算

@Suite("プロンプトの予算はエンジンのコンテキスト窓に収まる")
struct PromptBudgetTests {
    /// 応答枠を入力と無関係に確保すると、入力を積んだ時点で窓を超える。
    @Test("応答枠は入力が食った分を差し引く")
    func responseBudgetLeavesRoomForInput() {
        let prompt = FormattingPrompt(
            system: String(repeating: "指", count: 700),
            user: String(repeating: "話", count: 1_400)
        )
        let budget = FoundationModelsLlm.responseTokenBudget(for: prompt)

        #expect(budget < prompt.user.count * 2)
        #expect(prompt.system.count + prompt.user.count + budget <= FoundationModelsLlm.contextWindowTokens)
    }

    /// 整形は「出力は入力と同程度」の見積もりのままにする。
    @Test("整形は出力長を申告しないので入力の 2 倍を見込む")
    func formattingKeepsProportionalEstimate() {
        let prompt = FormattingPrompt(system: "短い指示", user: String(repeating: "あ", count: 300))
        #expect(FoundationModelsLlm.responseTokenBudget(for: prompt) == 600)
    }
}
