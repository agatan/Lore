import Foundation
import Testing
@testable import KoeKit

@Test func migrationRunsOnFreshDatabase() async throws {
    let database = try await KoeDatabase.inMemory()

    #expect(database.fileURL == nil)
    #expect(try await database.modes.all().count == BuiltinModes.all.count)
    #expect(try await database.history.count() == 0)
}

@Test func deletingAllUserDataCoversEveryPersistedDomain() async throws {
    let database = try await KoeDatabase.inMemory()
    let start = Date(timeIntervalSince1970: 1_725_158_400)
    try await database.history.save(makeSession(id: "delete", status: .completed, raw: "削除対象"))
    try await database.vocabulary.save(VocabularyEntry(id: "delete", surface: "削除語彙"))
    let chunk = LifeLogAudioChunk(
        id: "delete", captureStartedAt: start, captureEndedAt: start.addingTimeInterval(30),
        localPath: "/tmp/delete-all-user-data.m4a"
    )
    try await database.lifeLog.save(audioChunk: chunk)
    try await database.lifeLog.save(utterance: LifeLogUtterance(
        startedAt: start, endedAt: start.addingTimeInterval(10), text: "削除発話", audioChunkID: chunk.id
    ))

    try await database.deleteAllUserData()

    #expect(try await database.history.count() == 0)
    #expect(try await database.vocabulary.all().isEmpty)
    #expect(try await database.modes.all().isEmpty)
    #expect(try await database.lifeLog.day(start).utterances.isEmpty)
    #expect(try await database.lifeLog.pendingAudioChunks().isEmpty)
}

@Test func sessionUpsertPreservesOneAuditRow() async throws {
    let database = try await KoeDatabase.inMemory()
    var record = makeSession(id: "progress", status: .interrupted, raw: "確定した生テキスト")

    try await database.history.save(record)
    record.status = .completed
    record.formattedText = "確定した文章です。"
    record.endedAt = Date()
    try await database.history.save(record)

    #expect(try await database.history.count() == 1)
    let stored = try #require(await database.history.record(id: "progress"))
    #expect(stored.status == .completed)
    #expect(stored.rawTranscript == "確定した生テキスト")
    #expect(stored.formattedText == "確定した文章です。")
    #expect(stored.modeSnapshot == record.modeSnapshot)
}

@Test func japaneseSubstringSearchesRawAndFormattedText() async throws {
    let database = try await KoeDatabase.inMemory()
    try await database.history.save(makeSession(
        id: "raw",
        status: .completed,
        raw: "院内のレセコン連携を確認する"
    ))
    try await database.history.save(makeSession(
        id: "formatted",
        status: .completed,
        raw: "別の文字起こし",
        formatted: "明日はレセコン設定を更新します。"
    ))

    let results = try await database.history.search(query: "レセコン", limit: 10)
    #expect(Set(results.map(\.id)) == ["raw", "formatted"])
}

@Test func fullTextIndexFollowsUpdateAndDelete() async throws {
    let database = try await KoeDatabase.inMemory()
    var record = makeSession(id: "sync", status: .interrupted, raw: "更新前キーワード")
    try await database.history.save(record)
    #expect(try await database.history.search(query: "更新前", limit: 10).map(\.id) == ["sync"])

    record.status = .completed
    record.rawTranscript = "更新後キーワード"
    try await database.history.save(record)
    #expect(try await database.history.search(query: "更新前", limit: 10).isEmpty)
    #expect(try await database.history.search(query: "更新後", limit: 10).map(\.id) == ["sync"])

    try await database.history.delete(id: "sync")
    #expect(try await database.history.search(query: "更新後", limit: 10).isEmpty)
}

@Test func builtinSeedingRespectsEditsAndDeletion() async throws {
    let database = try await KoeDatabase.inMemory()
    let originalCount = try await database.modes.all().count

    try await database.modes.seedBuiltinsIfNeeded()
    #expect(try await database.modes.all().count == originalCount)

    var edited = try #require(await database.modes.mode(id: BuiltinModes.defaultModeID))
    edited.prompt = "ユーザーが編集したプロンプト"
    try await database.modes.save(edited)
    try await database.modes.seedBuiltinsIfNeeded()
    #expect(try await database.modes.mode(id: edited.id)?.prompt == edited.prompt)

    let deletedID = BuiltinModes.aiAgent.id
    try await database.modes.delete(id: deletedID)
    try await database.modes.seedBuiltinsIfNeeded()
    #expect(try await database.modes.mode(id: deletedID) == nil)
    #expect(try await database.modes.all().count == originalCount - 1)
}

@Test func suggestionsDeduplicateKnownSurfaces() async throws {
    let database = try await KoeDatabase.inMemory()
    try await database.vocabulary.save(VocabularyEntry(id: "known", surface: "Koe"))
    let rejected = makeSuggestion(id: "rejected", surface: "レセコン")
    #expect(try await database.vocabulary.insertSuggestions([rejected]) == 1)
    try await database.vocabulary.reject(suggestionID: rejected.id)

    let pending = makeSuggestion(id: "pending", surface: "Swift")
    #expect(try await database.vocabulary.insertSuggestions([pending]) == 1)
    let candidates = [
        makeSuggestion(id: "duplicate-vocabulary", surface: "Koe"),
        makeSuggestion(id: "duplicate-rejected", surface: "レセコン"),
        makeSuggestion(id: "duplicate-pending", surface: "Swift"),
        makeSuggestion(id: "new", surface: "GRDB"),
        makeSuggestion(id: "new-duplicate", surface: "GRDB"),
    ]

    #expect(try await database.vocabulary.insertSuggestions(candidates) == 1)
    #expect(try await database.vocabulary.knownSurfaces() == ["Koe", "レセコン"])
}

@Test func acceptingSuggestionPromotesVocabulary() async throws {
    let database = try await KoeDatabase.inMemory()
    let suggestion = VocabularySuggestion(
        id: "accept",
        surface: "ヘンリー",
        evidence: .init(
            kind: .repeatedCorrection,
            count: 4,
            misrecognitions: ["変理"],
            reading: "へんりー"
        )
    )
    #expect(try await database.vocabulary.insertSuggestions([suggestion]) == 1)

    let promoted = try #require(await database.vocabulary.accept(suggestionID: suggestion.id))
    #expect(promoted.surface == "ヘンリー")
    #expect(promoted.reading == "へんりー")
    #expect(promoted.misrecognitions == ["変理"])
    #expect(promoted.source == .suggested)
    #expect(try await database.vocabulary.suggestions(status: .accepted).map(\.id) == [suggestion.id])
    #expect(try await database.vocabulary.all().map(\.surface) == ["ヘンリー"])
}

@Test func purgeHonorsRetentionAndForeverSetting() async throws {
    let database = try await KoeDatabase.inMemory()
    try await database.history.save(makeSession(
        id: "old",
        startedAt: Date().addingTimeInterval(-10 * 86_400),
        status: .completed,
        raw: "古い履歴"
    ))
    try await database.history.save(makeSession(id: "new", status: .completed, raw: "新しい履歴"))

    #expect(try await database.history.purge(retentionDays: 0) == 0)
    #expect(try await database.history.count() == 2)
    #expect(try await database.history.purge(retentionDays: 5) == 1)
    #expect(try await database.history.recent(limit: 10).map(\.id) == ["new"])
}

@Test func latencyStatsUsesNearestRankPercentiles() async throws {
    let database = try await KoeDatabase.inMemory()
    for (index, latency) in [100, 200, 300, 400, 500].enumerated() {
        try await database.history.save(makeSession(
            id: "latency-\(index)",
            startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
            status: .completed,
            raw: "計測",
            insertLatencyMs: latency
        ))
    }

    #expect(try await database.history.latencyStats(limit: 5) == LatencyStats(count: 5, p50Ms: 300, p95Ms: 500))
}

@Suite("実測レイテンシは音声長に対する倍率で集計する")
struct MeasuredLatencyTests {
    /// 待ち時間の秒数だけでは速さが分からない(20 秒の発話か 5 分の発話かで意味が変わる)。
    @Test("倍率はセッションごとの比の中央値になる")
    func realtimeFactorIsMedianOfPerSessionRatios() async throws {
        let database = try await KoeDatabase.inMemory()
        // 音声 10 秒 / 20 秒 / 40 秒 に対し、比は 0.2 / 0.5 / 0.8。
        for (index, sample) in [(10_000, 2_000), (20_000, 10_000), (40_000, 32_000)].enumerated() {
            try await database.history.save(makeSession(
                id: "ratio-\(index)",
                startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                status: .completed,
                raw: "計測",
                audioDurationMs: sample.0,
                sttLatencyMs: sample.1
            ))
        }

        let measured = try await database.history.measuredLatencies(limit: 10)
        let stats = try #require(measured.transcription[HistoryStore.key("speech_analyzer", nil)])
        #expect(stats.count == 3)
        #expect(stats.realtimeFactorCount == 3)
        #expect(try #require(stats.realtimeFactor) == 0.5)
    }

    /// 立ち上がりコストが支配する極端に短い録音は倍率を歪めるので母数から外す。
    @Test("短すぎる録音と音声長の無い記録は倍率の母数から外れる")
    func shortAndUnknownDurationsAreExcludedFromRatio() async throws {
        let database = try await KoeDatabase.inMemory()
        try await database.history.save(makeSession(
            id: "too-short",
            startedAt: Date(timeIntervalSince1970: 1),
            status: .completed,
            raw: "短い",
            audioDurationMs: 200,
            sttLatencyMs: 1_000
        ))
        try await database.history.save(makeSession(
            id: "unknown-duration",
            startedAt: Date(timeIntervalSince1970: 2),
            status: .completed,
            raw: "長さ不明",
            sttLatencyMs: 1_000
        ))

        let measured = try await database.history.measuredLatencies(limit: 10)
        let stats = try #require(measured.transcription[HistoryStore.key("speech_analyzer", nil)])
        // 秒数の母数には入るが、倍率は出せない。
        #expect(stats.count == 2)
        #expect(stats.realtimeFactorCount == 0)
        #expect(stats.realtimeFactor == nil)
    }
}

private func makeSession(
    id: String,
    startedAt: Date = Date(),
    status: SessionStatus,
    raw: String,
    formatted: String? = nil,
    audioDurationMs: Int? = nil,
    sttLatencyMs: Int? = nil,
    insertLatencyMs: Int? = nil
) -> SessionRecord {
    SessionRecord(
        id: id,
        startedAt: startedAt,
        status: status,
        modeID: BuiltinModes.defaultModeID,
        modeSnapshot: ModeSnapshot(
            modeName: "Default",
            modePrompt: "基本整形",
            systemPrompt: "実際に使用したプロンプト",
            vocabularyCount: 2,
            trigger: .toggle
        ),
        sttEngine: .speechAnalyzer,
        llmEngine: .foundationModels,
        language: .ja,
        rawTranscript: raw,
        formattedText: formatted,
        audioDurationMs: audioDurationMs,
        sttLatencyMs: sttLatencyMs,
        insertLatencyMs: insertLatencyMs
    )
}

private func makeSuggestion(id: String, surface: String) -> VocabularySuggestion {
    VocabularySuggestion(
        id: id,
        surface: surface,
        evidence: .init(kind: .frequentTerm, count: 3)
    )
}

@Suite("共通ルールはモードと同じ規則で永続化する")
struct SharedRulesStoreTests {
    @Test("未保存なら同梱内容が入る")
    func seedsShippedText() async throws {
        let database = try await KoeDatabase.inMemory()
        try await database.sharedRules.seedOrMigrate()
        #expect(try await database.sharedRules.current() == BuiltinSharedRules.text)
        #expect(try await database.sharedRules.isEdited() == false)
    }

    @Test("編集した内容は同梱内容の更新で上書きされない")
    func keepsEditedText() async throws {
        let database = try await KoeDatabase.inMemory()
        try await database.sharedRules.seedOrMigrate()
        try await database.sharedRules.save("自分で書いたルール")

        // 起動し直しても編集内容が残る。
        try await database.sharedRules.seedOrMigrate()
        #expect(try await database.sharedRules.current() == "自分で書いたルール")
        #expect(try await database.sharedRules.isEdited())
    }

    @Test("標準の内容に戻せる")
    func resetsToShipped() async throws {
        let database = try await KoeDatabase.inMemory()
        try await database.sharedRules.seedOrMigrate()
        try await database.sharedRules.save("書き換えた")
        #expect(try await database.sharedRules.reset() == BuiltinSharedRules.text)
        #expect(try await database.sharedRules.isEdited() == false)
    }

    /// 共通ルールが空でもプロンプトが壊れないこと(全部消して保存できてしまうため)。
    @Test("共通ルールを空にしてもモード指示と語彙は渡る")
    func emptySharedRulesStillBuildsPrompt() {
        let prompt = FormattingPolicy.systemPrompt(
            sharedRules: "",
            mode: BuiltinModes.aiAgent,
            vocabulary: [VocabularyEntry(surface: "レセコン")]
        )
        #expect(prompt.contains("レセコン"))
        #expect(prompt.contains("AI コーディングエージェントへの指示文"))
        #expect(!prompt.hasPrefix("\n"))
    }
}

@Suite("共通ルールとモード指示が衝突しない")
struct PromptConsistencyTests {
    /// 「補う」と「足さない」は言い方を揃えないと逆向きの指示になる。
    /// 補完の許可は共通側にだけ書き、モード側では繰り返さない。
    @Test("補完の許可は共通ルールにあり、モードは繰り返さない")
    func completionRuleLivesInSharedRulesOnly() {
        #expect(BuiltinSharedRules.text.contains("主語・助詞・接続詞の欠けは補う"))
        #expect(BuiltinSharedRules.text.contains("「情報を足す」ことには当たらない"))

        for mode in BuiltinModes.all {
            #expect(
                !mode.prompt.contains("補って"),
                "\(mode.name) が共通ルールと重複する補完指示を持っている"
            )
        }
    }

    /// 共通ルールは言いよどみを消す。モードが「そのまま残す」と書くと逆向きになる。
    @Test("モードは言いよどみの保持を指示しない")
    func modesDoNotAskToKeepDisfluencies() {
        for mode in BuiltinModes.all {
            #expect(
                !mode.prompt.contains("そのまま残す"),
                "\(mode.name) が言いよどみ除去と逆向きの指示を持っている"
            )
        }
    }
}

@Suite("語彙表は置換命令にしない")
struct VocabularyPromptToneTests {
    let vocabulary = [
        VocabularyEntry(surface: "医事", reading: "いじ", misrecognitions: ["維持"])
    ]

    /// 同じ読みで表記が分かれる語は文脈で決まる。「維持」は正しい語でもあるので、
    /// 機械的な置換を命じるのは誤り。判断の材料を渡す書き方を固定する。
    @Test("必ず置き換えろとは書かない")
    func doesNotCommandUnconditionalReplacement() {
        let table = try! #require(FormattingPolicy.vocabularyTable(vocabulary))
        #expect(!table.contains("必ず"))
        #expect(!table.contains("最優先"))
        #expect(table.contains("文脈に合うときだけ"))
        #expect(table.contains("機械的に置き換えない"))
        // 判断に必要な材料(表記・読み・化けやすい形)は渡す。
        #expect(table.contains("医事(いじ)"))
        #expect(table.contains("「維持」"))

        // 判断の基準は見出しに 1 回だけ。語ごとに繰り返すと入力を無駄に食う。
        let twoEntries = try! #require(FormattingPolicy.vocabularyTable([
            VocabularyEntry(surface: "医事", reading: "いじ", misrecognitions: ["維持"]),
            VocabularyEntry(surface: "レセコン", reading: "れせこん", misrecognitions: ["レセ困"]),
        ]))
        #expect(twoEntries.components(separatedBy: "機械的に置き換えない").count - 1 == 1)
        #expect(twoEntries.components(separatedBy: "← の右は").count - 1 == 1)
    }

    @Test("共通ルールも語彙を最優先だと言わない")
    func sharedRulesDoNotOverrideContext() {
        #expect(!BuiltinSharedRules.text.contains("必ずその表記に置き換える"))
        #expect(BuiltinSharedRules.text.contains("機械的に置き換えない"))
    }

    /// モードの指示は見出しを被せずそのまま連ねる。
    @Test("モード指示に見出しを付けない")
    func modePromptIsConcatenatedPlainly() {
        let prompt = FormattingPolicy.systemPrompt(mode: BuiltinModes.aiAgent, vocabulary: [])
        #expect(!prompt.contains("固有の指示"))
        #expect(prompt.contains("AI コーディングエージェントへの指示文"))
    }

    /// 語彙表は入力にいちばん近い位置(最後)に置く。
    @Test("語彙表はモード指示より後ろに来る")
    func vocabularyComesAfterModePrompt() {
        let prompt = FormattingPolicy.systemPrompt(
            mode: BuiltinModes.aiAgent,
            vocabulary: [VocabularyEntry(surface: "レセコン")]
        )
        let mode = try! #require(prompt.range(of: "AI コーディングエージェントへの指示文"))
        let table = try! #require(prompt.range(of: "# 語彙表"))
        #expect(mode.lowerBound < table.lowerBound)
    }
}
