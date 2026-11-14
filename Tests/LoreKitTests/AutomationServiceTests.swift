import Foundation
import Testing

@testable import LoreKit

@Suite("CLI/MCP共通のライフログ取得")
@MainActor
struct AutomationServiceTests {
    private let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return value
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
    }

    private func makeService() async throws -> LoreAutomationService {
        let defaults = UserDefaults(suiteName: "lore-automation-\(UUID().uuidString)")!
        return LoreAutomationService(
            database: try await LoreDatabase.inMemory(),
            settings: AppSettings(defaults: defaults)
        )
    }

    /// 8/25: 発話（音声入力と重なる）と音声入力、参加しない予定。8/27: memoと参加する2日間の予定。
    private func seed(_ database: LoreDatabase) async throws {
        let chunk = LifeLogAudioChunk(id: "audio", captureStartedAt: at(25, 9), captureEndedAt: at(25, 10), localPath: "/tmp/a.m4a")
        try await database.lifeLog.save(audioChunk: chunk)
        try await database.lifeLog.save(utterance: LifeLogUtterance(
            id: "hidden", startedAt: at(25, 9, 1), endedAt: at(25, 9, 2), text: "重複", audioChunkID: chunk.id
        ))
        try await database.lifeLog.save(utterance: LifeLogUtterance(
            id: "spoken", startedAt: at(25, 9, 30), endedAt: at(25, 9, 31), text: "設計を見直す", audioChunkID: chunk.id
        ))
        let snapshot = ModeSnapshot(modeName: "標準", modePrompt: "", systemPrompt: "", vocabularyCount: 0, trigger: .manual)
        try await database.history.save(SessionRecord(
            id: "dictation", startedAt: at(25, 9), endedAt: at(25, 9, 5), status: .completed,
            modeSnapshot: snapshot, sttEngine: EngineIdentifier("speech-analyzer"),
            rawTranscript: "重複", formattedText: "重複", audioDurationMs: 180_000
        ))
        try await database.lifeLog.save(calendarEvents: [
            CalendarEventSnapshot(id: "declined", title: "断った会議", startsAt: at(25, 13), endsAt: at(25, 14),
                                  calendarTitle: "Work", participationStatus: .declined),
            CalendarEventSnapshot(id: "offsite", title: "合宿", startsAt: at(27, 10), endsAt: at(28, 17),
                                  calendarTitle: "Work", participationStatus: .accepted),
        ])
        try await database.lifeLog.save(memo: LifeLogMemo(id: "memo", createdAt: at(27, 18), text: "合宿の振り返り"))
    }

    @Test("記録がある日だけを件数と発話秒数つきで返す")
    func daysListOnlyRecordedDays() async throws {
        let service = try await makeService()
        try await seed(service.database)

        let days = try await service.days(from: at(24, 0), to: at(30, 0), calendar: calendar)
        #expect(days.map(\.day) == ["2026-08-25", "2026-08-27", "2026-08-28"])
        let first = try #require(days.first)
        // 音声入力と重なる発話は数えず、参加しない予定も含めない。
        #expect(first.utterances == 1)
        #expect(first.dictations == 1)
        #expect(first.events == 0)
        #expect(first.spokenSeconds == 60)
        #expect(days[1].memos == 1)
        #expect(days[1].events == 1)
    }

    @Test("日一覧は既定で今日までの30日間を読み、上限を超える期間を拒否する")
    func daysDefaultsAndLimits() async throws {
        let service = try await makeService()
        // 8/30までの30日間は8/1から。7/31は含めない。
        try await service.database.lifeLog.save(memo: LifeLogMemo(createdAt: at(1, 9).addingTimeInterval(-86_400), text: "古い"))
        try await service.database.lifeLog.save(memo: LifeLogMemo(createdAt: at(1, 9), text: "境界"))
        try await service.database.lifeLog.save(memo: LifeLogMemo(createdAt: at(30, 9), text: "新しい"))

        let recent = try await service.days(now: at(30, 12), calendar: calendar)
        #expect(recent.map(\.day) == ["2026-08-01", "2026-08-30"])
        await #expect(throws: AutomationError.self) {
            _ = try await service.days(from: at(30, 0), to: at(1, 0), calendar: calendar)
        }
        let start = calendar.date(byAdding: .day, value: -400, to: at(30, 0))!
        await #expect(throws: AutomationError.self) {
            _ = try await service.days(from: start, to: at(30, 0), calendar: calendar)
        }
    }

    @Test("期間の項目を時刻順に返し、画面と同じprojectionと予定filterを使う")
    func rangeReturnsOrderedProjectedEntries() async throws {
        let service = try await makeService()
        try await seed(service.database)

        let entries = try await service.range(from: at(25, 0), to: at(28, 0), calendar: calendar)
        #expect(entries.map(\.id) == ["dictation", "spoken", "offsite", "memo"])
        #expect(entries.map(\.kind) == [.dictation, .utterance, .event, .memo])
        let event = entries[2]
        #expect(event.title == "合宿")
        #expect(event.calendar == "Work")
        #expect(event.allDay == false)
        #expect(event.day == "2026-08-27")
        #expect(entries[3].end == nil)
        #expect(LifeLogEntry.parseTimestamp(entries[1].start) == at(25, 9, 30))

        let json = try LifeLogJSON.encode(entries)
        #expect(json.contains("\"kind\" : \"utterance\""))
        #expect(!json.contains("\\/"))
    }

    @Test("期間取得は種類を選べ、空選択・逆順・31日超をerrorにする")
    func rangeFiltersAndValidates() async throws {
        let service = try await makeService()
        try await seed(service.database)

        let memos = try await service.range(
            from: at(25, 0), to: at(28, 0),
            options: .init(includesCalendarEvents: false, includesUtterances: false, includesDictations: false, includesMemos: true),
            calendar: calendar
        )
        #expect(memos.map(\.id) == ["memo"])
        let single = try await service.range(from: at(26, 0), calendar: calendar)
        #expect(single.isEmpty)

        await #expect(throws: AutomationError.self) {
            _ = try await service.range(
                from: at(25, 0),
                options: .init(includesCalendarEvents: false, includesUtterances: false, includesDictations: false, includesMemos: false),
                calendar: calendar
            )
        }
        await #expect(throws: AutomationError.self) {
            _ = try await service.range(from: at(28, 0), to: at(25, 0), calendar: calendar)
        }
        let tooLong = calendar.date(byAdding: .day, value: 31, to: at(1, 0))!
        await #expect(throws: AutomationError.self) {
            _ = try await service.range(from: at(1, 0), to: tooLong, calendar: calendar)
        }
        let edge = calendar.date(byAdding: .day, value: 30, to: at(1, 0))!
        _ = try await service.range(from: at(1, 0), to: edge, calendar: calendar)
    }

    @Test("ISO8601は時差付きと小数秒付きを受け付ける")
    func parsesTimestamps() {
        #expect(LifeLogEntry.parseTimestamp("2026-08-29T18:00:00+09:00") == at(29, 18))
        #expect(LifeLogEntry.parseTimestamp("2026-08-29T09:00:00.500Z") == at(29, 18).addingTimeInterval(0.5))
        #expect(LifeLogEntry.parseTimestamp("2026-08-29") == nil)
        #expect(LifeLogEntry.timestamp(at(29, 18), timeZone: calendar.timeZone) == "2026-08-29T18:00:00+09:00")
    }
}

@Suite("memo編集")
struct MemoEditingTests {
    @Test("本文だけを更新し、作成時刻を保つ。存在しないmemoはerror")
    func storeUpdatesTextOnly() async throws {
        let database = try await LoreDatabase.inMemory()
        let createdAt = Date(timeIntervalSince1970: 1_777_777_700)
        try await database.lifeLog.save(memo: LifeLogMemo(id: "m", createdAt: createdAt, text: "旧"))

        try await database.lifeLog.updateMemo(id: "m", text: "新しい本文")
        let memo = try #require(try await database.lifeLog.memo(id: "m"))
        #expect(memo.text == "新しい本文")
        #expect(memo.createdAt == createdAt)
        #expect(try await database.lifeLog.search("新しい本文").map(\.id) == ["memo-m"])
        await #expect(throws: LifeLogStoreError.self) {
            try await database.lifeLog.updateMemo(id: "missing", text: "x")
        }
    }

    @Test("coordinatorは空の本文を保存せず、更新後にtimelineを再読込する")
    @MainActor
    func coordinatorRejectsEmptyAndReloads() async throws {
        let database = try await LoreDatabase.inMemory()
        let coordinator = LifeLogCoordinator()
        try await database.lifeLog.save(memo: LifeLogMemo(id: "m", createdAt: Date(), text: "旧"))
        await coordinator.configure(
            database: database,
            engines: EngineRegistry(),
            vocabulary: { [] },
            participatingEventsOnly: { true },
            audioProcessingCompleted: {}
        )

        #expect(await coordinator.updateMemo(id: "m", text: "  ") == false)
        #expect(coordinator.day.memos.first?.text == "旧")
        #expect(await coordinator.updateMemo(id: "m", text: " 新 ") == true)
        #expect(coordinator.day.memos.first?.text == "新")
        #expect(await coordinator.updateMemo(id: "missing", text: "x") == false)
        #expect(coordinator.errorMessage != nil)
    }
}
