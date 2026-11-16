import Foundation
import GRDB
import Synchronization
import Testing
@testable import LoreKit

private final class SpyLlm: LlmEngine {
    let identifier = EngineIdentifier.ollama
    let modelName: String? = "spy-model"
    let inputCharacterBudget: Int
    private let response: Mutex<Result<String, EngineError>>
    private let recorded = Mutex<[FormattingPrompt]>([])

    init(response: Result<String, EngineError> = .success(SpyLlm.validResponse), budget: Int = 24_000) {
        self.response = Mutex(response)
        inputCharacterBudget = budget
    }

    static let validResponse = """
        DECIDE (S1): Ship on Friday
        COMMIT (S2): Write the release note
        ASK (S2) [Aki]: Review the pricing page copy
        ASK (): Invented request
        COMMIT (S99): Prepare the invoice
        """

    var prompts: [FormattingPrompt] { recorded.withLock { $0 } }
    func availability() async -> EngineAvailability { .ready }
    func complete(prompt: FormattingPrompt, timeout: Duration) async throws -> String {
        recorded.withLock { $0.append(prompt) }
        return try response.withLock { $0 }.get()
    }
    func unload() async {}
}

@MainActor
private struct Fixture {
    let database: LoreDatabase
    var now: Date
    let event: CalendarEventSnapshot
    var settings = LifeLogAISettings()
    let spy: SpyLlm

    static let longText = String(repeating: "We agreed to ship the beta on Friday and Aki writes the release note. ", count: 3)

    static func make(spy: SpyLlm = SpyLlm(), backlog: Date? = nil) async throws -> Fixture {
        let database = try await LoreDatabase.inMemory()
        let day = Calendar.current.startOfDay(for: Date())
        let event = CalendarEventSnapshot(id: "event-1", title: "Release planning", startsAt: day.addingTimeInterval(10 * 3600),
                                          endsAt: day.addingTimeInterval(11 * 3600), calendarTitle: "Work")
        try await database.lifeLog.save(calendarEvents: [event])
        let chunk = LifeLogAudioChunk(id: "chunk-1", captureStartedAt: event.startsAt, captureEndedAt: event.endsAt,
                                      localPath: "/tmp/lore-ai-test.m4a", transcriptionState: .transcribed, processingState: .extracted)
        try await database.lifeLog.save(audioChunk: chunk)
        try await database.lifeLog.save(utterance: LifeLogUtterance(id: "u1", startedAt: event.startsAt.addingTimeInterval(60),
                                                                    endedAt: event.startsAt.addingTimeInterval(90), text: longText, audioChunkID: chunk.id))
        try await database.lifeLog.save(memo: LifeLogMemo(id: "m1", createdAt: event.startsAt.addingTimeInterval(120), text: "Release note owner: Aki"))
        // Outside the range: must never be sent.
        try await database.lifeLog.save(utterance: LifeLogUtterance(id: "u-outside", startedAt: event.endsAt.addingTimeInterval(60),
                                                                    endedAt: event.endsAt.addingTimeInterval(90), text: "OUTSIDE-SECRET", audioChunkID: chunk.id))
        var settings = LifeLogAISettings()
        settings.isEnabled = true
        settings.backend = .ollama
        return Fixture(database: database, now: event.endsAt.addingTimeInterval(60), event: event, settings: settings, spy: spy)
    }
}

@MainActor
private final class Harness {
    var fixture: Fixture
    var engineCalls = 0
    var backlog: Date?
    var excludedCalendarEvents: [CalendarEventSnapshot] = []
    var participatingOnly = true
    var saved: [(GeneratedNote, Bool)] = []
    lazy var service = makeService()

    init(_ fixture: Fixture) { self.fixture = fixture }

    func makeService() -> LifeLogAIService {
        LifeLogAIService(dependencies: .init(
            settings: { [unowned self] in fixture.settings },
            database: { [unowned self] in fixture.database },
            engine: { [unowned self] _, _ in
                engineCalls += 1
                return fixture.spy
            },
            oldestUntranscribedAudio: { [unowned self] in backlog },
            excludedCalendarEvents: { [unowned self] _, calendars in
                excludedCalendarEvents.filter { calendars.contains($0.calendarTitle) }
            },
            participatingEventsOnly: { [unowned self] in participatingOnly },
            noteSaved: { [unowned self] note, _, automatic in saved.append((note, automatic)) },
            now: { [unowned self] in fixture.now }
        ))
    }

    var scope: GeneratedNoteScope { .event(EventOccurrence(fixture.event)) }
}

@MainActor
@Suite("Life Log AI")
struct LifeLogAITests {
    // MARK: Send boundary

    @Test("With Life Log AI off, generation fails before any text is read or an engine is created")
    func offSendsNothing() async throws {
        var fixture = try await Fixture.make()
        fixture.settings.isEnabled = false
        let harness = Harness(fixture)
        await #expect(throws: LifeLogAIService.GenerationError.disabled) {
            try await harness.service.generate(kind: .eventNotes, scope: harness.scope)
        }
        await harness.service.evaluateEventNotes()
        #expect(harness.engineCalls == 0)
        #expect(fixture.spy.prompts.isEmpty)
        #expect(try await fixture.database.lifeLog.generatedNote(kind: .eventNotes, scope: harness.scope) == nil)
    }

    @Test("A cloud provider without its confirmation sends nothing, and the confirmation is per provider")
    func cloudNeedsConfirmation() async throws {
        var fixture = try await Fixture.make()
        fixture.settings.backend = .openAI
        let harness = Harness(fixture)
        await #expect(throws: LifeLogAIService.GenerationError.cloudConsentRequired(.openAI)) {
            try await harness.service.generate(kind: .eventNotes, scope: harness.scope)
        }
        #expect(harness.engineCalls == 0)
        harness.fixture.settings.confirmedCloudBackend = .anthropic
        #expect(harness.fixture.settings.sendPermission == .cloudConsentRequired(.openAI))
        harness.fixture.settings.confirmedCloudBackend = .openAI
        #expect(harness.fixture.settings.sendPermission == .allowed)
    }

    @Test("Only the event range is sent, and the stored note keeps only traceable items and their sources")
    func sendsRangeAndStoresTraceableItems() async throws {
        let harness = Harness(try await Fixture.make())
        let note = try await harness.service.generate(kind: .eventNotes, scope: harness.scope)

        let prompt = try #require(harness.fixture.spy.prompts.first)
        #expect(prompt.user.contains("Release planning"))
        #expect(prompt.user.contains("Release note owner: Aki"))
        #expect(!prompt.user.contains("OUTSIDE-SECRET"))
        #expect(!prompt.user.contains("Work"), "the calendar name is not sent")
        #expect(prompt.system.contains("only the user's own microphone"))

        #expect(note.items(.decisions).map(\.text) == ["Ship on Friday"])
        #expect(note.items(.decisions).first?.sources == ["u-u1"])
        #expect(note.items(.requests).map(\.text) == ["Review the pricing page copy"])
        #expect(note.items(.requests).first?.owner == "Aki")
        #expect(note.items(.commitments).map(\.text) == ["Write the release note"], "an item citing an unknown label is dropped")
        #expect(note.sourceUtteranceIDs == ["u1"])
        #expect(note.sourceMemoIDs == ["m1"])
        #expect(note.backend == .ollama)
        #expect(harness.service.requestsToday == 1)
        let stored = try #require(try await harness.fixture.database.lifeLog.generatedNote(kind: .eventNotes, scope: harness.scope))
        #expect(stored.sections == note.sections)
        #expect(stored.staleReasons.isEmpty)
    }

    @Test("An excluded event, an excluded calendar, and text under an overlapping excluded event are never sent")
    func exclusions() async throws {
        let harness = Harness(try await Fixture.make())
        let database = harness.fixture.database
        try await database.lifeLog.setAIExcluded(true, eventID: "event-1")
        await #expect(throws: LifeLogAIService.GenerationError.excluded) {
            try await harness.service.generate(kind: .eventNotes, scope: harness.scope)
        }
        try await database.lifeLog.setAIExcluded(false, eventID: "event-1")

        harness.fixture.settings.excludedCalendars = ["Work"]
        await #expect(throws: LifeLogAIService.GenerationError.excluded) {
            try await harness.service.generate(kind: .eventNotes, scope: harness.scope)
        }
        harness.fixture.settings.excludedCalendars = []
        #expect(harness.fixture.spy.prompts.isEmpty)

        // A private event overlapping the memo's time hides the memo from the other event's request.
        let event = harness.fixture.event
        try await database.lifeLog.save(calendarEvents: [CalendarEventSnapshot(
            id: "private", title: "Doctor", startsAt: event.startsAt.addingTimeInterval(100),
            endsAt: event.startsAt.addingTimeInterval(200), calendarTitle: "Personal")])
        try await database.lifeLog.setAIExcluded(true, eventID: "private")
        let note = try await harness.service.generate(kind: .eventNotes, scope: harness.scope)
        let prompt = try #require(harness.fixture.spy.prompts.last)
        #expect(!prompt.user.contains("Release note owner: Aki"))
        #expect(!prompt.user.contains("Doctor"))
        #expect(note.sourceMemoIDs.isEmpty)
    }

    @Test("An excluded calendar that the timeline does not import, and an excluded all-day event, still hide their text")
    func exclusionsBeyondTheSnapshot() async throws {
        let harness = Harness(try await Fixture.make())
        let event = harness.fixture.event
        // The utterance starts before the private range and runs into it, so it is left out as well.
        harness.excludedCalendarEvents = [CalendarEventSnapshot(
            id: "not-imported", title: "Therapy", startsAt: event.startsAt.addingTimeInterval(80),
            endsAt: event.startsAt.addingTimeInterval(100), calendarTitle: "Private")]
        harness.fixture.settings.excludedCalendars = ["Private"]
        let note = try await harness.service.generate(kind: .eventNotes, scope: harness.scope)
        let prompt = try #require(harness.fixture.spy.prompts.first)
        #expect(!prompt.user.contains("We agreed to ship"))
        #expect(!prompt.user.contains("Therapy"))
        #expect(prompt.user.contains("Release note owner: Aki"))
        #expect(note.sourceUtteranceIDs.isEmpty)
        harness.fixture.settings.excludedCalendars = []
        try await harness.fixture.database.lifeLog.save(calendarEvents: [CalendarEventSnapshot(
            id: "holiday", title: "Off", startsAt: Calendar.current.startOfDay(for: event.startsAt),
            endsAt: Calendar.current.startOfDay(for: event.startsAt).addingTimeInterval(86_400), calendarTitle: "Work", isAllDay: true)])
        try await harness.fixture.database.lifeLog.setAIExcluded(true, eventID: "holiday")
        await #expect(throws: LifeLogAIService.GenerationError.nothingToSend) {
            try await harness.service.generate(kind: .eventNotes, scope: harness.scope)
        }
        #expect(harness.fixture.spy.prompts.count == 1)
    }

    @Test("A provider failure keeps a retryable reason and leaves the timeline as it was")
    func providerFailure() async throws {
        let harness = Harness(try await Fixture.make(spy: SpyLlm(response: .failure(.failed("provider down")))))
        await #expect(throws: (any Error).self) {
            try await harness.service.generate(kind: .eventNotes, scope: harness.scope)
        }
        #expect(harness.service.failures[harness.scope.key] == "provider down")
        #expect(harness.service.generatingScopes.isEmpty)
        let day = try await harness.fixture.database.lifeLog.day(harness.fixture.event.startsAt)
        #expect(day.utterances.count == 2)
        #expect(day.generatedNotes.isEmpty)
    }

    @Test("A localhost provider sends its requests only to localhost")
    func localProviderStaysOnLocalhost() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        RecordingURLProtocol.reset()
        for backend in [FormattingBackend.ollama, .lmStudio] {
            let engine = EngineRegistry().lifeLogAIEngine(backend: backend, model: backend.defaultModel, session: session)
            _ = try await engine.complete(prompt: FormattingPrompt(system: "s", user: "u"), timeout: .seconds(5))
        }
        let hosts = RecordingURLProtocol.hosts
        #expect(hosts.count == 2)
        #expect(hosts.allSatisfy { $0 == "localhost" })
    }

    // MARK: Trigger

    @Test("The trigger decides from the event, the settings, and the store state")
    func triggerRules() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let event = CalendarEventSnapshot(id: "e", title: "t", startsAt: today.addingTimeInterval(9 * 3600),
                                          endsAt: today.addingTimeInterval(10 * 3600), calendarTitle: "c")
        var on = LifeLogAISettings()
        on.isEnabled = true
        let after = event.endsAt.addingTimeInterval(60)
        func decide(_ settings: LifeLogAISettings = on, event: CalendarEventSnapshot = event, now: Date = after,
                    excluded: Bool = false, hasNote: Bool = false, wasDeleted: Bool = false, characters: Int = 500,
                    backlog: Date? = nil) -> GenerationDecision {
            EventNotesTrigger.decide(event: event, now: now, settings: settings, isExcluded: excluded, hasNote: hasNote, wasDeleted: wasDeleted,
                                     spokenCharacters: characters, oldestUntranscribedAudio: backlog)
        }
        #expect(decide() == .generate)
        #expect(decide(LifeLogAISettings()) == .skip(.notAllowed))
        var manual = on
        manual.eventNotesTrigger = .manual
        #expect(decide(manual) == .skip(.manualTrigger))
        var allDay = event
        allDay.isAllDay = true
        #expect(decide(event: allDay) == .skip(.allDay))
        #expect(decide(now: event.endsAt) == .waitUntil(event.endsAt.addingTimeInterval(EventNotesTrigger.settleTime)))
        #expect(decide(now: today.addingTimeInterval(86_400 + 60)) == .skip(.outsideLookBack))
        var midnight = event
        midnight.endsAt = today.addingTimeInterval(86_400)
        #expect(decide(event: midnight, now: midnight.endsAt.addingTimeInterval(EventNotesTrigger.settleTime)) == .generate)
        #expect(decide(wasDeleted: true) == .skip(.deletedByUser))
        #expect(decide(hasNote: true) == .skip(.alreadyGenerated))
        #expect(decide(excluded: true) == .skip(.excluded))
        #expect(decide(characters: EventNotesPolicy.minimumSpokenCharacters - 1) == .skip(.tooLittleSpeech))
        #expect(decide(backlog: event.endsAt.addingTimeInterval(-30)) == .waitForTranscription)
        #expect(decide(backlog: event.endsAt.addingTimeInterval(30)) == .generate)
    }

    @Test("Evaluating again, or after a relaunch, never makes a second request for the same occurrence")
    func triggerIsIdempotent() async throws {
        let harness = Harness(try await Fixture.make())
        await harness.service.evaluateEventNotes()
        await harness.service.evaluateEventNotes()
        let relaunched = harness.makeService()
        await relaunched.evaluateEventNotes()
        #expect(harness.fixture.spy.prompts.count == 1)
        #expect(harness.saved.map(\.1) == [true])
        let notes = try await harness.fixture.database.lifeLog.generatedNotes(fromDay: harness.scope.day, throughDay: harness.scope.day)
        #expect(notes.count == 1)
    }

    @Test("A note the user deleted is not generated again automatically, and manual generation clears that")
    func deletedNotesStayDeleted() async throws {
        let harness = Harness(try await Fixture.make())
        await harness.service.evaluateEventNotes()
        let database = harness.fixture.database
        let note = try #require(try await database.lifeLog.generatedNote(kind: .eventNotes, scope: harness.scope))
        await harness.service.deleteNote(note)
        await harness.service.evaluateEventNotes()
        #expect(harness.fixture.spy.prompts.count == 1)
        #expect(try await database.lifeLog.generatedNote(kind: .eventNotes, scope: harness.scope) == nil)
        try await harness.service.generate(kind: .eventNotes, scope: harness.scope)
        #expect(try await database.lifeLog.isGeneratedNoteDismissed(kind: .eventNotes, scope: harness.scope) == false)
    }

    @Test("The trigger skips events that the participation filter hides")
    func triggerHonorsParticipation() async throws {
        let harness = Harness(try await Fixture.make())
        var declined = harness.fixture.event
        declined.participationStatus = .declined
        try await harness.fixture.database.lifeLog.save(calendarEvents: [declined])
        await harness.service.evaluateEventNotes()
        #expect(harness.fixture.spy.prompts.isEmpty)
        harness.participatingOnly = false
        await harness.service.evaluateEventNotes()
        #expect(harness.fixture.spy.prompts.count == 1)
    }

    @Test("An unanswered invitation never starts notes on its own while the filter is on")
    func triggerSkipsPendingInvitation() async throws {
        let harness = Harness(try await Fixture.make())
        var pending = harness.fixture.event
        pending.participationStatus = .pending
        try await harness.fixture.database.lifeLog.save(calendarEvents: [pending])
        await harness.service.evaluateEventNotes()
        #expect(harness.fixture.spy.prompts.isEmpty)
        harness.participatingOnly = false
        await harness.service.evaluateEventNotes()
        #expect(harness.fixture.spy.prompts.count == 1)
    }

    @Test("Pending transcription before the event end makes the trigger wait")
    func triggerWaitsForTranscription() async throws {
        let harness = Harness(try await Fixture.make())
        harness.backlog = harness.fixture.event.endsAt.addingTimeInterval(-10)
        await harness.service.evaluateEventNotes()
        #expect(harness.fixture.spy.prompts.isEmpty)
        harness.backlog = nil
        await harness.service.evaluateEventNotes()
        #expect(harness.fixture.spy.prompts.count == 1)
    }

    @Test("An event with too little speech gets no request")
    func triggerSkipsShortEvents() async throws {
        let harness = Harness(try await Fixture.make())
        try await harness.fixture.database.lifeLog.save(utterance: LifeLogUtterance(
            id: "u1", startedAt: harness.fixture.event.startsAt.addingTimeInterval(60),
            endedAt: harness.fixture.event.startsAt.addingTimeInterval(62), text: "OK", audioChunkID: "chunk-1"))
        await harness.service.evaluateEventNotes()
        #expect(harness.fixture.spy.prompts.isEmpty)
    }

    // MARK: Staleness and deletion

    @Test("Moving the event or deleting a source marks the note, and the trigger does not regenerate it")
    func staleness() async throws {
        let harness = Harness(try await Fixture.make())
        try await harness.service.generate(kind: .eventNotes, scope: harness.scope)
        let database = harness.fixture.database
        var moved = harness.fixture.event
        moved.endsAt = moved.endsAt.addingTimeInterval(1800)
        try await database.lifeLog.save(calendarEvents: [moved])
        var note = try #require(try await database.lifeLog.generatedNote(kind: .eventNotes, scope: harness.scope))
        #expect(note.staleReasons == [.eventChanged])

        try await database.lifeLog.deleteMemo(id: "m1")
        note = try #require(try await database.lifeLog.generatedNote(kind: .eventNotes, scope: harness.scope))
        #expect(note.staleReasons == [.eventChanged, .sourcesDeleted])

        harness.fixture.now = moved.endsAt.addingTimeInterval(60)
        await harness.service.evaluateEventNotes()
        #expect(harness.fixture.spy.prompts.count == 1)
    }

    @Test("Saving the next occurrence of a repeating event leaves this occurrence's note unmarked")
    func nextOccurrenceDoesNotMarkNote() async throws {
        let harness = Harness(try await Fixture.make())
        try await harness.service.generate(kind: .eventNotes, scope: harness.scope)
        var tomorrow = harness.fixture.event
        tomorrow.startsAt = tomorrow.startsAt.addingTimeInterval(86_400)
        tomorrow.endsAt = tomorrow.endsAt.addingTimeInterval(86_400)
        try await harness.fixture.database.lifeLog.save(calendarEvents: [tomorrow])
        let note = try #require(try await harness.fixture.database.lifeLog.generatedNote(kind: .eventNotes, scope: harness.scope))
        #expect(note.staleReasons.isEmpty)
    }

    @Test("Delete Life Log and Reset Lore remove notes and AI exclusions")
    func deletion() async throws {
        for resetsEverything in [false, true] {
            let harness = Harness(try await Fixture.make())
            let database = harness.fixture.database
            try await harness.service.generate(kind: .eventNotes, scope: harness.scope)
            try await database.lifeLog.setAIExcluded(true, eventID: "other")
            if resetsEverything { try await database.deleteAllUserData() } else { try await database.lifeLog.deleteAll() }
            #expect(try await database.lifeLog.generatedNotes(fromDay: "0000-01-01", throughDay: "9999-12-31").isEmpty)
            #expect(try await database.lifeLog.aiExcludedEventIDs().isEmpty)
        }
    }

    // MARK: Export and automation

    @Test("The day export includes AI notes only when asked, marked as AI-generated")
    func exportOption() async throws {
        let harness = Harness(try await Fixture.make())
        try await harness.service.generate(kind: .eventNotes, scope: harness.scope)
        let day = try await harness.fixture.database.lifeLog.day(harness.fixture.event.startsAt)
        let plain = LifeLogTextExporter.render(date: harness.fixture.event.startsAt, day: day)
        #expect(!plain.contains("Ship on Friday"))
        let withNotes = LifeLogTextExporter.render(date: harness.fixture.event.startsAt, day: day, options: .init(includesAINotes: true))
        #expect(withNotes.contains("Ship on Friday"))
        #expect(withNotes.contains("AIが生成したノート"))
        #expect(withNotes.contains("Ollama"))
    }

    @Test("The automation service reads notes marked as generated, with their staleness")
    func automationReadsNotes() async throws {
        let harness = Harness(try await Fixture.make())
        try await harness.service.generate(kind: .eventNotes, scope: harness.scope)
        try await harness.fixture.database.lifeLog.deleteMemo(id: "m1")
        let service = LoreAutomationService(database: harness.fixture.database, settings: AppSettings(defaults: UserDefaults(suiteName: "lore-ai-\(UUID())")!))
        let entries = try await service.aiNotes(from: harness.fixture.event.startsAt, to: harness.fixture.event.startsAt)
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.generated)
        #expect(entry.eventId == "event-1")
        #expect(entry.stale == ["sources_deleted"])
        #expect(try LifeLogJSON.encode(entries).contains("\"generated\" : true"))
    }

    @Test("A source line is label, minute, and text, and only kinds other than utterance name their kind")
    func sourceLine() {
        let utc = TimeZone(identifier: "UTC")!
        let at = Date(timeIntervalSince1970: 1_800_000_045)
        let line = { (kind: GeneratedNoteSource.Kind, end: Date?) in
            GeneratedNoteSource(label: "S7", kind: kind, timelineID: "t", recordID: "r", at: at, end: end, text: "a\nb").line(timeZone: utc)
        }
        #expect(line(.utterance, nil) == "S7 08:00 a b\n")
        #expect(line(.memo, nil) == "S7 08:00 memo: a b\n")
        #expect(line(.event, at.addingTimeInterval(3_600)) == "S7 08:00-09:00 event: a b\n")
    }

    @Test("The parser reads one item per line, accepts NONE, and rejects an unreadable answer")
    func parser() throws {
        let sent = [GeneratedNoteSource(label: "S1", kind: .utterance, timelineID: "u-a", recordID: "a", at: Date(), text: "x"),
                    GeneratedNoteSource(label: "S2", kind: .memo, timelineID: "m-b", recordID: "b", at: Date(), text: "y")]
        let sections = try EventNotesPolicy.parse("""
            Here are the notes:
            - COMMIT (S1, S2): Keep the plan
            ASK (S2) [null]: Send the summary
            DECIDE (S7): Unknown source
            """, sent: sent)
        #expect(sections.first { $0.kind == .commitments }?.items.first?.sources == ["u-a", "m-b"])
        #expect(sections.first { $0.kind == .requests }?.items.first?.owner == nil)
        #expect(sections.first { $0.kind == .decisions }?.items.isEmpty == true)
        #expect(try EventNotesPolicy.parse("NONE", sent: sent).allSatisfy(\.items.isEmpty))
        #expect(throws: GeneratedNoteResponse.ParseError.self) {
            try EventNotesPolicy.parse(#"{"decisions":[{"text": "x",sources":["S1"]}]"#, sent: sent)
        }
    }

    @Test("COMMIT, ASK, and DECIDE become commitments, requests, and decisions in that order, and only ASK keeps the person")
    func parsesTheUsersOwnSide() throws {
        let sent = (1...3).map {
            GeneratedNoteSource(label: "S\($0)", kind: .utterance, timelineID: "u-\($0)", recordID: "\($0)", at: Date(), text: "x")
        }
        let sections = try EventNotesPolicy.parse("""
            DECIDE (S3) [Aki]: Go with the two-tier plan
            ASK (S2) [Aki]: Review the pricing page copy
            COMMIT (S1) [Aki]: Send the release notes draft by Thursday
            """, sent: sent)
        #expect(sections.map(\.kind) == [.commitments, .requests, .decisions])
        #expect(sections.map { $0.items.map(\.text) } == [["Send the release notes draft by Thursday"], ["Review the pricing page copy"], ["Go with the two-tier plan"]])
        #expect(sections.map { $0.items.first?.owner } == [nil, "Aki", nil])
    }

    @Test("The old DECISION, ACTION, and QUESTION lines are not recognized")
    func rejectsTheOldTags() {
        let sent = [GeneratedNoteSource(label: "S1", kind: .utterance, timelineID: "u-a", recordID: "a", at: Date(), text: "x")]
        #expect(throws: GeneratedNoteResponse.ParseError.self) {
            try EventNotesPolicy.parse("""
                DECISION (S1): Keep the plan
                ACTION (S1) [Aki]: Send the summary
                QUESTION (S1): Who reviews it?
                """, sent: sent)
        }
    }

    @Test("The instructions tell the model that the user's voice is not guaranteed and that unsure items are left out")
    func instructionsCarrySpeakerCaveat() {
        for instructions in [EventNotesPolicy.instructions, DailyDigestPolicy.instructions] {
            #expect(instructions.contains("other voices in the room may appear"))
            #expect(instructions.contains("Leave it out when you are unsure who said it"))
            #expect(instructions.contains("Memos are always the user's own words"))
        }
    }

    @Test("Settings decode missing or unknown values to off without losing other fields")
    func settingsDecoding() throws {
        let decoded = try JSONDecoder().decode(LifeLogAISettings.self, from: Data(#"{"backend":"unknown","isEnabled":true}"#.utf8))
        #expect(decoded.isEnabled)
        #expect(decoded.backend == .onDevice)
        #expect(decoded.confirmedCloudBackend == nil)
        #expect(LifeLogAISettings().sendPermission == .disabled)
    }
}

@Suite("v12-life-log-ai migration")
struct LifeLogAIMigrationTests {
    private func legacyDatabase(at root: URL) throws -> URL {
        let url = root.appendingPathComponent("lore.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = try DatabaseQueue(path: url.path)
        try LoreDatabase.migrator.migrate(legacy, upTo: "v11-remove-vocab-suggestions")
        try legacy.write { db in
            try db.execute(sql: "INSERT INTO life_log_memos (id, created_at, text) VALUES ('keep', '2026-11-01T09:00:00.000Z', 'before v12')")
        }
        return url
    }

    @Test("The migration adds the tables and keeps existing records, and the backup holds the old schema")
    func migrates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-v12-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try legacyDatabase(at: root)
        let backups = root.appendingPathComponent("Backups")
        let database = try await LoreDatabase.open(fileURL: url, backupDirectory: backups)
        #expect(try await database.lifeLog.memo(id: "keep")?.text == "before v12")
        #expect(try await database.lifeLog.aiExcludedEventIDs().isEmpty)

        let backup = try #require(try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("pre-migration-") })
        let queue = try DatabaseQueue(path: backup.path)
        #expect(try await queue.read { try $0.tableExists("generated_notes") } == false)
        #expect(try await queue.read { try String.fetchAll($0, sql: "SELECT text FROM life_log_memos") } == ["before v12"])
    }

    @Test("A failing migration leaves the database unchanged")
    func failureLeavesDatabaseUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-v12-fail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try legacyDatabase(at: root)
        do {
            let legacy = try DatabaseQueue(path: url.path)
            try await legacy.write { try $0.execute(sql: "CREATE TABLE life_log_ai_event_exclusions (conflict TEXT)") }
        }
        await #expect(throws: (any Error).self) {
            _ = try await LoreDatabase.open(fileURL: url, backupDirectory: root.appendingPathComponent("Backups"))
        }
        let queue = try DatabaseQueue(path: url.path)
        #expect(try await queue.read { try $0.tableExists("generated_notes") } == false)
        #expect(try await queue.read { try LoreDatabase.migrator.appliedIdentifiers($0).contains("v12-life-log-ai") } == false)
        #expect(try await queue.read { try String.fetchAll($0, sql: "SELECT text FROM life_log_memos") } == ["before v12"])
    }
}

final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let recorded = Mutex<[String]>([])
    static var hosts: [String] { recorded.withLock { $0 } }
    static func reset() { recorded.withLock { $0 = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.recorded.withLock { $0.append(request.url?.host ?? "") }
        let body = Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
