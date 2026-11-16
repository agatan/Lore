import Foundation
import GRDB
import Synchronization
import Testing
@testable import LoreKit

private final class DigestSpy: LlmEngine {
    let identifier = EngineIdentifier.ollama
    let modelName: String? = "spy-model"
    let inputCharacterBudget: Int
    private let recorded = Mutex<[FormattingPrompt]>([])

    init(budget: Int = 24_000) { inputCharacterBudget = budget }

    static let response = """
        SUMMARY (S1, S2): Planned the release and wrote the release note
        SUMMARY (): An invented line
        DECIDE (S2): Ship the beta on Friday
        COMMIT (S2): Write the release note
        ASK (S2) [Aki]: Review the release note
        COMMIT (S99): Prepare the invoice
        """

    var prompts: [FormattingPrompt] { recorded.withLock { $0 } }
    func availability() async -> EngineAvailability { .ready }
    func complete(prompt: FormattingPrompt, timeout: Duration) async throws -> String {
        recorded.withLock { $0.append(prompt) }
        return Self.response
    }
    func unload() async {}
}

private let longText = String(repeating: "We agreed to ship the beta on Friday and Aki writes the release note. ", count: 3)

private func at(_ day: Date, _ hour: Double) -> Date { day.addingTimeInterval(hour * 3600) }

@MainActor
private final class DigestHarness {
    let database: LoreDatabase
    let today = Calendar.current.startOfDay(for: Date())
    var yesterday: Date { Calendar.current.date(byAdding: .day, value: -1, to: today)! }
    var now: Date
    var settings = LifeLogAISettings()
    var schedule = LifeLogSchedule()
    var spy: DigestSpy
    var engineCalls = 0
    var backlog: Date?
    var excludedCalendarEvents: [CalendarEventSnapshot] = []
    var saved: [(GeneratedNote, Bool)] = []
    lazy var service = makeService()

    init(budget: Int = 24_000) async throws {
        database = try await LoreDatabase.inMemory()
        now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(19 * 3600)
        spy = DigestSpy(budget: budget)
        settings.isEnabled = true
        settings.backend = .ollama
    }

    func makeService() -> LifeLogAIService {
        LifeLogAIService(dependencies: .init(
            settings: { [unowned self] in settings },
            database: { [unowned self] in database },
            engine: { [unowned self] _, _ in
                engineCalls += 1
                return spy
            },
            oldestUntranscribedAudio: { [unowned self] in backlog },
            excludedCalendarEvents: { [unowned self] _, calendars in excludedCalendarEvents.filter { calendars.contains($0.calendarTitle) } },
            lifeLogSchedule: { [unowned self] in schedule },
            noteSaved: { [unowned self] note, _, automatic in saved.append((note, automatic)) },
            now: { [unowned self] in now }
        ))
    }

    /// An event with speech inside, speech after it, and a memo, on `day`.
    func seedDay(_ day: Date, prefix: String = "", speech: String = longText) async throws {
        let event = CalendarEventSnapshot(id: "\(prefix)event", title: "Release planning", startsAt: at(day, 10), endsAt: at(day, 11), calendarTitle: "Work")
        try await database.lifeLog.save(calendarEvents: [event])
        try await database.lifeLog.save(utterance: LifeLogUtterance(id: "\(prefix)u-in", startedAt: at(day, 10.1), endedAt: at(day, 10.2), text: speech, audioChunkID: nil))
        try await database.lifeLog.save(utterance: LifeLogUtterance(id: "\(prefix)u-after", startedAt: at(day, 14), endedAt: at(day, 14.1), text: speech, audioChunkID: nil))
        try await database.lifeLog.save(memo: LifeLogMemo(id: "\(prefix)m1", createdAt: at(day, 15), text: "Release note owner: Aki"))
    }

    func scope(_ day: Date) -> GeneratedNoteScope { .day(LifeLogDateKey.string(for: day)) }
    func digest(_ day: Date) async throws -> GeneratedNote? { try await database.lifeLog.generatedNote(kind: .dailyDigest, scope: scope(day)) }
}

@MainActor
@Suite("Daily digest")
struct DailyDigestTests {
    // MARK: Digest time

    @Test("The digest time is the end of the scheduled window that starts on the day, otherwise the set time")
    func digestTime() throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: day)
        #expect(DailyDigestTrigger.digestTime(for: day, schedule: LifeLogSchedule(), minute: 18 * 60) == at(day, 18))
        let scheduled = LifeLogSchedule(isEnabled: true, weekdays: [weekday], startMinute: 9 * 60, endMinute: 17 * 60 + 30)
        #expect(DailyDigestTrigger.digestTime(for: day, schedule: scheduled, minute: 18 * 60) == at(day, 17.5))
        let otherDays = LifeLogSchedule(isEnabled: true, weekdays: Set(1...7).subtracting([weekday]), startMinute: 9 * 60, endMinute: 17 * 60)
        #expect(DailyDigestTrigger.digestTime(for: day, schedule: otherDays, minute: 20 * 60) == at(day, 20))
        let overnight = LifeLogSchedule(isEnabled: true, weekdays: [weekday], startMinute: 22 * 60, endMinute: 2 * 60)
        let next = try #require(calendar.date(byAdding: .day, value: 1, to: day))
        #expect(DailyDigestTrigger.digestTime(for: day, schedule: overnight, minute: 18 * 60) == calendar.date(bySettingHour: 2, minute: 0, second: 0, of: next))
    }

    // MARK: Trigger

    @Test("The trigger generates only for today or yesterday, after the digest time, once, and with enough speech")
    func triggerTable() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let twoDaysAgo = try #require(calendar.date(byAdding: .day, value: -2, to: today))
        var on = LifeLogAISettings()
        on.isEnabled = true
        var manual = on
        manual.dailyDigestTrigger = .manual
        let now = at(today, 19)
        func decide(day: Date = today, now: Date = now, time: Date? = nil, settings: LifeLogAISettings = on, hasDigest: Bool = false,
                    deleted: Bool = false, spoken: Int = 400, backlog: Date? = nil) -> GenerationDecision {
            DailyDigestTrigger.decide(day: day, now: now, digestTime: time ?? at(calendar.startOfDay(for: day), 18), settings: settings,
                                      hasDigest: hasDigest, wasDeleted: deleted, spokenCharacters: spoken, oldestUntranscribedAudio: backlog)
        }
        #expect(decide() == .generate)
        #expect(decide(settings: LifeLogAISettings()) == .skip(.notAllowed))
        #expect(decide(settings: manual) == .skip(.manualTrigger))
        #expect(decide(now: at(today, 9)) == .waitUntil(at(today, 18)))
        #expect(decide(day: yesterday, now: at(today, 9)) == .generate)
        #expect(decide(day: twoDaysAgo) == .skip(.outsideLookBack))
        #expect(decide(hasDigest: true) == .skip(.alreadyGenerated))
        #expect(decide(deleted: true) == .skip(.deletedByUser))
        #expect(decide(spoken: DailyDigestPolicy.minimumSpokenCharacters - 1) == .skip(.tooLittleSpeech))
        #expect(decide(backlog: at(today, 17)) == .waitForTranscription)
        #expect(decide(backlog: at(today, 18.5)) == .generate)
    }

    // MARK: Reduction rule

    @Test("Kinds give way in order, the first kind that does not fit is thinned to every k-th record, and the rest is counted")
    func reductionRule() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func source(_ kind: GeneratedNoteSource.Kind, _ index: Int) -> GeneratedNoteSource {
            GeneratedNoteSource(kind: kind, timelineID: "\(kind.rawValue)-\(index)", recordID: "\(index)", at: base.addingTimeInterval(Double(index) * 60), text: "")
        }
        let sources = [source(.event, 0), source(.memo, 1)] + (2...7).map { source(.utterance, $0) }
        let cost: (GeneratedNoteSource) -> Int = { _ in 10 }

        let whole = DailyDigestPolicy.reduce(sources, budget: 80, cost: cost)
        #expect(whole.omitted == 0)
        #expect(whole.sent.map(\.label) == (1...8).map { "S\($0)" })

        let thinned = DailyDigestPolicy.reduce(sources, budget: 50, cost: cost)
        #expect(thinned.sent.map(\.timelineID) == ["event-0", "memo-1", "utterance-2", "utterance-4", "utterance-6"])
        #expect(thinned.sent.map(\.label) == ["S1", "S2", "S3", "S4", "S5"])
        #expect(thinned.omitted == 3)

        let tight = DailyDigestPolicy.reduce(sources, budget: 15, cost: cost)
        #expect(tight.sent.map(\.timelineID) == ["event-0"])
        #expect(tight.omitted == 7)
    }

    @Test("A day longer than the provider's limit is reduced, sends less than the limit, and stores the omitted count")
    func longDayStoresOmittedCount() async throws {
        let harness = try await DigestHarness(budget: DailyDigestPolicy.instructions.count + 400)
        try await harness.seedDay(harness.today)
        for index in 0..<20 {
            let start = at(harness.today, 16 + Double(index) / 60)
            try await harness.database.lifeLog.save(utterance: LifeLogUtterance(id: "extra-\(index)", startedAt: start, endedAt: start.addingTimeInterval(20), text: "Extra line \(index) about the beta", audioChunkID: nil))
        }
        let note = try await harness.service.generate(kind: .dailyDigest, scope: harness.scope(harness.today))
        let prompt = try #require(harness.spy.prompts.first)
        #expect(prompt.system.count + prompt.user.count <= harness.spy.inputCharacterBudget)
        #expect(note.omittedSourceCount > 0)
        #expect(try await harness.digest(harness.today)?.omittedSourceCount == note.omittedSourceCount)
        #expect(GeneratedNoteMarkdown.render(note, title: "").contains("\(note.omittedSourceCount)件の記録を省きました"))
    }

    // MARK: Input

    @Test("Excluded events and calendars contribute nothing, declined events are not listed, and fresh event notes replace utterances")
    func inputExclusionsAndReplacement() {
        let day = Calendar.current.startOfDay(for: Date())
        let noted = CalendarEventSnapshot(id: "noted", title: "Noted meeting", startsAt: at(day, 9), endsAt: at(day, 10), calendarTitle: "Work")
        let excluded = CalendarEventSnapshot(id: "excluded", title: "SECRET-EVENT", startsAt: at(day, 11), endsAt: at(day, 12), calendarTitle: "Work")
        let privateCalendar = CalendarEventSnapshot(id: "private", title: "PRIVATE-EVENT", startsAt: at(day, 13), endsAt: at(day, 14), calendarTitle: "Private")
        let declined = CalendarEventSnapshot(id: "declined", title: "DECLINED-EVENT", startsAt: at(day, 15), endsAt: at(day, 16), calendarTitle: "Work", participationStatus: .declined)
        let note = GeneratedNote(kind: .eventNotes, scope: .event(EventOccurrence(noted)), rangeStart: noted.startsAt, rangeEnd: noted.endsAt,
                                 backend: .ollama, model: "m", createdAt: noted.endsAt, sourceUtteranceIDs: ["u-noted"], sourceMemoIDs: [],
                                 sections: [GeneratedNoteSection(kind: .decisions, items: [GeneratedNoteItem(text: "Ship on Friday", sources: ["u-u-noted"])])])
        func utterance(_ id: String, _ hour: Double, _ text: String) -> LifeLogUtterance {
            LifeLogUtterance(id: id, startedAt: at(day, hour), endedAt: at(day, hour + 0.01), text: text, audioChunkID: nil)
        }
        let contents = LifeLogDay(
            utterances: [utterance("u-noted", 9.5, "RAW-NOTED"), utterance("u-excluded", 11.5, "SECRET-SPEECH"),
                         utterance("u-private", 13.5, "PRIVATE-SPEECH"), utterance("u-declined", 15.5, "declined speech"), utterance("u-free", 17, "free speech")],
            memos: [LifeLogMemo(id: "m-excluded", createdAt: at(day, 11.2), text: "SECRET-MEMO")],
            calendarEvents: [noted, excluded, privateCalendar, declined],
            generatedNotes: [note]
        )
        var settings = LifeLogAISettings()
        settings.excludedCalendars = ["Private"]
        let input = DailyDigestPolicy.input(dayKey: LifeLogDateKey.string(for: day), day: contents,
                                            listedEvents: [noted, excluded, privateCalendar], settings: settings,
                                            excludedEventIDs: ["excluded"], excludedCalendarEvents: [privateCalendar])
        let text = input.sources.map(\.text).joined(separator: "\n")
        for secret in ["SECRET", "PRIVATE", "DECLINED-EVENT", "RAW-NOTED"] {
            #expect(!text.contains(secret), "\(secret) must not be sent")
        }
        #expect(text.contains("Noted meeting / decision: Ship on Friday"))
        #expect(text.contains("declined speech") && text.contains("free speech"))
        #expect(input.spokenCharacters == ["RAW-NOTED", "declined speech", "free speech"].reduce(0) { $0 + $1.count })

        var stale = note
        stale.staleReasons = [.sourcesDeleted]
        var staleContents = contents
        staleContents.generatedNotes = [stale]
        let fallback = DailyDigestPolicy.input(dayKey: LifeLogDateKey.string(for: day), day: staleContents, listedEvents: [noted],
                                               settings: settings, excludedEventIDs: ["excluded"], excludedCalendarEvents: [privateCalendar])
        #expect(fallback.sources.contains { $0.text == "RAW-NOTED" })
        #expect(!fallback.sources.contains { $0.kind == .note })
    }

    @Test("An excluded all-day event covers the day, so the day gets no digest")
    func allDayExclusionBlocksDigest() async throws {
        let harness = try await DigestHarness()
        try await harness.seedDay(harness.today)
        let allDay = CalendarEventSnapshot(id: "holiday", title: "Off", startsAt: harness.today, endsAt: at(harness.today, 24), calendarTitle: "Private", isAllDay: true)
        harness.excludedCalendarEvents = [allDay]
        harness.settings.excludedCalendars = ["Private"]
        await harness.service.evaluateDailyDigest()
        #expect(harness.engineCalls == 0)
        #expect(try await harness.digest(harness.today) == nil)
    }

    // MARK: Service

    @Test("One digest per day: it waits for the digest time, and reruns and relaunches never send again")
    func oneDigestPerDay() async throws {
        let harness = try await DigestHarness()
        try await harness.seedDay(harness.today)
        harness.now = at(harness.today, 17)
        await harness.service.evaluateDailyDigest()
        #expect(harness.engineCalls == 0)

        harness.now = at(harness.today, 19)
        await harness.service.evaluateDailyDigest()
        await harness.service.evaluateDailyDigest()
        harness.service = harness.makeService()
        await harness.service.evaluateDailyDigest()
        #expect(harness.spy.prompts.count == 1)
        #expect(harness.saved.map(\.1) == [true])

        let digest = try #require(try await harness.digest(harness.today))
        #expect(digest.items(.summary).map(\.text) == ["Planned the release and wrote the release note"])
        #expect(digest.items(.commitments).map(\.text) == ["Write the release note"])
        #expect(digest.items(.requests).first?.owner == "Aki")
        #expect(digest.items(.decisions).count == 1, "an item citing an unknown label is dropped from the commitments")
        #expect(digest.rangeStart == harness.today)

        let regenerated = try await harness.service.generate(kind: .dailyDigest, scope: harness.scope(harness.today))
        let rows = try await harness.database.lifeLog.generatedNotes(fromDay: LifeLogDateKey.string(for: harness.today), throughDay: LifeLogDateKey.string(for: harness.today))
        #expect(rows.filter { $0.kind == .dailyDigest }.map(\.id) == [regenerated.id])
        #expect(harness.saved.map(\.1) == [true, false])
    }

    @Test("A day with too little speech gets no digest and no notification")
    func tooLittleSpeech() async throws {
        let harness = try await DigestHarness()
        try await harness.seedDay(harness.today, speech: "Short.")
        await harness.service.evaluateDailyDigest()
        #expect(harness.engineCalls == 0)
        #expect(harness.saved.isEmpty)
        await #expect(throws: LifeLogAIService.GenerationError.tooLittleSpeech) {
            try await harness.service.generate(kind: .dailyDigest, scope: harness.scope(harness.today))
        }
        #expect(harness.spy.prompts.isEmpty)
    }

    @Test("A missed digest time is caught up at the next launch for yesterday only")
    func catchUpYesterdayOnly() async throws {
        let harness = try await DigestHarness()
        let twoDaysAgo = try #require(Calendar.current.date(byAdding: .day, value: -2, to: harness.today))
        try await harness.seedDay(harness.yesterday, prefix: "y-")
        try await harness.seedDay(twoDaysAgo, prefix: "old-")
        try await harness.seedDay(harness.today, prefix: "t-")
        harness.now = at(harness.today, 8)
        await harness.service.evaluateDailyDigest()
        #expect(harness.spy.prompts.count == 1)
        #expect(try await harness.digest(harness.yesterday) != nil)
        #expect(try await harness.digest(twoDaysAgo) == nil)
        #expect(try await harness.digest(harness.today) == nil)
        let prompt = try #require(harness.spy.prompts.first)
        #expect(prompt.user.contains("Day: \(LifeLogDateKey.string(for: harness.yesterday))"))
    }

    @Test("Pending transcription before the digest time holds the digest back")
    func waitsForTranscription() async throws {
        let harness = try await DigestHarness()
        try await harness.seedDay(harness.today)
        harness.backlog = at(harness.today, 17.9)
        await harness.service.evaluateDailyDigest()
        #expect(harness.engineCalls == 0)
        harness.backlog = nil
        await harness.service.evaluateDailyDigest()
        #expect(harness.spy.prompts.count == 1)
    }

    @Test("A digest the user deleted is not made again automatically, and Create Digest still works")
    func deletedStaysDeleted() async throws {
        let harness = try await DigestHarness()
        try await harness.seedDay(harness.today)
        await harness.service.evaluateDailyDigest()
        await harness.service.deleteNote(try #require(try await harness.digest(harness.today)))
        await harness.service.evaluateDailyDigest()
        #expect(harness.spy.prompts.count == 1)
        #expect(try await harness.digest(harness.today) == nil)
        try await harness.service.generate(kind: .dailyDigest, scope: harness.scope(harness.today))
        #expect(try await harness.digest(harness.today) != nil)
    }

    @Test("The prompt holds only that day's events, memos, and utterances, and the digest is marked when a source is deleted")
    func promptAndStaleness() async throws {
        let harness = try await DigestHarness()
        try await harness.seedDay(harness.today)
        try await harness.database.lifeLog.save(utterance: LifeLogUtterance(id: "other-day", startedAt: at(harness.yesterday, 12), endedAt: at(harness.yesterday, 12.1), text: "OTHER-DAY", audioChunkID: nil))
        try await harness.service.generate(kind: .dailyDigest, scope: harness.scope(harness.today))
        let prompt = try #require(harness.spy.prompts.first)
        #expect(prompt.user.contains("event: Release planning"))
        #expect(prompt.user.contains("memo: Release note owner: Aki"))
        #expect(!prompt.user.contains("OTHER-DAY"))
        #expect(!prompt.user.contains("Work"))

        try await harness.database.lifeLog.deleteMemo(id: "m1")
        #expect(try await harness.digest(harness.today)?.staleReasons == [.sourcesDeleted])
    }

    // MARK: Search, notification, morning sheet

    @Test("Search finds the digest and event notes, labels them as generated, opens them in place, and forgets deleted ones")
    func searchLabelsGenerated() async throws {
        let harness = try await DigestHarness()
        try await harness.seedDay(harness.today)
        let digest = try await harness.service.generate(kind: .dailyDigest, scope: harness.scope(harness.today))
        let event = CalendarEventSnapshot(id: "event", title: "Release planning", startsAt: at(harness.today, 10), endsAt: at(harness.today, 11), calendarTitle: "Work")
        try await harness.database.lifeLog.save(generatedNote: GeneratedNote(
            kind: .eventNotes, scope: .event(EventOccurrence(event)), rangeStart: event.startsAt, rangeEnd: event.endsAt, backend: .ollama, model: "m",
            createdAt: event.endsAt, sourceUtteranceIDs: [], sourceMemoIDs: [],
            sections: [GeneratedNoteSection(kind: .commitments, items: [GeneratedNoteItem(text: "Freeze the scope on Thursday", sources: ["u-u-in"])])]
        ))

        let results = try await harness.database.lifeLog.search("wrote the release")
        #expect(results.map(\.kind) == [.generated])
        #expect(results.first?.timelineItemID == GeneratedNoteScope.digestTimelineItemID)
        #expect(results.first?.day == LifeLogDateKey.string(for: harness.today))
        #expect(try await harness.database.lifeLog.search("Friday").first { $0.kind == .generated }?.text == "Ship the beta on Friday")
        #expect(LifeLogSearchResult.Kind.generated.displayName == "AIが生成")
        let eventResult = try #require(try await harness.database.lifeLog.search("Freeze").first)
        #expect(eventResult.kind == .generated && eventResult.timelineItemID == EventOccurrence(event).timelineItemID)
        #expect(try await harness.database.lifeLog.search("Fr").contains { $0.id == eventResult.id })

        await harness.service.deleteNote(digest)
        #expect(try await harness.database.lifeLog.search("wrote the release").isEmpty)
    }

    @Test("The CLI and MCP return the digest as generated, without an event, with its omitted count, and search labels it")
    func automationOutput() async throws {
        let harness = try await DigestHarness()
        try await harness.seedDay(harness.today)
        try await harness.service.generate(kind: .dailyDigest, scope: harness.scope(harness.today))
        let service = LoreAutomationService(database: harness.database, settings: AppSettings(defaults: UserDefaults(suiteName: "lore-digest-\(UUID())")!))
        let entry = try #require(try await service.aiNotes(from: harness.today, to: harness.today).first { $0.kind == "daily_digest" })
        #expect(entry.generated && entry.eventId == nil && entry.omittedSources == 0)
        #expect(entry.sections.map(\.kind) == ["summary", "commitments", "requests", "decisions"])
        let json = try LifeLogJSON.encode([entry])
        #expect(json.contains("\"omittedSources\" : 0") && !json.contains("eventId"))
        #expect(try await service.search("wrote the release").map(\.kind.rawValue) == ["generated"])
    }

    @Test("The notification carries the talk time and the event and memo counts")
    func notificationNumbers() {
        let day = Calendar.current.startOfDay(for: Date())
        let contents = LifeLogDay(
            utterances: [LifeLogUtterance(id: "a", startedAt: at(day, 9), endedAt: at(day, 9) + 125 * 60, text: "x", audioChunkID: nil)],
            memos: (0..<4).map { LifeLogMemo(id: "m\($0)", createdAt: at(day, 10), text: "m") }
        )
        let body = DailyDigestNotification.body(LifeLogDaySummary(day: contents), events: 7)
        #expect(body.contains(DailyDigestNotification.duration(125 * 60)))
        #expect(body.contains("7") && body.contains("4"))
        #expect(DailyDigestNotification.duration(125 * 60) == String(lore: "\(2)時間\(5)分"))
        #expect(DailyDigestNotification.duration(30) == String(lore: "1分未満"))
    }

    @Test("Yesterday's digest is offered once, and nothing is offered without one")
    func morningDigestOnce() async throws {
        let harness = try await DigestHarness()
        #expect(await harness.service.takeMorningDigest() == nil)
        try await harness.seedDay(harness.yesterday)
        try await harness.service.generate(kind: .dailyDigest, scope: harness.scope(harness.yesterday))
        harness.now = at(harness.today, 8)
        #expect(await harness.service.takeMorningDigest()?.scope == harness.scope(harness.yesterday))
        #expect(await harness.service.takeMorningDigest() == nil)
        harness.service = harness.makeService()
        #expect(await harness.service.takeMorningDigest() == nil)
    }

    @Test("Delete Life Log and Reset Lore remove digests and their search index")
    func deletion() async throws {
        let harness = try await DigestHarness()
        try await harness.seedDay(harness.today)
        try await harness.service.generate(kind: .dailyDigest, scope: harness.scope(harness.today))
        try await harness.database.lifeLog.deleteAll()
        #expect(try await harness.digest(harness.today) == nil)
        #expect(try await harness.database.lifeLog.search("release note").isEmpty)

        try await harness.seedDay(harness.today)
        try await harness.service.generate(kind: .dailyDigest, scope: harness.scope(harness.today))
        try await harness.database.deleteAllUserData()
        #expect(try await harness.digest(harness.today) == nil)
        #expect(try await harness.database.queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM generated_notes_fts") } == 0)
    }
}

@Suite("v15-daily-digest migration")
struct DailyDigestMigrationTests {
    private func legacyDatabase(at root: URL) throws -> URL {
        let url = root.appendingPathComponent("lore.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = try DatabaseQueue(path: url.path)
        try LoreDatabase.migrator.migrate(legacy, upTo: "v14-event-snapshot-per-occurrence")
        let content = #"[{"kind":"decisions","items":[{"text":"Ship the beta on Friday","sources":["u-1"]}]},{"kind":"requests","items":[{"text":"Aki writes the note","sources":["u-1"]}]}]"#
        try legacy.write { db in
            try db.execute(sql: """
                INSERT INTO generated_notes (id, kind, scope_key, scope_day, event_id, range_start, range_end, provider, model,
                  created_at, source_utterance_ids, source_memo_ids, content)
                VALUES ('old-note', 'event_notes', 'event:e1@2026-11-01', '2026-11-01', 'e1', '2026-11-01T09:00:00.000Z',
                  '2026-11-01T10:00:00.000Z', 'ollama', 'm', '2026-11-01T10:01:00.000Z', '[]', '[]', ?)
                """, arguments: [content])
        }
        return url
    }

    @Test("The migration keeps notes, makes them searchable, and the backup holds the old schema")
    func migrates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-v15-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try legacyDatabase(at: root)
        let backups = root.appendingPathComponent("Backups")
        let database = try await LoreDatabase.open(fileURL: url, backupDirectory: backups)
        let notes = try await database.lifeLog.generatedNotes(fromDay: "2026-11-01", throughDay: "2026-11-01")
        #expect(notes.map(\.id) == ["old-note"])
        #expect(notes.first?.omittedSourceCount == 0)
        #expect(try await database.lifeLog.search("Aki writes").map(\.id) == ["generated-old-note"])
        #expect(try await database.lifeLog.search("Friday").map(\.kind) == [.generated])

        let backup = try #require(try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("pre-migration-") })
        let queue = try DatabaseQueue(path: backup.path)
        #expect(try await queue.read { try $0.tableExists("generated_notes_fts") } == false)
        #expect(try await queue.read { try String.fetchAll($0, sql: "SELECT id FROM generated_notes") } == ["old-note"])
    }

    @Test("A failing migration leaves the database unchanged")
    func failureLeavesDatabaseUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-v15-fail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try legacyDatabase(at: root)
        do {
            let legacy = try DatabaseQueue(path: url.path)
            try await legacy.write { try $0.execute(sql: "CREATE TABLE generated_notes_fts (conflict TEXT)") }
        }
        await #expect(throws: (any Error).self) {
            _ = try await LoreDatabase.open(fileURL: url, backupDirectory: root.appendingPathComponent("Backups"))
        }
        let queue = try DatabaseQueue(path: url.path)
        #expect(try await queue.read { try LoreDatabase.migrator.appliedIdentifiers($0).contains("v15-daily-digest") } == false)
        #expect(try await queue.read { try $0.columns(in: "generated_notes").contains { $0.name == "search_text" } } == false)
        #expect(try await queue.read { try String.fetchAll($0, sql: "SELECT id FROM generated_notes") } == ["old-note"])
    }
}
