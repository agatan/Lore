import Foundation
import Testing
@testable import KoeKit

@Test func migrationRunsOnFreshDatabase() async throws {
    let database = try await KoeDatabase.inMemory()

    #expect(database.fileURL == nil)
    #expect(try await database.modes.all().count == BuiltinModes.all.count)
    #expect(try await database.history.count() == 0)
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

private func makeSession(
    id: String,
    startedAt: Date = Date(),
    status: SessionStatus,
    raw: String,
    formatted: String? = nil,
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
