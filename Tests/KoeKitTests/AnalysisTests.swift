import Foundation
import Synchronization
import Testing

@testable import KoeKit

// MARK: - コンテキスト予算

@Suite("プロンプトの予算はエンジンのコンテキスト窓に収まる")
struct PromptBudgetTests {
    /// 語彙分析が動かなかった原因そのもの。
    /// 応答枠を入力と無関係に確保すると、入力を積んだ時点で窓を超える。
    @Test("応答枠は入力が食った分を差し引く")
    func responseBudgetLeavesRoomForInput() {
        let prompt = FormattingPrompt(
            system: String(repeating: "指", count: 700),
            user: String(repeating: "話", count: 1_400),
            expectedOutputCharacters: 900
        )
        let budget = FoundationModelsLlm.responseTokenBudget(for: prompt)

        #expect(budget <= 900)
        #expect(prompt.system.count + prompt.user.count + budget <= FoundationModelsLlm.contextWindowTokens)
    }

    /// 整形は「出力は入力と同程度」の見積もりのままにする。
    @Test("整形は出力長を申告しないので入力の 2 倍を見込む")
    func formattingKeepsProportionalEstimate() {
        let prompt = FormattingPrompt(system: "短い指示", user: String(repeating: "あ", count: 300))
        #expect(FoundationModelsLlm.responseTokenBudget(for: prompt) == 600)
    }
}

// MARK: - コーパスの分割

@Suite("履歴の分析はエンジンの入力予算に収まるバッチへ分割する")
struct VocabularyCorpusBatchingTests {
    private func entries(count: Int, bodyLength: Int) -> [VocabularySuggestionJob.Entry] {
        (0..<count).map { index in
            VocabularySuggestionJob.Entry(
                id: "session-\(index)",
                body: String(repeating: "話", count: bodyLength)
            )
        }
    }

    @Test("どのバッチも予算を超えない")
    func everyBatchFitsBudget() {
        let batches = VocabularySuggestionJob.batches(
            entries(count: 20, bodyLength: 100),
            budget: 400,
            maxBatches: 100
        )

        #expect(batches.count > 1)
        for batch in batches {
            #expect(batch.reduce(0) { $0 + $1.cost } <= 400)
        }
        // 分割しても 1 件も落とさない。
        #expect(batches.flatMap { $0 }.count == 20)
    }

    /// 1 件だけで予算を超えるセッションも、捨てずに単独のバッチにする
    /// (捨てると「分析したのに候補が出ない」理由が説明できなくなる)。
    @Test("単体で予算を超えるセッションも落とさない")
    func oversizedEntryStillGetsItsOwnBatch() {
        let batches = VocabularySuggestionJob.batches(
            entries(count: 3, bodyLength: 1_000),
            budget: 400,
            maxBatches: 100
        )

        #expect(batches.count == 3)
        #expect(batches.allSatisfy { $0.count == 1 })
    }

    /// 1 回の実行時間に上限を置く。溢れた分は透かしが進まないので次回が引き継ぐ。
    @Test("バッチ数の上限で打ち切る")
    func batchCountIsCapped() {
        let batches = VocabularySuggestionJob.batches(
            entries(count: 40, bodyLength: 100),
            budget: 200,
            maxBatches: 3
        )

        #expect(batches.count == 3)
    }

    @Test("固定部分が予算を食い切っても下限は残す")
    func corpusBudgetKeepsFloor() {
        let budget = VocabularySuggestionJob.corpusBudget(
            inputBudget: 100,
            knownHeader: String(repeating: "語", count: 500)
        )
        #expect(budget == VocabularySuggestionJob.minimumCorpusBudget)
    }

    @Test("同じ語が複数バッチから挙がったら誤認識パターンを寄せる")
    func mergeUnionsMisrecognitions() {
        var candidates: [String: VocabularySuggestionJob.Candidate] = [:]
        VocabularySuggestionJob.merge(
            .init(surface: "レセコン", kind: .frequentTerm, reading: nil, misrecognitions: ["レセ婚"]),
            into: &candidates
        )
        VocabularySuggestionJob.merge(
            .init(surface: "レセコン", kind: .frequentTerm, reading: "れせこん", misrecognitions: ["レセ紺"]),
            into: &candidates
        )

        #expect(candidates.count == 1)
        let merged = try! #require(candidates["レセコン"])
        #expect(Set(merged.misrecognitions) == ["レセ婚", "レセ紺"])
        #expect(merged.reading == "れせこん")
    }
}

// MARK: - ジョブ全体

@Suite("語彙提案ジョブの実行")
struct VocabularySuggestionJobRunTests {
    /// 予算の狭いエンジンでも分析が完走し、渡したプロンプトが窓を超えないこと。
    @Test("狭い入力予算のエンジンでも分割して完走する")
    func runsWithinNarrowInputBudget() async throws {
        let database = try await KoeDatabase.inMemory()
        for index in 0..<12 {
            try await database.history.save(makeAnalysisSession(
                index: index,
                raw: "きょうもレセコンの設定を確認しました。" + String(repeating: "詳細な説明が続きます。", count: 8)
            ))
        }

        let llm = RecordingLlm(inputCharacterBudget: 1_200, response: #"[{"surface":"レセコン","kind":"frequent_term"}]"#)
        let job = VocabularySuggestionJob(
            history: database.history,
            vocabulary: database.vocabulary,
            meta: database.meta,
            llm: llm
        )

        let result = try await job.run(force: true)

        #expect(result.batches > 1)
        #expect(result.failedBatches == 0)
        #expect(result.created == 1)
        // 実際に投げたプロンプトが全部予算内に収まっている = コンテキスト超過が起きない。
        for prompt in llm.prompts {
            #expect(prompt.system.count + prompt.user.count <= llm.inputCharacterBudget)
            #expect(prompt.expectedOutputCharacters != nil)
        }
        // 分析できた範囲は透かしに残り、次回は続きから始まる。
        #expect(try await database.meta.date(forKey: VocabularySuggestionJob.watermarkKey) != nil)
    }

    /// 全滅は「成功 0 件」に丸めず、理由を呼び出し側へ返す。
    @Test("すべてのバッチが失敗したらエラーを投げ、透かしを進めない")
    func totalFailureThrowsAndKeepsWatermark() async throws {
        let database = try await KoeDatabase.inMemory()
        for index in 0..<8 {
            try await database.history.save(makeAnalysisSession(index: index, raw: "レセコンの設定を確認しました。"))
        }

        let llm = RecordingLlm(inputCharacterBudget: 2_200, failure: EngineError.failed("コンテキスト超過"))
        let job = VocabularySuggestionJob(
            history: database.history,
            vocabulary: database.vocabulary,
            meta: database.meta,
            llm: llm
        )

        await #expect(throws: EngineError.self) { try await job.run(force: true) }
        #expect(try await database.meta.date(forKey: VocabularySuggestionJob.watermarkKey) == nil)
    }

    @Test("履歴が少なすぎるときはモデルを呼ばない")
    func skipsWhenNotEnoughHistory() async throws {
        let database = try await KoeDatabase.inMemory()
        try await database.history.save(makeAnalysisSession(index: 0, raw: "一件だけ"))

        let llm = RecordingLlm(inputCharacterBudget: 2_200, response: "[]")
        let job = VocabularySuggestionJob(
            history: database.history,
            vocabulary: database.vocabulary,
            meta: database.meta,
            llm: llm
        )

        #expect(try await job.run(force: true) == .notEnoughData)
        #expect(llm.prompts.isEmpty)
    }
}

/// 受け取ったプロンプトを記録するだけの LLM。予算の検証に使う。
private final class RecordingLlm: LlmEngine, @unchecked Sendable {
    let identifier = EngineIdentifier("test_llm")
    var modelName: String? { "テスト用" }
    let inputCharacterBudget: Int

    private let response: String
    private let failure: (any Error)?
    private let recorded = Mutex<[FormattingPrompt]>([])

    var prompts: [FormattingPrompt] { recorded.withLock { $0 } }

    init(inputCharacterBudget: Int, response: String = "[]", failure: (any Error)? = nil) {
        self.inputCharacterBudget = inputCharacterBudget
        self.response = response
        self.failure = failure
    }

    func availability() async -> EngineAvailability { .ready }

    func complete(prompt: FormattingPrompt, timeout: Duration) async throws -> String {
        recorded.withLock { $0.append(prompt) }
        if let failure { throw failure }
        return response
    }

    func unload() async {}
}

private func makeAnalysisSession(index: Int, raw: String) -> SessionRecord {
    SessionRecord(
        id: "analysis-\(index)",
        startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
        status: .completed,
        modeID: BuiltinModes.defaultModeID,
        modeSnapshot: ModeSnapshot(
            modeName: "Default",
            modePrompt: "基本整形",
            systemPrompt: "実際に使用したプロンプト",
            vocabularyCount: 0,
            trigger: .toggle
        ),
        sttEngine: .speechAnalyzer,
        llmEngine: .foundationModels,
        language: .ja,
        rawTranscript: raw
    )
}
