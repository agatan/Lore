import Foundation

/// When Lore generates event notes or the daily digest on its own.
public enum GenerationTriggerMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic
    case manual

    public var id: String { rawValue }
}

/// The persisted Life Log AI setting. Off by default: nothing from the Life Log is sent until the
/// user turns it on, and a cloud backend also needs `confirmedCloudBackend` to match.
public struct LifeLogAISettings: Codable, Sendable, Equatable {
    public var isEnabled = false
    public var backend: FormattingBackend = .onDevice
    public var model: String = FormattingBackend.onDevice.defaultModel
    public var confirmedCloudBackend: FormattingBackend?
    public var excludedCalendars: [String] = []
    public var eventNotesTrigger: GenerationTriggerMode = .automatic
    public var notifiesWhenEventNotesReady = true
    public var dailyDigestTrigger: GenerationTriggerMode = .automatic
    /// Minutes after midnight. Used on days without a scheduled recording window.
    public var dailyDigestMinute = 18 * 60
    public var notifiesWhenDailyDigestReady = true

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = LifeLogAISettings()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? fallback.isEnabled
        backend = (try? container.decodeIfPresent(FormattingBackend.self, forKey: .backend)).flatMap { $0 } ?? fallback.backend
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? backend.defaultModel
        confirmedCloudBackend = (try? container.decodeIfPresent(FormattingBackend.self, forKey: .confirmedCloudBackend)).flatMap { $0 }
        excludedCalendars = try container.decodeIfPresent([String].self, forKey: .excludedCalendars) ?? []
        eventNotesTrigger = (try? container.decodeIfPresent(GenerationTriggerMode.self, forKey: .eventNotesTrigger)).flatMap { $0 } ?? fallback.eventNotesTrigger
        notifiesWhenEventNotesReady = try container.decodeIfPresent(Bool.self, forKey: .notifiesWhenEventNotesReady) ?? fallback.notifiesWhenEventNotesReady
        dailyDigestTrigger = (try? container.decodeIfPresent(GenerationTriggerMode.self, forKey: .dailyDigestTrigger)).flatMap { $0 } ?? fallback.dailyDigestTrigger
        dailyDigestMinute = min(max(try container.decodeIfPresent(Int.self, forKey: .dailyDigestMinute) ?? fallback.dailyDigestMinute, 0), 24 * 60 - 1)
        notifiesWhenDailyDigestReady = try container.decodeIfPresent(Bool.self, forKey: .notifiesWhenDailyDigestReady) ?? fallback.notifiesWhenDailyDigestReady
    }

    public enum SendPermission: Equatable, Sendable {
        case allowed
        case disabled
        case cloudConsentRequired(FormattingBackend)
    }

    /// The single rule that decides whether Life Log text may leave the store at all.
    public var sendPermission: SendPermission {
        guard isEnabled else { return .disabled }
        if backend.sendsTranscriptOffDevice, confirmedCloudBackend != backend {
            return .cloudConsentRequired(backend)
        }
        return .allowed
    }

    public func excludes(_ event: CalendarEventSnapshot, excludedEventIDs: Set<String>) -> Bool {
        excludedEventIDs.contains(event.id) || excludedCalendars.contains(event.calendarTitle)
    }

    /// Ranges whose text never joins a request. Snapshots cover only the calendars shown in the timeline,
    /// so the caller passes the events of excluded calendars read straight from the calendar. An all-day
    /// exclusion covers its whole span.
    public func excludedRanges(
        in day: LifeLogDay,
        excludedEventIDs: Set<String>,
        excludedCalendarEvents: [CalendarEventSnapshot]
    ) -> [Range<Date>] {
        (day.calendarEvents.filter { excludes($0, excludedEventIDs: excludedEventIDs) } + excludedCalendarEvents)
            .map { $0.startsAt..<$0.endsAt }
    }
}

/// One occurrence of a calendar event. EventKit gives every occurrence of a repeating event the
/// same identifier, so the day of the start keeps occurrences apart.
public struct EventOccurrence: Hashable, Codable, Sendable {
    public var eventID: String
    public var day: String

    public init(eventID: String, day: String) {
        self.eventID = eventID
        self.day = day
    }

    public init(_ event: CalendarEventSnapshot, calendar: Calendar = .current) {
        self.init(eventID: event.id, day: LifeLogDateKey.string(for: event.startsAt, calendar: calendar))
    }

    public var timelineItemID: String { "e-\(eventID)@\(day)" }
}

public enum GeneratedNoteKind: String, Codable, Sendable {
    case eventNotes = "event_notes"
    case dailyDigest = "daily_digest"
}

public enum GeneratedNoteScope: Hashable, Sendable {
    case event(EventOccurrence)
    /// A day key (`yyyy-MM-dd`).
    case day(String)

    public var key: String {
        switch self {
        case .event(let occurrence): "event:\(occurrence.eventID)@\(occurrence.day)"
        case .day(let day): "day:\(day)"
        }
    }

    public var day: String {
        switch self {
        case .event(let occurrence): occurrence.day
        case .day(let day): day
        }
    }

    public var eventID: String? {
        switch self {
        case .event(let occurrence): occurrence.eventID
        case .day: nil
        }
    }

    /// Where the note sits in the main window timeline.
    public var timelineItemID: String {
        switch self {
        case .event(let occurrence): occurrence.timelineItemID
        case .day: Self.digestTimelineItemID
        }
    }

    public static let digestTimelineItemID = "digest"
}

public struct GeneratedNoteItem: Codable, Sendable, Hashable {
    public var text: String
    public var owner: String?
    /// Timeline item ids (`u-<utterance id>`, `m-<memo id>`, or an event occurrence) the item was derived from. Never empty.
    public var sources: [String]
    /// Titles of the events the sources fall in, decided from the sources when a daily digest is made.
    /// Empty for event notes, which sit under their event, and for digests stored before this field.
    public var events: [String]

    public init(text: String, owner: String? = nil, sources: [String], events: [String] = []) {
        self.text = text
        self.owner = owner
        self.sources = sources
        self.events = events
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        sources = try container.decode([String].self, forKey: .sources)
        events = try container.decodeIfPresent([String].self, forKey: .events) ?? []
    }
}

public enum GeneratedNoteSectionKind: String, Codable, Sendable, CaseIterable {
    /// A few lines about what the day was about. Daily digest only.
    case summary
    case commitments
    /// What the user asked another person to do or answer. The item's owner is that person.
    case requests
    case decisions
}

public struct GeneratedNoteSection: Codable, Sendable, Hashable {
    public var kind: GeneratedNoteSectionKind
    public var items: [GeneratedNoteItem]

    public init(kind: GeneratedNoteSectionKind, items: [GeneratedNoteItem]) {
        self.kind = kind
        self.items = items
    }
}

public enum GeneratedNoteStaleReason: String, Codable, Sendable, Hashable, CaseIterable {
    /// The event moved, was edited, or left the snapshot after the note was made.
    case eventChanged = "event_changed"
    /// A source utterance or memo was deleted.
    case sourcesDeleted = "sources_deleted"
}

/// A stored note row that failed to decode. Saving a note for the same scope replaces the row.
public struct UnreadableGeneratedNote: Sendable, Hashable {
    public var id: String
    public var scopeKey: String
    public var reason: String

    public init(id: String, scopeKey: String, reason: String) {
        self.id = id
        self.scopeKey = scopeKey
        self.reason = reason
    }
}

public struct UnreadableGeneratedNotesError: LocalizedError, Sendable {
    public var notes: [UnreadableGeneratedNote]

    public init(notes: [UnreadableGeneratedNote]) { self.notes = notes }

    public var errorDescription: String? {
        String(lore: "読み込めないAIノートが\(notes.count)件あります。ノートを作り直すと置き換わります。")
    }
}

public struct GeneratedNote: Identifiable, Sendable, Hashable {
    public var id: String
    public var kind: GeneratedNoteKind
    public var scope: GeneratedNoteScope
    public var rangeStart: Date
    public var rangeEnd: Date
    public var backend: FormattingBackend
    public var model: String
    public var createdAt: Date
    public var sourceUtteranceIDs: [String]
    public var sourceMemoIDs: [String]
    /// Sources that did not fit the provider's input limit and were left out.
    public var omittedSourceCount: Int
    public var sections: [GeneratedNoteSection]
    /// Computed by the store on every read; never persisted.
    public var staleReasons: Set<GeneratedNoteStaleReason>

    public init(
        id: String = UUID().uuidString,
        kind: GeneratedNoteKind,
        scope: GeneratedNoteScope,
        rangeStart: Date,
        rangeEnd: Date,
        backend: FormattingBackend,
        model: String,
        createdAt: Date,
        sourceUtteranceIDs: [String],
        sourceMemoIDs: [String],
        omittedSourceCount: Int = 0,
        sections: [GeneratedNoteSection],
        staleReasons: Set<GeneratedNoteStaleReason> = []
    ) {
        self.id = id
        self.kind = kind
        self.scope = scope
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.backend = backend
        self.model = model
        self.createdAt = createdAt
        self.sourceUtteranceIDs = sourceUtteranceIDs
        self.sourceMemoIDs = sourceMemoIDs
        self.omittedSourceCount = omittedSourceCount
        self.sections = sections
        self.staleReasons = staleReasons
    }

    public var isEmpty: Bool { sections.allSatisfy(\.items.isEmpty) }

    /// What search matches: every item text, one per line.
    public var searchText: String {
        sections.flatMap(\.items).map(\.text).joined(separator: "\n")
    }

    public func items(_ kind: GeneratedNoteSectionKind) -> [GeneratedNoteItem] {
        sections.first { $0.kind == kind }?.items ?? []
    }

    /// `occurrence` is the snapshot of the note's event on its scope day, or nil when the event left that day.
    public static func staleReasons(
        rangeStart: Date,
        rangeEnd: Date,
        occurrence: CalendarEventSnapshot?,
        missingSourceCount: Int
    ) -> Set<GeneratedNoteStaleReason> {
        var reasons: Set<GeneratedNoteStaleReason> = []
        if let current = occurrence {
            if abs(current.startsAt.timeIntervalSince(rangeStart)) >= 1 || abs(current.endsAt.timeIntervalSince(rangeEnd)) >= 1 {
                reasons.insert(.eventChanged)
            }
        } else {
            reasons.insert(.eventChanged)
        }
        if missingSourceCount > 0 { reasons.insert(.sourcesDeleted) }
        return reasons
    }
}
