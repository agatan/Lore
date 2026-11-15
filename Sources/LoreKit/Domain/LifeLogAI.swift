import Foundation

/// When Lore generates event notes on its own.
public enum EventNotesTriggerMode: String, Codable, Sendable, CaseIterable, Identifiable {
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
    public var eventNotesTrigger: EventNotesTriggerMode = .automatic
    public var notifiesWhenEventNotesReady = true

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = LifeLogAISettings()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? fallback.isEnabled
        backend = (try? container.decodeIfPresent(FormattingBackend.self, forKey: .backend)).flatMap { $0 } ?? fallback.backend
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? backend.defaultModel
        confirmedCloudBackend = (try? container.decodeIfPresent(FormattingBackend.self, forKey: .confirmedCloudBackend)).flatMap { $0 }
        excludedCalendars = try container.decodeIfPresent([String].self, forKey: .excludedCalendars) ?? []
        eventNotesTrigger = (try? container.decodeIfPresent(EventNotesTriggerMode.self, forKey: .eventNotesTrigger)).flatMap { $0 } ?? fallback.eventNotesTrigger
        notifiesWhenEventNotesReady = try container.decodeIfPresent(Bool.self, forKey: .notifiesWhenEventNotesReady) ?? fallback.notifiesWhenEventNotesReady
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
}

public enum GeneratedNoteScope: Hashable, Sendable {
    case event(EventOccurrence)

    public var key: String {
        switch self {
        case .event(let occurrence): "event:\(occurrence.eventID)@\(occurrence.day)"
        }
    }

    public var day: String {
        switch self {
        case .event(let occurrence): occurrence.day
        }
    }

    public var eventID: String? {
        switch self {
        case .event(let occurrence): occurrence.eventID
        }
    }
}

public struct GeneratedNoteItem: Codable, Sendable, Hashable {
    public var text: String
    public var owner: String?
    /// Timeline item ids (`u-<utterance id>`, `m-<memo id>`) the item was derived from. Never empty.
    public var sources: [String]

    public init(text: String, owner: String? = nil, sources: [String]) {
        self.text = text
        self.owner = owner
        self.sources = sources
    }
}

public enum GeneratedNoteSectionKind: String, Codable, Sendable, CaseIterable {
    case decisions
    case actionItems = "action_items"
    case openQuestions = "open_questions"
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
        self.sections = sections
        self.staleReasons = staleReasons
    }

    public var isEmpty: Bool { sections.allSatisfy(\.items.isEmpty) }

    public func items(_ kind: GeneratedNoteSectionKind) -> [GeneratedNoteItem] {
        sections.first { $0.kind == kind }?.items ?? []
    }

    public static func staleReasons(
        rangeStart: Date,
        rangeEnd: Date,
        event: CalendarEventSnapshot?,
        missingSourceCount: Int
    ) -> Set<GeneratedNoteStaleReason> {
        var reasons: Set<GeneratedNoteStaleReason> = []
        if let event {
            if abs(event.startsAt.timeIntervalSince(rangeStart)) >= 1 || abs(event.endsAt.timeIntervalSince(rangeEnd)) >= 1 {
                reasons.insert(.eventChanged)
            }
        } else {
            reasons.insert(.eventChanged)
        }
        if missingSourceCount > 0 { reasons.insert(.sourcesDeleted) }
        return reasons
    }
}
