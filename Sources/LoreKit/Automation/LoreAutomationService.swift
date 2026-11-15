import Foundation

/// CLIとMCPが共有する読み取り専用のユースケース。
/// 雑なメモや発話を別アプリへ転記するのは外部AIの役割で、Loreへの書き戻しは提供しない。
@MainActor
public final class LoreAutomationService {
    public let database: LoreDatabase
    public let settings: AppSettings

    /// 期間取得の上限。AIへ一度に返す量を抑え、DBを日ごとに読む回数を有界にする。
    public static let maximumRangeDays = 31
    public static let maximumDayListDays = 366

    public init(database: LoreDatabase, settings: AppSettings) {
        self.database = database
        self.settings = settings
    }

    public static func openDefault() async throws -> LoreAutomationService {
        guard let defaults = UserDefaults(suiteName: AppEnvironment.bundleIdentifier) else {
            throw AutomationError.preferencesUnavailable
        }
        // App本体より先にCLI/MCPが動いた場合も、旧Koeの設定とdataを同じ手順で移す。
        LegacyKoeMigration.migrateDefaults(legacyDomain: LegacyKoeMigration.legacyDefaultsDomain(), into: defaults)
        let (database, _) = try await LoreDatabase.openDefault()
        return LoreAutomationService(database: database, settings: AppSettings(defaults: defaults))
    }

    public func exportDay(_ date: Date, options: LifeLogTextExporter.Options) async throws -> String {
        guard options.hasSelection else { throw AutomationError.emptyExportSelection }
        let day = try await database.lifeLog.day(
            date,
            participatingOnly: settings.lifeLogParticipatingEventsOnly
        )
        return LifeLogTextExporter.render(date: date, day: day, options: options)
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
    ) async throws -> [LifeLogEntry] {
        guard options.hasSelection else { throw AutomationError.emptyExportSelection }
        let start = calendar.startOfDay(for: from)
        let dates = try Self.days(
            from: start,
            through: calendar.startOfDay(for: to ?? from),
            limit: Self.maximumRangeDays,
            calendar: calendar
        )
        var entries: [(date: Date, entry: LifeLogEntry)] = []
        var seenEventIDs = Set<String>()
        for date in dates {
            let day = try await database.lifeLog.day(
                date,
                calendar: calendar,
                participatingOnly: settings.lifeLogParticipatingEventsOnly
            )
            // 日をまたぐ予定は各日のsnapshotに現れるため、期間内では1件にする。
            entries += LifeLogEntry.entries(of: day, options: options, calendar: calendar)
                .filter { $0.entry.kind != .event || seenEventIDs.insert($0.entry.id).inserted }
        }
        return entries.sorted { ($0.date, $0.entry.id) < ($1.date, $1.entry.id) }.map(\.entry)
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

/// One AI note as the CLI and MCP return it. `generated` is always true so a client never mistakes
/// it for something the user said or wrote.
public struct GeneratedNoteEntry: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var text: String
        public var owner: String?
        public var sources: [String]
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
        sourceUtteranceIds = note.sourceUtteranceIDs
        sourceMemoIds = note.sourceMemoIDs
        sections = note.sections.map { section in
            Section(kind: section.kind.rawValue, items: section.items.map { Item(text: $0.text, owner: $0.owner, sources: $0.sources) })
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

/// CLI/MCPが返すlife logの1項目。時刻はlocal時差付きISO8601文字列にする。
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

    static func entries(
        of day: LifeLogDay,
        options: LifeLogTextExporter.Options,
        calendar: Calendar
    ) -> [(date: Date, entry: LifeLogEntry)] {
        func key(_ date: Date) -> String { LifeLogDateKey.string(for: date, calendar: calendar) }
        var result: [(date: Date, entry: LifeLogEntry)] = []
        if options.includesCalendarEvents {
            result += day.calendarEvents.map {
                ($0.startsAt, LifeLogEntry(id: $0.id, kind: .event, day: key($0.startsAt), start: timestamp($0.startsAt),
                             end: timestamp($0.endsAt), text: $0.title, title: $0.title,
                             calendar: $0.calendarTitle, allDay: $0.isAllDay))
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

public enum LifeLogJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

public enum AutomationError: LocalizedError, Sendable {
    case preferencesUnavailable
    case emptyExportSelection
    case invalidRange
    case rangeTooLong(Int)

    public var errorDescription: String? {
        switch self {
        case .preferencesUnavailable: "Loreの設定を開けませんでした"
        case .emptyExportSelection: "書き出す項目を1つ以上選んでください"
        case .invalidRange: "開始日は終了日以前にしてください"
        case .rangeTooLong(let days): "期間は\(days)日以内にしてください"
        }
    }
}
