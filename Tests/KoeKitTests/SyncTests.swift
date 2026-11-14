import CryptoKit
import Foundation
import GRDB
import Testing
@testable import KoeKit

@Suite("同期コードと暗号file")
struct SyncCryptoTests {
    @Test("同期コードは鍵へ戻り、書き写し間違いを検出する")
    func codeRoundTrip() throws {
        let key = SyncCode.generateKey()
        let code = SyncCode.encode(key)
        #expect(code.split(separator: "-").allSatisfy { $0.count <= 4 })
        let decoded = try SyncCode.decode(code.lowercased().replacingOccurrences(of: "-", with: " "))
        #expect(decoded.withUnsafeBytes { Data($0) } == key.withUnsafeBytes { Data($0) })

        var characters = Array(code)
        let index = characters.firstIndex { $0 != "-" }!
        characters[index] = characters[index] == "A" ? "B" : "A"
        #expect(throws: SyncCodeError.checksumMismatch) { try SyncCode.decode(String(characters)) }
        #expect(throws: SyncCodeError.malformed) { try SyncCode.decode("ABCD-1") }
    }

    @Test("暗号fileは同じ鍵で開け、違う鍵・改ざん・途中までのfileは拒否する")
    func sealAndOpen() throws {
        let key = SyncCode.generateKey()
        let batch = SyncBatch(records: [
            SyncRecord(entity: "memo", id: "m1", changedAt: "2026-11-14T00:00:00.000Z",
                       fields: ["id": .text("m1"), "created_at": .text("2026-11-14T00:00:00.000Z"), "text": .text("秘密のメモ")]),
        ])
        let header = SyncFileFormat.Header(device: UUID().uuidString, seq: 3)
        let sealed = try SyncFileFormat.seal(try SyncFileFormat.encode(batch), header: header, key: key)
        #expect(!String(decoding: sealed, as: UTF8.self).contains("秘密"))

        let (openedHeader, payload) = try SyncFileFormat.open(sealed, key: key)
        #expect(openedHeader == header)
        #expect(try SyncFileFormat.decode(payload) == batch)

        #expect(throws: SyncFileError.authenticationFailed) {
            try SyncFileFormat.open(sealed, key: SyncCode.generateKey())
        }
        var tampered = sealed
        tampered[tampered.count - 20] ^= 0x01
        #expect(throws: SyncFileError.authenticationFailed) { try SyncFileFormat.open(tampered, key: key) }
        // 暗号化されないheaderの書き換えも認証で検出する。
        var renamed = sealed
        let headerOffset = SyncFileFormat.magic.count + 1 + 4
        renamed[headerOffset + 2] ^= 0x01
        #expect(throws: (any Error).self) { try SyncFileFormat.open(renamed, key: key) }
        #expect(throws: SyncFileError.truncated) { try SyncFileFormat.open(sealed.prefix(30), key: key) }
        #expect(throws: SyncFileError.authenticationFailed) { try SyncFileFormat.open(sealed.dropLast(5), key: key) }
        var future = sealed
        future[SyncFileFormat.magic.count] = 9
        #expect(throws: SyncFileError.unsupportedVersion(9)) { try SyncFileFormat.open(future, key: key) }
        #expect(throws: SyncFileError.notSyncFile) { try SyncFileFormat.open(Data("hello".utf8), key: key) }
    }
}

/// 2台のMacを、in-memory DBと一時folderで模擬する。
private struct SyncPair {
    let folder: URL
    let key = SyncCode.generateKey()
    let a: KoeDatabase
    let b: KoeDatabase
    var engineA: SyncEngine { SyncEngine(database: a, folder: folder, key: key) }
    var engineB: SyncEngine { SyncEngine(database: b, folder: folder, key: key) }

    static func make(enableB: Bool = true) async throws -> SyncPair {
        let folder = FileManager.default.temporaryDirectory.appending(path: "koe-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pair = SyncPair(folder: folder, a: try await KoeDatabase.inMemory(), b: try await KoeDatabase.inMemory())
        try pair.engineA.prepareNewFolder()
        try await pair.a.sync.enable(deviceID: UUID().uuidString, folderBookmark: Data())
        if enableB {
            try pair.engineB.verifyExistingFolder()
            try await pair.b.sync.enable(deviceID: UUID().uuidString, folderBookmark: Data())
        }
        return pair
    }

    func roundTrip() async throws {
        try await engineA.export()
        try await engineB.export()
        let reportB = try await engineB.importAll()
        let reportA = try await engineA.importAll()
        #expect(reportA.failures.isEmpty && reportB.failures.isEmpty)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }
}

private func pause() async throws { try await Task.sleep(for: .milliseconds(5)) }

private func session(id: String, raw: String) -> SessionRecord {
    SessionRecord(
        id: id,
        startedAt: Date(),
        status: .completed,
        modeID: BuiltinModes.defaultModeID,
        modeSnapshot: ModeSnapshot(modeName: "Default", modePrompt: "整形", systemPrompt: "整形", vocabularyCount: 0, trigger: .toggle),
        sttEngine: .speechAnalyzer,
        llmEngine: .foundationModels,
        language: .ja,
        rawTranscript: raw,
        formattedText: raw + "。"
    )
}

@Suite("Mac間同期", .serialized)
struct SyncEngineTests {
    @Test("memoの追加・編集・削除が他のMacへ届く")
    func memoLifecycle() async throws {
        let pair = try await SyncPair.make()
        defer { pair.cleanUp() }
        let memo = LifeLogMemo(text: "請求書を送る")
        try await pair.a.lifeLog.save(memo: memo)
        try await pair.roundTrip()
        #expect(try await pair.b.lifeLog.memo(id: memo.id)?.text == "請求書を送る")
        #expect(try await pair.b.lifeLog.search("請求書").map(\.kind) == [.memo])

        try await pause()
        try await pair.b.lifeLog.updateMemo(id: memo.id, text: "請求書を金曜に送る")
        try await pair.roundTrip()
        #expect(try await pair.a.lifeLog.memo(id: memo.id)?.text == "請求書を金曜に送る")

        try await pause()
        try await pair.a.lifeLog.deleteMemo(id: memo.id)
        try await pair.roundTrip()
        #expect(try await pair.b.lifeLog.memo(id: memo.id) == nil)
        // 適用は書き出し待ちへ戻らない。
        #expect(try await pair.a.sync.pendingCount() == 0)
        #expect(try await pair.b.sync.pendingCount() == 0)
    }

    @Test("音声入力履歴、語彙、発話が届き、発話はaudioなしで検索できる")
    func historyVocabularyAndUtterances() async throws {
        let pair = try await SyncPair.make()
        defer { pair.cleanUp() }
        try await pair.a.history.save(session(id: "s1", raw: "レセコンの見積もり"))
        try await pair.a.vocabulary.save(VocabularyEntry(id: "v1", surface: "GRDB", reading: "じーあーるでーびー"))
        try await pair.a.lifeLog.save(audioChunk: LifeLogAudioChunk(
            id: "chunk", captureStartedAt: Date(), captureEndedAt: Date().addingTimeInterval(30), localPath: "/tmp/sync-test.m4a"))
        try await pair.a.lifeLog.save(utterance: LifeLogUtterance(
            id: "u1", startedAt: Date(), endedAt: Date().addingTimeInterval(3), text: "診療報酬の改定を確認", audioChunkID: "chunk"))
        try await pair.roundTrip()

        let record = try #require(try await pair.b.history.record(id: "s1"))
        #expect(record.rawTranscript == "レセコンの見積もり")
        #expect(record.formattedText == "レセコンの見積もり。")
        #expect(try await pair.b.history.search(query: "見積もり", limit: 10).map(\.id) == ["s1"])
        #expect(try await pair.b.vocabulary.all().map(\.surface) == ["GRDB"])
        let utterance = try #require(try await pair.b.lifeLog.utterance(id: "u1"))
        #expect(utterance.audioChunkID == nil)
        #expect(try await pair.b.lifeLog.search("診療報酬").map(\.id) == ["utterance-u1"])
        // 送り元のaudioとの関連は保持する。
        #expect(try await pair.a.lifeLog.utterance(id: "u1")?.audioChunkID == "chunk")
    }

    @Test("同じ項目は後から変えた方を採用する")
    func lastWriterWins() async throws {
        let pair = try await SyncPair.make()
        defer { pair.cleanUp() }
        let memo = LifeLogMemo(id: "m", text: "最初")
        try await pair.a.lifeLog.save(memo: memo)
        try await pair.roundTrip()

        try await pair.a.lifeLog.updateMemo(id: "m", text: "Aの変更")
        try await pause()
        try await pair.b.lifeLog.updateMemo(id: "m", text: "Bの後からの変更")
        // Aが先に取り込んでも、Bの方が新しい。
        try await pair.engineB.export()
        _ = try await pair.engineA.importAll()
        try await pair.engineA.export()
        _ = try await pair.engineB.importAll()
        #expect(try await pair.a.lifeLog.memo(id: "m")?.text == "Bの後からの変更")
        #expect(try await pair.b.lifeLog.memo(id: "m")?.text == "Bの後からの変更")
    }

    @Test("削除の後に届いた古い変更で復活しない")
    func tombstoneBeatsOlderUpsert() async throws {
        let pair = try await SyncPair.make()
        defer { pair.cleanUp() }
        try await pair.a.lifeLog.save(memo: LifeLogMemo(id: "m", text: "最初"))
        try await pair.roundTrip()

        try await pair.a.lifeLog.updateMemo(id: "m", text: "古い編集")
        try await pause()
        try await pair.b.lifeLog.deleteMemo(id: "m")
        try await pair.engineB.export()
        _ = try await pair.engineA.importAll()
        #expect(try await pair.a.lifeLog.memo(id: "m") == nil)
        try await pair.engineA.export()
        _ = try await pair.engineB.importAll()
        #expect(try await pair.b.lifeLog.memo(id: "m") == nil)
    }

    @Test("保持期間と一括削除はこのMacだけに適用する")
    func localOnlyDeletions() async throws {
        let pair = try await SyncPair.make()
        defer { pair.cleanUp() }
        var old = session(id: "old", raw: "古い履歴")
        old.startedAt = Date().addingTimeInterval(-40 * 86_400)
        try await pair.a.history.save(old)
        try await pair.a.history.save(session(id: "new", raw: "新しい履歴"))
        try await pair.a.lifeLog.save(memo: LifeLogMemo(id: "m", text: "残る"))
        try await pair.roundTrip()

        #expect(try await pair.a.history.purge(retentionDays: 30) == 1)
        try await pair.a.history.deleteAll()
        try await pair.a.lifeLog.deleteAll()
        #expect(try await pair.a.sync.pendingCount() == 0)
        try await pair.roundTrip()
        #expect(try await pair.b.history.count() == 2)
        #expect(try await pair.b.lifeLog.memo(id: "m") != nil)
    }

    @Test("参加前からあるdataも書き出す")
    func initialSnapshot() async throws {
        let pair = try await SyncPair.make(enableB: false)
        defer { pair.cleanUp() }
        try await pair.b.lifeLog.save(memo: LifeLogMemo(id: "before", text: "参加前のメモ"))
        // 無効の間は記録しない。
        #expect(try await pair.b.sync.pendingCount() == 0)
        try pair.engineB.verifyExistingFolder()
        try await pair.b.sync.enable(deviceID: UUID().uuidString, folderBookmark: Data())
        #expect(try await pair.b.sync.pendingCount() == 1)
        try await pair.roundTrip()
        #expect(try await pair.a.lifeLog.memo(id: "before")?.text == "参加前のメモ")
    }

    @Test("違う同期コードとfolderの取り違えを拒否する")
    func joinValidation() async throws {
        let pair = try await SyncPair.make(enableB: false)
        defer { pair.cleanUp() }
        let wrong = SyncEngine(database: pair.b, folder: pair.folder, key: SyncCode.generateKey())
        #expect(throws: SyncEngineError.wrongCode) { try wrong.verifyExistingFolder() }
        #expect(throws: SyncEngineError.folderAlreadyUsed) { try wrong.prepareNewFolder() }
        let empty = FileManager.default.temporaryDirectory.appending(path: "koe-sync-empty-\(UUID().uuidString)")
        #expect(throws: SyncEngineError.folderNotInitialized) {
            try SyncEngine(database: pair.b, folder: empty, key: pair.key).verifyExistingFolder()
        }
    }

    @Test("読めないfileで止まり、正しいfileが届けば続きから取り込む")
    func cursorWaitsOnBrokenFile() async throws {
        let pair = try await SyncPair.make()
        defer { pair.cleanUp() }
        try await pair.a.lifeLog.save(memo: LifeLogMemo(id: "m1", text: "一つ目"))
        try await pair.engineA.export()
        try await pair.a.lifeLog.save(memo: LifeLogMemo(id: "m2", text: "二つ目"))
        try await pair.engineA.export()

        let deviceA = try #require(try await pair.a.sync.control().deviceID)
        let first = pair.engineA.devicesDirectory.appending(path: deviceA).appending(path: SyncEngine.fileName(1))
        let original = try Data(contentsOf: first)
        try original.prefix(original.count / 2).write(to: first)

        let report = try await pair.engineB.importAll()
        #expect(report.failures.count == 1)
        #expect(try await pair.b.sync.cursor(for: deviceA) == 0)
        #expect(try await pair.b.lifeLog.memo(id: "m2") == nil)

        try original.write(to: first)
        let retry = try await pair.engineB.importAll()
        #expect(retry.failures.isEmpty)
        #expect(try await pair.b.sync.cursor(for: deviceA) == 2)
        #expect(try await pair.b.lifeLog.memo(id: "m1") != nil)
        #expect(try await pair.b.lifeLog.memo(id: "m2") != nil)
    }

    @Test("書き込み後にDB更新できなくても番号を再利用しない")
    func sequenceNeverReused() async throws {
        let pair = try await SyncPair.make()
        defer { pair.cleanUp() }
        try await pair.a.lifeLog.save(memo: LifeLogMemo(id: "m1", text: "一つ目"))
        try await pair.engineA.export()
        let deviceA = try #require(try await pair.a.sync.control().deviceID)
        // file書き込み直後にcrashし、DBの次番号だけ戻った状態。
        try await pair.a.queue.write { db in try db.execute(sql: "UPDATE sync_control SET next_seq = 1") }
        try await pair.a.lifeLog.save(memo: LifeLogMemo(id: "m2", text: "二つ目"))
        try await pair.engineA.export()
        let names = try FileManager.default.contentsOfDirectory(
            atPath: pair.engineA.devicesDirectory.appending(path: deviceA).path).sorted()
        #expect(names == [SyncEngine.fileName(1), SyncEngine.fileName(2)])
        _ = try await pair.engineB.importAll()
        #expect(try await pair.b.lifeLog.memo(id: "m2") != nil)
    }

    @Test("同期の解除と全データ削除は同期状態を消し、変更を記録しない")
    func disableClearsState() async throws {
        let pair = try await SyncPair.make()
        defer { pair.cleanUp() }
        try await pair.a.lifeLog.save(memo: LifeLogMemo(id: "m", text: "記録"))
        try await pair.a.sync.disable()
        #expect(try await pair.a.sync.control() == SyncControlState(enabled: false, nextSeq: 1))
        try await pair.a.lifeLog.save(memo: LifeLogMemo(id: "m2", text: "解除後"))
        #expect(try await pair.a.sync.pendingCount() == 0)

        try await pair.b.lifeLog.save(memo: LifeLogMemo(id: "b", text: "B"))
        try await pair.b.deleteAllUserData()
        #expect(try await pair.b.sync.control().enabled == false)
        #expect(try await pair.b.sync.pendingCount() == 0)
    }
}

@Test func syncMigrationKeepsUtterancesAndAllowsMissingAudio() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-v10-test-\(UUID().uuidString)")
    let databaseURL = root.appendingPathComponent("koe.sqlite")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let legacy = try DatabaseQueue(path: databaseURL.path)
        try KoeDatabase.migrator.migrate(legacy, upTo: "v9-remove-todo-summary-usage")
        try await legacy.write { db in
            try db.execute(sql: """
                INSERT INTO life_log_audio_chunks (id, capture_started_at, capture_ended_at, local_path, transcription_state, processing_state)
                  VALUES ('audio', '2026-08-29T09:00:00.000Z', '2026-08-29T09:00:30.000Z', '/tmp/v10.m4a', 'transcribed', 'extracted');
                INSERT INTO life_log_utterances VALUES ('utterance', '2026-08-29T09:00:01.000Z', '2026-08-29T09:00:05.000Z',
                  'レセコンの移行を相談した', 'audio', NULL);
                """)
        }
    }

    let database = try await KoeDatabase.open(fileURL: databaseURL, backupDirectory: root.appendingPathComponent("Backups"))
    #expect(try await database.lifeLog.search("レセコン").map(\.id) == ["utterance-utterance"])
    #expect(try await database.lifeLog.utterances(audioChunkID: "audio").map(\.id) == ["utterance"])
    try await database.lifeLog.save(utterance: LifeLogUtterance(
        id: "remote", startedAt: Date(), endedAt: Date(), text: "別のMacの発話", audioChunkID: nil))
    #expect(try await database.lifeLog.search("別のMac").map(\.id) == ["utterance-remote"])
    #expect(try await database.sync.control().enabled == false)
    #expect(try await database.sync.pendingCount() == 0)
}
