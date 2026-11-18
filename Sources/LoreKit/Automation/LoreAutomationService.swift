import Foundation

/// MCPサーバーが使う読み取り専用のユースケース。
/// 雑なメモや発話を別アプリへ転記するのは外部AIの役割で、Loreへの書き戻しは提供しない。
@MainActor
public final class LoreAutomationService {
    public let database: LoreDatabase
    public let settings: AppSettings
    /// Nil: no event details are read, and event entries have the snapshot fields only.
    private let eventDetails: (any CalendarEventDetailsRangeReading)?

    /// 期間取得の上限。AIへ一度に返す量を抑え、DBを日ごとに読む回数を有界にする。
    public static let maximumRangeDays = 31
    public static let maximumDayListDays = 366

    public init(
        database: LoreDatabase,
        settings: AppSettings,
        eventDetails: (any CalendarEventDetailsRangeReading)? = nil
    ) {
        self.database = database
        self.settings = settings
        self.eventDetails = eventDetails
    }

    public static func openDefault(eventDetails: (any CalendarEventDetailsRangeReading)? = nil) async throws -> LoreAutomationService {
        guard let defaults = UserDefaults(suiteName: AppEnvironment.bundleIdentifier) else {
            throw AutomationError.preferencesUnavailable
        }
        // App本体より先にMCPサーバーが動いた場合も、旧Koeの設定とdataを同じ手順で移す。
        LegacyKoeMigration.migrateDefaults(legacyDomain: LegacyKoeMigration.legacyDefaultsDomain(), into: defaults)
        let (database, _) = try await LoreDatabase.openDefault()
        return LoreAutomationService(database: database, settings: AppSettings(defaults: defaults), eventDetails: eventDetails)
    }

    public func exportDay(
        _ date: Date,
        options: LifeLogTextExporter.Options,
        calendar: Calendar = .current
    ) async throws -> EventDetailsOutcome<String> {
        guard !options.includesEventDetails || options.includesCalendarEvents else {
            throw AutomationError.eventDetailsNeedCalendar
        }
        guard options.hasSelection else { throw AutomationError.emptyExportSelection }
        let day = try await database.lifeLog.day(
            date,
            calendar: calendar,
            participatingOnly: settings.lifeLogParticipatingEventsOnly
        )
        var outcome = EventDetailsOutcome(value: "")
        let details = options.includesEventDetails ? try await outcome.details(of: day.calendarEvents, from: eventDetails) : []
        outcome.value = LifeLogTextExporter.render(date: date, day: day, options: options, eventDetails: details, calendar: calendar)
        return outcome
    }

    public func search(_ query: String, limit: Int = 100) async throws -> [LifeLogSearchResult] {
        try await database.lifeLog.search(query, limit: limit)
    }

    /// 記録がある日だけを古い順に返す。画面と同じ発話projectionと予定filterで数える。
    public func days(
        from: Date? = nil,
        to: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> [LifeLogDayOverview] {
        let end = calendar.startOfDay(for: to ?? now)
        let start = calendar.startOfDay(for: from ?? calendar.date(byAdding: .day, value: -29, to: end)!)
        let dates = try Self.days(from: start, through: end, limit: Self.maximumDayListDays, calendar: calendar)
        var result: [LifeLogDayOverview] = []
        for date in dates {
            let day = try await database.lifeLog.day(
                date,
                calendar: calendar,
                participatingOnly: settings.lifeLogParticipatingEventsOnly
            )
            let overview = LifeLogDayOverview(day: LifeLogDateKey.string(for: date, calendar: calendar), contents: day)
            if !overview.isEmpty { result.append(overview) }
        }
        return result
    }

    /// 期間内の予定・発話・音声入力・memoを時刻順の構造化項目で返す。
    public func range(
        from: Date,
        to: Date? = nil,
        options: LifeLogTextExporter.Options = .init(),
        calendar: Calendar = .current
    ) async throws -> EventDetailsOutcome<[LifeLogEntry]> {
        guard options.hasSelection else { throw AutomationError.emptyExportSelection }
        let start = calendar.startOfDay(for: from)
        let dates = try Self.days(
            from: start,
            through: calendar.startOfDay(for: to ?? from),
            limit: Self.maximumRangeDays,
            calendar: calendar
        )
        var entries: [(date: Date, entry: LifeLogEntry)] = []
        var outcome = EventDetailsOutcome<[LifeLogEntry]>(value: [])
        var seenOccurrences = Set<EventOccurrence>()
        for date in dates {
            let day = try await database.lifeLog.day(
                date,
                calendar: calendar,
                participatingOnly: settings.lifeLogParticipatingEventsOnly
            )
            let details = options.includesCalendarEvents ? try await outcome.details(of: day.calendarEvents, from: eventDetails) : []
            // 日をまたぐ予定は各日のsnapshotに現れるため、期間内では1件にする。繰り返し予定は回ごとに残す。
            entries += LifeLogEntry.entries(of: day, options: options, eventDetails: details, calendar: calendar).filter {
                $0.entry.kind != .event
                    || seenOccurrences.insert(EventOccurrence(eventID: $0.entry.id, day: $0.entry.day)).inserted
            }
        }
        outcome.value = entries.sorted { ($0.date, $0.entry.id) < ($1.date, $1.entry.id) }.map(\.entry)
        return outcome
    }

    /// AI-generated notes whose day falls in the range, marked as generated, oldest first.
    public func aiNotes(
        from: Date? = nil,
        to: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> [GeneratedNoteEntry] {
        let end = calendar.startOfDay(for: to ?? now)
        let start = calendar.startOfDay(for: from ?? end)
        let dates = try Self.days(from: start, through: end, limit: Self.maximumRangeDays, calendar: calendar)
        guard let first = dates.first, let last = dates.last else { return [] }
        return try await database.lifeLog.generatedNotes(
            fromDay: LifeLogDateKey.string(for: first, calendar: calendar),
            throughDay: LifeLogDateKey.string(for: last, calendar: calendar)
        ).map(GeneratedNoteEntry.init)
    }

    private static func days(from start: Date, through end: Date, limit: Int, calendar: Calendar) throws -> [Date] {
        guard start <= end else { throw AutomationError.invalidRange }
        var dates: [Date] = []
        var cursor = start
        while cursor <= end {
            guard dates.count < limit else { throw AutomationError.rangeTooLong(limit) }
            dates.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        return dates
    }
}

/// One AI note as the MCP server returns it. `generated` is always true so a client never mistakes
/// it for something the user said or wrote.
public struct GeneratedNoteEntry: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var text: String
        public var owner: String?
        public var sources: [String]
        public var events: [String]
    }
    public struct Section: Codable, Sendable, Equatable {
        public var kind: String
        public var items: [Item]
    }

    public var id: String
    public var generated = true
    public var kind: String
    public var day: String
    public var eventId: String?
    public var start: String
    public var end: String
    public var provider: String
    public var model: String
    public var createdAt: String
    public var stale: [String]
    public var omittedSources: Int
    public var sourceUtteranceIds: [String]
    public var sourceMemoIds: [String]
    public var sections: [Section]

    init(_ note: GeneratedNote) {
        id = note.id
        kind = note.kind.rawValue
        day = note.scope.day
        eventId = note.scope.eventID
        start = LifeLogEntry.timestamp(note.rangeStart)
        end = LifeLogEntry.timestamp(note.rangeEnd)
        provider = note.backend.displayName
        model = note.model
        createdAt = LifeLogEntry.timestamp(note.createdAt)
        stale = note.staleReasons.map(\.rawValue).sorted()
        omittedSources = note.omittedSourceCount
        sourceUtteranceIds = note.sourceUtteranceIDs
        sourceMemoIds = note.sourceMemoIDs
        sections = note.sections.map { section in
            Section(kind: section.kind.rawValue, items: section.items.map { Item(text: $0.text, owner: $0.owner, sources: $0.sources, events: $0.events) })
        }
    }
}

/// 記録がある日の件数。AIが期間を選ぶための目次として使う。
public struct LifeLogDayOverview: Codable, Sendable, Equatable {
    public var day: String
    public var utterances: Int
    public var dictations: Int
    public var memos: Int
    public var events: Int
    /// timelineに残るlife-log発話の秒数。無音と音声入力と重なる区間は含めない。
    public var spokenSeconds: Int

    init(day: String, contents: LifeLogDay) {
        self.day = day
        utterances = contents.utterances.count
        dictations = contents.dictations.count
        memos = contents.memos.count
        events = contents.calendarEvents.count
        spokenSeconds = Int(contents.utterances.reduce(0) { $0 + max(0, $1.endedAt.timeIntervalSince($1.startedAt)) }.rounded())
    }

    var isEmpty: Bool { utterances + dictations + memos + events == 0 }
}

/// MCPが返すlife logの1項目。時刻はlocal時差付きISO8601文字列にする。
public struct LifeLogEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case event, utterance, dictation, memo }

    public var id: String
    public var kind: Kind
    public var day: String
    public var start: String
    public var end: String?
    public var text: String
    public var title: String?
    public var calendar: String?
    public var allDay: Bool?
    public var externalIdentifier: String?
    public var conferenceURL: String?
    public var description: String?
    public var organizer: Person?
    public var attendees: [Attendee]?

    public struct Person: Codable, Sendable, Equatable {
        public var name: String?
        public var email: String?
    }

    public struct Attendee: Codable, Sendable, Equatable {
        public var name: String?
        public var email: String?
        public var response: String
        public var role: String
    }

    static func entries(
        of day: LifeLogDay,
        options: LifeLogTextExporter.Options,
        eventDetails: [CalendarEventDetails] = [],
        calendar: Calendar
    ) -> [(date: Date, entry: LifeLogEntry)] {
        func key(_ date: Date) -> String { LifeLogDateKey.string(for: date, calendar: calendar) }
        var result: [(date: Date, entry: LifeLogEntry)] = []
        if options.includesCalendarEvents {
            result += day.calendarEvents.map {
                ($0.startsAt, LifeLogEntry(event: $0, details: eventDetails.occurrence(eventID: $0.id, startsAt: $0.startsAt), day: key($0.startsAt)))
            }
        }
        if options.includesUtterances {
            result += day.utterances.map {
                ($0.startedAt, LifeLogEntry(id: $0.id, kind: .utterance, day: key($0.startedAt), start: timestamp($0.startedAt),
                                            end: timestamp($0.endedAt), text: $0.text))
            }
        }
        if options.includesDictations {
            result += day.dictations.map {
                ($0.startedAt, LifeLogEntry(id: $0.id, kind: .dictation, day: key($0.startedAt), start: timestamp($0.startedAt),
                                            end: timestamp($0.endedAt), text: $0.text))
            }
        }
        if options.includesMemos {
            result += day.memos.map {
                ($0.createdAt, LifeLogEntry(id: $0.id, kind: .memo, day: key($0.createdAt), start: timestamp($0.createdAt), text: $0.text))
            }
        }
        return result
    }

    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// 時差付き、または小数秒付きのISO8601を受け付ける。
    static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

extension LifeLogEntry {
    /// The snapshot fields, plus the fields read from the calendar when `details` is found. A field with nothing to say is nil.
    init(event: CalendarEventSnapshot, details: CalendarEventDetails?, day: String) {
        self.init(id: event.id, kind: .event, day: day, start: Self.timestamp(event.startsAt), end: Self.timestamp(event.endsAt),
                  text: event.title, title: event.title, calendar: event.calendarTitle, allDay: event.isAllDay)
        externalIdentifier = (event.externalIdentifier ?? details?.externalIdentifier)?.nonBlank
        guard let details else { return }
        conferenceURL = details.conferenceLink?.url.absoluteString
        description = details.notes?.nonBlank
        let organizer = details.organizer.map { Person(name: $0.name?.nonBlank, email: $0.email?.nonBlank) }
        self.organizer = organizer.flatMap { $0.name == nil && $0.email == nil ? nil : $0 }
        let attendees = details.attendees.map {
            Attendee(name: $0.name?.nonBlank, email: $0.email?.nonBlank, response: $0.status.rawValue, role: $0.role.rawValue)
        }
        self.attendees = attendees.isEmpty ? nil : attendees
    }
}

/// A result whose events may lack details, with the reason when the details of the request could not be read.
public struct EventDetailsOutcome<Value: Sendable>: Sendable {
    public var value: Value
    /// The first failure of the request. Nil when details were read, or when no reader or no event was involved.
    public var unavailable: EventDetailsUnavailable?

    /// Reads the events from the calendar now, once for the span of `events`. Nothing is stored.
    /// After a failure the rest of the request is not asked again; other errors are thrown.
    mutating func details(
        of events: [CalendarEventSnapshot],
        from reader: (any CalendarEventDetailsRangeReading)?
    ) async throws -> [CalendarEventDetails] {
        guard let reader, unavailable == nil,
              let start = events.map(\.startsAt).min(), let end = events.map(\.endsAt).max() else { return [] }
        do {
            return try await reader.details(start: start, end: max(end, start.addingTimeInterval(1)))
        } catch let reason as EventDetailsUnavailable {
            unavailable = reason
            return []
        }
    }
}

public enum LifeLogJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

public enum AutomationError: LocalizedError, Sendable, Equatable {
    case preferencesUnavailable
    case emptyExportSelection
    case invalidRange
    case rangeTooLong(Int)
    case eventDetailsNeedCalendar

    public var errorDescription: String? {
        switch self {
        case .preferencesUnavailable: "Loreの設定を開けませんでした"
        case .emptyExportSelection: "書き出す項目を1つ以上選んでください"
        case .invalidRange: "開始日は終了日以前にしてください"
        case .rangeTooLong(let days): "期間は\(days)日以内にしてください"
        case .eventDetailsNeedCalendar: "event-detailsはcalendarと一緒に指定してください"
        }
    }
}
