import Foundation
import Observation

/// The only path from the Life Log to an LLM. It reads what the capture pipeline already saved and
/// never takes part in recording or transcription, so a provider failure cannot affect either.
@MainActor
@Observable
public final class LifeLogAIService {
    public struct Dependencies {
        public var settings: @MainActor () -> LifeLogAISettings
        public var database: @MainActor () -> LoreDatabase?
        public var engine: @MainActor (FormattingBackend, String) -> any LlmEngine
        public var oldestUntranscribedAudio: @MainActor () async throws -> Date?
        public var refreshTodayCalendar: @MainActor () async throws -> Void
        /// Events of the AI-excluded calendars in an interval, read from the calendar itself, because the
        /// snapshot holds only the calendars shown in the timeline.
        public var excludedCalendarEvents: @MainActor (DateInterval, Set<String>) async throws -> [CalendarEventSnapshot]
        public var participatingEventsOnly: @MainActor () -> Bool
        /// The recording schedule. The end of a day's window is that day's digest time.
        public var lifeLogSchedule: @MainActor () -> LifeLogSchedule
        /// Called after a note is stored, with its event for event notes. `automatic` is true when the trigger made it.
        public var noteSaved: @MainActor (GeneratedNote, CalendarEventSnapshot?, _ automatic: Bool) async -> Void
        public var now: @MainActor () -> Date

        public init(
            settings: @escaping @MainActor () -> LifeLogAISettings,
            database: @escaping @MainActor () -> LoreDatabase?,
            engine: @escaping @MainActor (FormattingBackend, String) -> any LlmEngine,
            oldestUntranscribedAudio: @escaping @MainActor () async throws -> Date? = { nil },
            refreshTodayCalendar: @escaping @MainActor () async throws -> Void = {},
            excludedCalendarEvents: @escaping @MainActor (DateInterval, Set<String>) async throws -> [CalendarEventSnapshot] = { _, _ in [] },
            participatingEventsOnly: @escaping @MainActor () -> Bool = { true },
            lifeLogSchedule: @escaping @MainActor () -> LifeLogSchedule = { LifeLogSchedule() },
            noteSaved: @escaping @MainActor (GeneratedNote, CalendarEventSnapshot?, Bool) async -> Void = { _, _, _ in },
            now: @escaping @MainActor () -> Date = { Date() }
        ) {
            self.settings = settings
            self.database = database
            self.engine = engine
            self.oldestUntranscribedAudio = oldestUntranscribedAudio
            self.refreshTodayCalendar = refreshTodayCalendar
            self.excludedCalendarEvents = excludedCalendarEvents
            self.participatingEventsOnly = participatingEventsOnly
            self.lifeLogSchedule = lifeLogSchedule
            self.noteSaved = noteSaved
            self.now = now
        }
    }

    public enum GenerationError: LocalizedError, Equatable {
        case disabled
        case cloudConsentRequired(FormattingBackend)
        case databaseUnavailable
        case eventNotFound
        case excluded
        case nothingToSend
        case tooLittleSpeech

        public var errorDescription: String? {
            switch self {
            case .disabled: String(lore: "ライフログAIがオフです")
            case .cloudConsentRequired(let backend): String(lore: "\(backend.displayName)へ送信する確認がまだです")
            case .databaseUnavailable: String(lore: "データベースを開けていません")
            case .eventNotFound: String(lore: "予定が見つかりません")
            case .excluded: String(lore: "この予定はAIに送らない設定です")
            case .nothingToSend: String(lore: "予定の時間内に送れる発話やメモがありません")
            case .tooLittleSpeech: String(lore: "まとめを作るには、この日の発話が少なすぎます")
            }
        }
    }

    static let requestCountKey = "life_log_ai_requests"
    static let requestTimeout: Duration = .seconds(90)
    static let transcriptionRetryInterval: TimeInterval = 120

    /// Scope keys with a request in flight.
    public private(set) var generatingScopes: Set<String> = []
    /// The last failure per scope key, shown next to "Retry".
    public private(set) var failures: [String: String] = [:]
    public private(set) var requestsToday = 0
    public private(set) var excludedEventIDs: Set<String> = []
    public private(set) var errorMessage: String?

    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var tasks: [String: Task<GeneratedNote, Error>] = [:]
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var digestWakeTask: Task<Void, Never>?
    /// An automatic run tries an occurrence once per process. "Retry" in the UI always asks again.
    @ObservationIgnored private var automaticFailures: Set<String> = []

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    public func configure() async {
        guard let database = dependencies.database() else { return }
        do {
            excludedEventIDs = try await database.lifeLog.aiExcludedEventIDs()
            requestsToday = try await storedRequestCount(database: database)
        } catch { report(error) }
    }

    // MARK: Generation

    /// The single entry point. Sending is checked before any Life Log text is read.
    @discardableResult
    public func generate(kind: GeneratedNoteKind, scope: GeneratedNoteScope) async throws -> GeneratedNote {
        try await generate(kind: kind, scope: scope, automatic: false)
    }

    @discardableResult
    private func generate(kind: GeneratedNoteKind, scope: GeneratedNoteScope, automatic: Bool) async throws -> GeneratedNote {
        let settings = dependencies.settings()
        switch settings.sendPermission {
        case .allowed: break
        case .disabled: throw GenerationError.disabled
        case .cloudConsentRequired(let backend): throw GenerationError.cloudConsentRequired(backend)
        }
        if let running = tasks[scope.key] { return try await running.value }
        let task = Task { try await self.perform(kind: kind, scope: scope, settings: settings, automatic: automatic) }
        tasks[scope.key] = task
        generatingScopes.insert(scope.key)
        defer {
            tasks[scope.key] = nil
            generatingScopes.remove(scope.key)
        }
        do {
            let note = try await task.value
            failures[scope.key] = nil
            return note
        } catch {
            failures[scope.key] = error.localizedDescription
            throw error
        }
    }

    private func perform(kind: GeneratedNoteKind, scope: GeneratedNoteScope, settings: LifeLogAISettings, automatic: Bool) async throws -> GeneratedNote {
        guard let database = dependencies.database() else { throw GenerationError.databaseUnavailable }
        switch scope {
        case .event(let occurrence):
            return try await performEventNotes(occurrence: occurrence, kind: kind, settings: settings, automatic: automatic, database: database)
        case .day(let day):
            return try await performDailyDigest(day: day, settings: settings, automatic: automatic, database: database)
        }
    }

    private func performEventNotes(occurrence: EventOccurrence, kind: GeneratedNoteKind, settings: LifeLogAISettings,
                                   automatic: Bool, database: LoreDatabase) async throws -> GeneratedNote {
        guard let date = LifeLogDateKey.date(from: occurrence.day) else { throw GenerationError.eventNotFound }
        let day = try await database.lifeLog.day(date)
        guard let event = day.calendarEvents.first(where: { EventOccurrence($0) == occurrence }) else {
            throw GenerationError.eventNotFound
        }
        let excluded = try await database.lifeLog.aiExcludedEventIDs()
        guard !settings.excludes(event, excludedEventIDs: excluded) else { throw GenerationError.excluded }
        let input = EventNotesPolicy.input(
            for: event, day: day, settings: settings, excludedEventIDs: excluded,
            excludedCalendarEvents: try await excludedCalendarEvents(around: event, settings: settings)
        )
        let engine = dependencies.engine(settings.backend, settings.model)
        let (prompt, sent) = EventNotesPolicy.prompt(for: input, characterBudget: engine.inputCharacterBudget)
        guard !sent.isEmpty else { throw GenerationError.nothingToSend }
        try await countRequest(database: database)
        let output = try await engine.complete(prompt: prompt, timeout: Self.requestTimeout)
        let note = GeneratedNote(
            kind: kind,
            scope: .event(occurrence),
            rangeStart: event.startsAt,
            rangeEnd: event.endsAt,
            backend: settings.backend,
            model: engine.modelName ?? settings.model,
            createdAt: dependencies.now(),
            sourceUtteranceIDs: sent.filter { $0.kind == .utterance }.map(\.recordID),
            sourceMemoIDs: sent.filter { $0.kind == .memo }.map(\.recordID),
            omittedSourceCount: input.sources.count - sent.count,
            sections: try EventNotesPolicy.parse(output, sent: sent)
        )
        try await database.lifeLog.save(generatedNote: note)
        await dependencies.noteSaved(note, event, automatic)
        return note
    }

    private func performDailyDigest(day: String, settings: LifeLogAISettings, automatic: Bool, database: LoreDatabase) async throws -> GeneratedNote {
        guard let date = LifeLogDateKey.date(from: day), let interval = Calendar.current.dateInterval(of: .day, for: date) else {
            throw GenerationError.nothingToSend
        }
        let input = try await digestInput(day: day, date: date, interval: interval, settings: settings, database: database)
        guard input.spokenCharacters >= DailyDigestPolicy.minimumSpokenCharacters else { throw GenerationError.tooLittleSpeech }
        let engine = dependencies.engine(settings.backend, settings.model)
        let (prompt, sent, omitted) = DailyDigestPolicy.prompt(for: input, characterBudget: engine.inputCharacterBudget)
        guard !sent.isEmpty else { throw GenerationError.nothingToSend }
        try await countRequest(database: database)
        let output = try await engine.complete(prompt: prompt, timeout: Self.requestTimeout)
        let note = GeneratedNote(
            kind: .dailyDigest,
            scope: .day(day),
            rangeStart: interval.start,
            rangeEnd: interval.end,
            backend: settings.backend,
            model: engine.modelName ?? settings.model,
            createdAt: dependencies.now(),
            sourceUtteranceIDs: sent.filter { $0.kind == .utterance }.map(\.recordID),
            sourceMemoIDs: sent.filter { $0.kind == .memo }.map(\.recordID),
            omittedSourceCount: omitted,
            sections: try DailyDigestPolicy.parse(output, input: input, sent: sent)
        )
        try await database.lifeLog.save(generatedNote: note)
        await dependencies.noteSaved(note, nil, automatic)
        return note
    }

    private func digestInput(day: String, date: Date, interval: DateInterval, settings: LifeLogAISettings,
                             database: LoreDatabase) async throws -> DailyDigestInput {
        let contents = try await database.lifeLog.day(date)
        let listed = dependencies.participatingEventsOnly()
            ? contents.calendarEvents.filter(\.participationStatus.isParticipating)
            : contents.calendarEvents
        let excludedCalendarEvents = settings.excludedCalendars.isEmpty ? []
            : try await dependencies.excludedCalendarEvents(interval, Set(settings.excludedCalendars))
        return DailyDigestPolicy.input(
            dayKey: day, day: contents, listedEvents: listed, settings: settings,
            excludedEventIDs: try await database.lifeLog.aiExcludedEventIDs(),
            excludedCalendarEvents: excludedCalendarEvents
        )
    }

    private func excludedCalendarEvents(around event: CalendarEventSnapshot, settings: LifeLogAISettings) async throws -> [CalendarEventSnapshot] {
        guard !settings.excludedCalendars.isEmpty else { return [] }
        return try await dependencies.excludedCalendarEvents(DateInterval(start: event.startsAt, end: event.endsAt), Set(settings.excludedCalendars))
    }

    public func deleteNote(_ note: GeneratedNote) async {
        guard let database = dependencies.database() else { return }
        do { try await database.lifeLog.deleteGeneratedNote(note) } catch { report(error) }
    }

    public func setExcluded(_ excluded: Bool, eventID: String) async {
        guard let database = dependencies.database() else { return }
        do {
            try await database.lifeLog.setAIExcluded(excluded, eventID: eventID)
            excludedEventIDs = try await database.lifeLog.aiExcludedEventIDs()
        } catch { report(error) }
    }

    public func dismissError() { errorMessage = nil }

    /// After "Delete Life Log" or "Reset Lore…" the in-memory projections must match the empty store.
    public func dataWasDeleted() async {
        failures = [:]
        automaticFailures = []
        await configure()
    }

    // MARK: Automatic trigger

    /// Evaluates every event of today and sleeps until the next moment a decision can change.
    /// Safe to call from any trigger source at any time: an occurrence with a note is never sent again.
    public func evaluateEventNotes() async {
        wakeTask?.cancel()
        wakeTask = nil
        let settings = dependencies.settings()
        guard settings.sendPermission == .allowed, settings.eventNotesTrigger == .automatic,
              let database = dependencies.database() else { return }
        do {
            try await dependencies.refreshTodayCalendar()
        } catch {
            // The stored snapshot still drives the decision; the refresh is retried on the next trigger.
            LoreLog.session.error("Life Log AI could not refresh today's events: \(error.localizedDescription, privacy: .public)")
        }
        var nextWake: Date?
        do {
            let now = dependencies.now()
            let excluded = try await database.lifeLog.aiExcludedEventIDs()
            let backlog = try await dependencies.oldestUntranscribedAudio()
            let participatingOnly = dependencies.participatingEventsOnly()
            // An event that ended just before midnight becomes ready on the next day.
            var days = [try await database.lifeLog.day(now)]
            let earlier = now.addingTimeInterval(-EventNotesTrigger.settleTime)
            if !Calendar.current.isDate(earlier, inSameDayAs: now) { days.append(try await database.lifeLog.day(earlier)) }
            var seen = Set<String>()
            let candidates = days.flatMap { day in day.calendarEvents.map { (day: day, event: $0) } }
            for (day, event) in candidates where !participatingOnly || event.participationStatus.isParticipating {
                let scope = GeneratedNoteScope.event(EventOccurrence(event))
                guard seen.insert(scope.key).inserted, !automaticFailures.contains(scope.key) else { continue }
                let isExcluded = settings.excludes(event, excludedEventIDs: excluded)
                // The calendar is read only for an event that could be sent at all.
                let input = isExcluded ? nil : EventNotesPolicy.input(
                    for: event, day: day, settings: settings, excludedEventIDs: excluded,
                    excludedCalendarEvents: event.endsAt <= now ? try await excludedCalendarEvents(around: event, settings: settings) : []
                )
                let decision = EventNotesTrigger.decide(
                    event: event,
                    now: now,
                    settings: settings,
                    isExcluded: isExcluded,
                    hasNote: try await database.lifeLog.generatedNote(kind: .eventNotes, scope: scope) != nil,
                    wasDeleted: try await database.lifeLog.isGeneratedNoteDismissed(kind: .eventNotes, scope: scope),
                    spokenCharacters: input?.spokenCharacters ?? 0,
                    oldestUntranscribedAudio: backlog
                )
                switch decision {
                case .generate:
                    do {
                        try await generate(kind: .eventNotes, scope: scope, automatic: true)
                    } catch {
                        automaticFailures.insert(scope.key)
                        LoreLog.session.error("Event notes generation failed: \(error.localizedDescription, privacy: .public)")
                    }
                case .waitUntil(let date):
                    nextWake = min(nextWake ?? date, date)
                case .waitForTranscription:
                    let date = now.addingTimeInterval(Self.transcriptionRetryInterval)
                    nextWake = min(nextWake ?? date, date)
                case .skip:
                    continue
                }
            }
        } catch { report(error) }
        guard let nextWake else { return }
        let delay = max(1, nextWake.timeIntervalSince(dependencies.now()))
        wakeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            // Drop the reference first, or the evaluation would cancel the task it runs in.
            self?.wakeTask = nil
            await self?.evaluateEventNotes()
        }
    }

    /// Decides the digest of yesterday and today and sleeps until the next digest time. Safe to call from
    /// any trigger source at any time: a day with a digest is never sent again.
    public func evaluateDailyDigest() async {
        digestWakeTask?.cancel()
        digestWakeTask = nil
        let settings = dependencies.settings()
        guard settings.sendPermission == .allowed, settings.dailyDigestTrigger == .automatic,
              let database = dependencies.database() else { return }
        var nextWake: Date?
        do {
            let now = dependencies.now()
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: now)
            let backlog = try await dependencies.oldestUntranscribedAudio()
            for offset in [-1, 0] {
                guard let date = calendar.date(byAdding: .day, value: offset, to: today),
                      let interval = calendar.dateInterval(of: .day, for: date) else { continue }
                let day = LifeLogDateKey.string(for: date)
                let scope = GeneratedNoteScope.day(day)
                guard !automaticFailures.contains(scope.key) else { continue }
                let digestTime = DailyDigestTrigger.digestTime(for: date, schedule: dependencies.lifeLogSchedule(), minute: settings.dailyDigestMinute)
                // The day is read only once its digest time has passed.
                let spoken = digestTime <= now
                    ? try await digestInput(day: day, date: date, interval: interval, settings: settings, database: database).spokenCharacters
                    : 0
                let decision = DailyDigestTrigger.decide(
                    day: date,
                    now: now,
                    digestTime: digestTime,
                    settings: settings,
                    hasDigest: try await database.lifeLog.generatedNote(kind: .dailyDigest, scope: scope) != nil,
                    wasDeleted: try await database.lifeLog.isGeneratedNoteDismissed(kind: .dailyDigest, scope: scope),
                    spokenCharacters: spoken,
                    oldestUntranscribedAudio: backlog
                )
                switch decision {
                case .generate:
                    do {
                        try await generate(kind: .dailyDigest, scope: scope, automatic: true)
                    } catch {
                        automaticFailures.insert(scope.key)
                        LoreLog.session.error("Daily digest generation failed: \(error.localizedDescription, privacy: .public)")
                    }
                case .waitUntil(let date):
                    nextWake = min(nextWake ?? date, date)
                case .waitForTranscription:
                    let date = now.addingTimeInterval(Self.transcriptionRetryInterval)
                    nextWake = min(nextWake ?? date, date)
                case .skip:
                    continue
                }
            }
            // Tomorrow's digest time, so a Mac that stays awake past midnight still makes it.
            if nextWake == nil, let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) {
                nextWake = DailyDigestTrigger.digestTime(for: tomorrow, schedule: dependencies.lifeLogSchedule(), minute: settings.dailyDigestMinute)
            }
        } catch { report(error) }
        guard let nextWake else { return }
        let delay = max(1, nextWake.timeIntervalSince(dependencies.now()))
        digestWakeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.digestWakeTask = nil
            await self?.evaluateDailyDigest()
        }
    }

    // MARK: Morning digest

    static let presentedDigestDayKey = "daily_digest_presented_day"

    /// Yesterday's digest the first time this is asked after it exists, nil every later time. The day is
    /// recorded before it is returned, so the sheet appears once even if the window closes at once.
    public func takeMorningDigest() async -> GeneratedNote? {
        guard let database = dependencies.database(),
              let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: dependencies.now())) else { return nil }
        let day = LifeLogDateKey.string(for: yesterday)
        do {
            guard try await database.meta.string(forKey: Self.presentedDigestDayKey) != day,
                  let digest = try await database.lifeLog.generatedNote(kind: .dailyDigest, scope: .day(day)) else { return nil }
            try await database.meta.setString(day, forKey: Self.presentedDigestDayKey)
            return digest
        } catch {
            report(error)
            return nil
        }
    }

    // MARK: Request count

    private func storedRequestCount(database: LoreDatabase) async throws -> Int {
        guard let value = try await database.meta.string(forKey: Self.requestCountKey) else { return 0 }
        let parts = value.split(separator: " ")
        guard parts.count == 2, String(parts[0]) == LifeLogDateKey.string(for: dependencies.now()), let count = Int(parts[1]) else { return 0 }
        return count
    }

    private func countRequest(database: LoreDatabase) async throws {
        let count = try await storedRequestCount(database: database) + 1
        try await database.meta.setString("\(LifeLogDateKey.string(for: dependencies.now())) \(count)", forKey: Self.requestCountKey)
        requestsToday = count
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
        LoreLog.session.error("Life Log AI failed: \(error.localizedDescription, privacy: .public)")
    }
}
