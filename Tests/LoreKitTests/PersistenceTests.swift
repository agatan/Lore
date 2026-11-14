import Foundation
import GRDB
import Testing
@testable import LoreKit

@Test func migrationRunsOnFreshDatabase() async throws {
    let database = try await LoreDatabase.inMemory()

    #expect(database.fileURL == nil)
    #expect(try await database.modes.all().count == BuiltinModes.all.count)
    #expect(try await database.history.count() == 0)
}

@Test func existingDatabaseIsBackedUpBeforeMigration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-backup-test-\(UUID().uuidString)")
    let databaseURL = root.appendingPathComponent("lore.sqlite")
    let backupDirectory = root.appendingPathComponent("Backups")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = try DatabaseQueue(path: databaseURL.path)

    _ = try await LoreDatabase.open(
        fileURL: databaseURL,
        backupDirectory: backupDirectory,
        now: Date(timeIntervalSince1970: 1_788_112_800)
    )

    let backups = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
    #expect(backups.count == 1)
    #expect(backups[0].lastPathComponent.hasPrefix("pre-migration-"))
    try FileManager.default.removeItem(at: root)
}

/// TODO・要約・token集計を廃止したv9は、発話とメモを保ったまま旧tableを消す。
@Test func removingTodoSummaryAndUsageKeepsLifeLogText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-v9-test-\(UUID().uuidString)")
    let databaseURL = root.appendingPathComponent("lore.sqlite")
    let backupDirectory = root.appendingPathComponent("Backups")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let legacy = try DatabaseQueue(path: databaseURL.path)
        try LoreDatabase.migrator.migrate(legacy, upTo: "v8-llm-token-usage")
        try await legacy.write { db in
            try db.execute(sql: """
                INSERT INTO life_log_audio_chunks (id, capture_started_at, capture_ended_at, local_path, transcription_state, processing_state)
                  VALUES ('audio', '2026-08-29T09:00:00.000Z', '2026-08-29T09:00:30.000Z', '/tmp/v9.m4a', 'transcribed', 'extracted');
                INSERT INTO life_log_conversations VALUES ('conversation', '2026-08-29T09:00:00.000Z', '2026-08-29T09:00:30.000Z', NULL);
                INSERT INTO life_log_utterances VALUES ('utterance', '2026-08-29T09:00:01.000Z', '2026-08-29T09:00:05.000Z',
                  'レセコンの移行を相談した', 'audio', NULL, 'conversation');
                INSERT INTO life_log_memos VALUES ('memo', '2026-08-29T09:01:00.000Z', '診療報酬の確認');
                INSERT INTO life_log_todos (id, title, status, created_at, source_utterance_ids, source_memo_ids)
                  VALUES ('todo', '請求データを確認', 'open', '2026-08-29T09:02:00.000Z', '[]', '[]');
                INSERT INTO daily_summaries VALUES ('2026-08-29', '移行計画', '[]', '[]', 0, 0, 1, '2026-08-29T09:02:00.000Z', 0);
                INSERT INTO llm_usage_events VALUES ('usage', '2026-08-29T09:03:00.000Z', '2026-08-29', 'dictation', 'openAI', NULL, 1, 1, 2);
                """)
        }
    }

    let database = try await LoreDatabase.open(fileURL: databaseURL, backupDirectory: backupDirectory)

    let results = try await database.lifeLog.search("レセコン")
    #expect(results.map(\.id) == ["utterance-utterance"])
    #expect(try await database.lifeLog.search("診療").map(\.kind) == [.memo])
    let date = try PersistenceCoding.decodeDate("2026-08-29T09:00:01.000Z")
    #expect(try await database.lifeLog.utterances(audioChunkID: "audio").map(\.text) == ["レセコンの移行を相談した"])
    #expect(try await database.lifeLog.search("移行計画").isEmpty)
    #expect(try await database.lifeLog.day(date).memos.map(\.id) == ["memo"])
    let tables = try await database.queue.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    for removed in ["life_log_todos", "life_log_todos_fts", "daily_summaries", "daily_summaries_fts", "llm_usage_events", "life_log_conversations"] {
        #expect(!tables.contains(removed))
    }
    let columns = try await database.queue.read { db in try db.columns(in: "life_log_utterances").map(\.name) }
    #expect(!columns.contains("conversation_id"))
    // 新しい発話もFTSへ入る。
    try await database.lifeLog.save(utterance: LifeLogUtterance(
        id: "new", startedAt: date.addingTimeInterval(10), endedAt: date.addingTimeInterval(12), text: "移行後の発話", audioChunkID: "audio"
    ))
    #expect(try await database.lifeLog.search("移行後").map(\.id) == ["utterance-new"])

    // 消したTODOと要約はmigration直前のbackupから回収できる。
    let backup = try #require(try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix("pre-migration-") })
    let backupQueue = try DatabaseQueue(path: backup.path)
    #expect(try await backupQueue.read { try String.fetchOne($0, sql: "SELECT title FROM life_log_todos") } == "請求データを確認")
}

@Test func dailyBackupIsAConsistentOncePerDaySnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-backup-test-\(UUID().uuidString)")
    let databaseURL = root.appendingPathComponent("lore.sqlite")
    let backupDirectory = root.appendingPathComponent("Backups")
    let day = Date(timeIntervalSince1970: 1_788_112_800)

    var database: LoreDatabase? = try await LoreDatabase.open(
        fileURL: databaseURL,
        backupDirectory: backupDirectory,
        now: day
    )
    try await database?.history.save(makeSession(id: "before-backup", status: .completed, raw: "保存済み"))
    database = try await LoreDatabase.open(fileURL: databaseURL, backupDirectory: backupDirectory, now: day)
    try await database?.history.save(makeSession(id: "after-backup", status: .completed, raw: "後から追加"))
    database = try await LoreDatabase.open(fileURL: databaseURL, backupDirectory: backupDirectory, now: day)

    let backups = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
    let daily = try #require(backups.first { $0.lastPathComponent.hasPrefix("daily-") })
    let backupQueue = try DatabaseQueue(path: daily.path)
    #expect(try await HistoryStore(queue: backupQueue).count() == 1)
    #expect(try await HistoryStore(queue: backupQueue).record(id: "before-backup") != nil)
    #expect(try await HistoryStore(queue: backupQueue).record(id: "after-backup") == nil)
    try database?.deleteBackups()
    #expect(!FileManager.default.fileExists(atPath: backupDirectory.path))
    try FileManager.default.removeItem(at: root)
}

@Test func backupRetentionKeepsSevenNewestSnapshots() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-backup-test-\(UUID().uuidString)")
    let databaseURL = root.appendingPathComponent("lore.sqlite")
    let backupDirectory = root.appendingPathComponent("Backups")
    let firstDay = Date(timeIntervalSince1970: 1_788_112_800)
    var database: LoreDatabase? = try await LoreDatabase.open(
        fileURL: databaseURL,
        backupDirectory: backupDirectory,
        now: firstDay
    )

    for offset in 0..<8 {
        let date = firstDay.addingTimeInterval(TimeInterval(offset * 86_400))
        database = try await LoreDatabase.open(fileURL: databaseURL, backupDirectory: backupDirectory, now: date)
        let created = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ).max { lhs, rhs in
            let left = try lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let right = try rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return left < right
        }
        if let created {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: created.path)
        }
    }

    let backups = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
    #expect(backups.count == 7)
    try database?.deleteBackups()
    try FileManager.default.removeItem(at: root)
}

@Test func deletingAllUserDataCoversEveryPersistedDomain() async throws {
    let database = try await LoreDatabase.inMemory()
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
    let database = try await LoreDatabase.inMemory()
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
    let database = try await LoreDatabase.inMemory()
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
    let database = try await LoreDatabase.inMemory()
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
    let database = try await LoreDatabase.inMemory()
    let originalCount = try await database.modes.all().count
    #expect(try await database.modes.mode(id: BuiltinModes.defaultModeID)?.isBuiltin == true)
    #expect(try await database.modes.mode(id: BuiltinModes.chat.id)?.isBuiltin == false)

    try await database.modes.seedBuiltinsIfNeeded()
    #expect(try await database.modes.all().count == originalCount)

    var edited = try #require(await database.modes.mode(id: BuiltinModes.defaultModeID))
    edited.prompt = "ユーザーが編集したプロンプト"
    try await database.modes.save(edited)
    try await database.modes.seedBuiltinsIfNeeded()
    #expect(try await database.modes.mode(id: edited.id)?.prompt == edited.prompt)

    let deletedID = BuiltinModes.chat.id
    try await database.modes.delete(id: deletedID)
    try await database.modes.seedBuiltinsIfNeeded()
    #expect(try await database.modes.mode(id: deletedID) == nil)
    #expect(try await database.modes.all().count == originalCount - 1)

    await #expect(throws: ModeStoreError.self) {
        try await database.modes.delete(id: BuiltinModes.defaultModeID)
    }

    try await database.modes.save(Mode(id: "builtin.ai-agent", name: "AI Agent", prompt: "legacy"))
    try await database.modes.seedBuiltinsIfNeeded()
    #expect(try await database.modes.mode(id: "builtin.ai-agent") == nil)
}

@Test func purgeHonorsRetentionAndForeverSetting() async throws {
    let database = try await LoreDatabase.inMemory()
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
    let database = try await LoreDatabase.inMemory()
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
        let database = try await LoreDatabase.inMemory()
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
        let database = try await LoreDatabase.inMemory()
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

@Suite("共通ルールはモードと同じ規則で永続化する")
struct SharedRulesStoreTests {
    @Test("未保存なら同梱内容が入る")
    func seedsShippedText() async throws {
        let database = try await LoreDatabase.inMemory()
        try await database.sharedRules.seedOrMigrate()
        #expect(try await database.sharedRules.current() == BuiltinSharedRules.text)
        #expect(try await database.sharedRules.isEdited() == false)
    }

    @Test("編集した内容は同梱内容の更新で上書きされない")
    func keepsEditedText() async throws {
        let database = try await LoreDatabase.inMemory()
        try await database.sharedRules.seedOrMigrate()
        try await database.sharedRules.save("自分で書いたルール")

        // 起動し直しても編集内容が残る。
        try await database.sharedRules.seedOrMigrate()
        #expect(try await database.sharedRules.current() == "自分で書いたルール")
        #expect(try await database.sharedRules.isEdited())
    }

    @Test("標準の内容に戻せる")
    func resetsToShipped() async throws {
        let database = try await LoreDatabase.inMemory()
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
            mode: BuiltinModes.chat,
            vocabulary: [VocabularyEntry(surface: "レセコン")]
        )
        #expect(prompt.contains("レセコン"))
        #expect(prompt.contains("Format the text as a chat message"))
        #expect(!prompt.hasPrefix("\n"))
    }
}

@Suite("共通ルールとモード指示が衝突しない")
struct PromptConsistencyTests {
    /// 「補う」と「足さない」は言い方を揃えないと逆向きの指示になる。
    /// 補完の許可は共通側にだけ書き、モード側では繰り返さない。
    @Test("補完の許可は共通ルールにあり、モードは繰り返さない")
    func completionRuleLivesInSharedRulesOnly() {
        #expect(BuiltinSharedRules.text.contains("Supply a missing particle, subject, or connective"))
        #expect(BuiltinSharedRules.text.contains("That is not adding information"))

        for mode in BuiltinModes.all {
            #expect(
                !mode.prompt.localizedCaseInsensitiveContains("supply"),
                "\(mode.name) が共通ルールと重複する補完指示を持っている"
            )
        }
    }

    /// 共通ルールは言いよどみを消す。モードが「そのまま残す」と書くと逆向きになる。
    @Test("モードは言いよどみの保持を指示しない")
    func modesDoNotAskToKeepDisfluencies() {
        for mode in BuiltinModes.all {
            #expect(
                !mode.prompt.localizedCaseInsensitiveContains("keep filler"),
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
        #expect(!table.localizedCaseInsensitiveContains("always"))
        #expect(!table.localizedCaseInsensitiveContains("must"))
        #expect(table.contains("only when the context fits"))
        #expect(table.contains("do not replace mechanically"))
        // 判断に必要な材料(表記・読み・化けやすい形)は渡す。
        #expect(table.contains("医事(いじ)"))
        #expect(table.contains("「維持」"))

        // 判断の基準は見出しに 1 回だけ。語ごとに繰り返すと入力を無駄に食う。
        let twoEntries = try! #require(FormattingPolicy.vocabularyTable([
            VocabularyEntry(surface: "医事", reading: "いじ", misrecognitions: ["維持"]),
            VocabularyEntry(surface: "レセコン", reading: "れせこん", misrecognitions: ["レセ困"]),
        ]))
        #expect(twoEntries.components(separatedBy: "do not replace mechanically").count - 1 == 1)
        #expect(twoEntries.components(separatedBy: "After ←").count - 1 == 1)
    }

    @Test("共通ルールも語彙を最優先だと言わない")
    func sharedRulesDoNotOverrideContext() {
        #expect(!BuiltinSharedRules.text.localizedCaseInsensitiveContains("always replace"))
        #expect(BuiltinSharedRules.text.contains("Do not replace mechanically"))
    }

    /// モードの指示は見出しを被せずそのまま連ねる。
    @Test("モード指示に見出しを付けない")
    func modePromptIsConcatenatedPlainly() {
        let prompt = FormattingPolicy.systemPrompt(mode: BuiltinModes.chat, vocabulary: [])
        #expect(!prompt.contains("固有の指示"))
        #expect(prompt.contains("Format the text as a chat message"))
    }

    /// 語彙表は入力にいちばん近い位置(最後)に置く。
    @Test("語彙表はモード指示より後ろに来る")
    func vocabularyComesAfterModePrompt() {
        let prompt = FormattingPolicy.systemPrompt(
            mode: BuiltinModes.chat,
            vocabulary: [VocabularyEntry(surface: "レセコン")]
        )
        let mode = try! #require(prompt.range(of: "Format the text as a chat message"))
        let table = try! #require(prompt.range(of: "# Vocabulary"))
        #expect(mode.lowerBound < table.lowerBound)
    }
}

@Suite("語彙候補の廃止migration")
struct RemoveVocabularySuggestionsMigrationTests {
    private func legacyDatabase(at root: URL) throws -> URL {
        let databaseURL = root.appendingPathComponent("lore.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = try DatabaseQueue(path: databaseURL.path)
        try LoreDatabase.migrator.migrate(legacy, upTo: "v10-sync")
        try legacy.write { db in
            try db.execute(sql: """
                INSERT INTO vocabulary (id, surface, reading, misrecognitions, source, enabled, created_at)
                  VALUES ('promoted', 'レセコン', NULL, '["れせこん"]', 'suggested', 1, '2026-08-29T09:00:00.000Z'),
                         ('manual', 'Lore', NULL, '[]', 'manual', 1, '2026-08-29T09:01:00.000Z');
                INSERT INTO vocab_suggestions (id, surface, evidence, status, created_at)
                  VALUES ('pending', 'GRDB', '{"kind":"frequentTerm","count":3,"examples":[],"misrecognitions":[]}', 'pending', '2026-08-29T09:00:00.000Z');
                INSERT INTO meta (key, value) VALUES
                  ('vocab_analysis_watermark', '2026-08-29T09:00:00.000Z'),
                  ('vocab_analysis_last_run', '2026-08-29T09:00:00.000Z'),
                  ('unrelated', 'keep');
                """)
        }
        return databaseURL
    }

    @Test("候補tableと分析の記録だけを消し、候補から登録した語彙は残す")
    func dropsSuggestionsAndKeepsVocabulary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-v11-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = try legacyDatabase(at: root)

        let database = try await LoreDatabase.open(fileURL: databaseURL, backupDirectory: root.appendingPathComponent("Backups"))

        let entries = try await database.vocabulary.all()
        #expect(Set(entries.map(\.id)) == ["promoted", "manual"])
        #expect(entries.first { $0.id == "promoted" }?.source == .suggested)
        #expect(try await database.meta.string(forKey: "vocab_analysis_watermark") == nil)
        #expect(try await database.meta.string(forKey: "vocab_analysis_last_run") == nil)
        #expect(try await database.meta.string(forKey: "unrelated") == "keep")
        let queue = try DatabaseQueue(path: databaseURL.path)
        #expect(try await queue.read { try $0.tableExists("vocab_suggestions") } == false)
    }

    @Test("消す前の候補はmigration直前のbackupから読める")
    func backupKeepsDroppedSuggestions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-v11-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = try legacyDatabase(at: root)
        let backupDirectory = root.appendingPathComponent("Backups")

        _ = try await LoreDatabase.open(fileURL: databaseURL, backupDirectory: backupDirectory)

        let backups = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
        let backup = try #require(backups.first { $0.lastPathComponent.hasPrefix("pre-migration-") })
        let queue = try DatabaseQueue(path: backup.path)
        #expect(try await queue.read { try String.fetchAll($0, sql: "SELECT surface FROM vocab_suggestions") } == ["GRDB"])
    }

    @Test("候補tableが既にないDBではmigrationが失敗し、元のDBを変えない")
    func failsWithoutSuggestionsTable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-v11-fail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = try legacyDatabase(at: root)
        do {
            let legacy = try DatabaseQueue(path: databaseURL.path)
            try await legacy.write { try $0.execute(sql: "DROP TABLE vocab_suggestions") }
        }

        await #expect(throws: (any Error).self) {
            _ = try await LoreDatabase.open(fileURL: databaseURL, backupDirectory: root.appendingPathComponent("Backups"))
        }
        let queue = try DatabaseQueue(path: databaseURL.path)
        #expect(try await queue.read { try String.fetchAll($0, sql: "SELECT key FROM meta ORDER BY key") }
            == ["unrelated", "vocab_analysis_last_run", "vocab_analysis_watermark"])
    }
}
