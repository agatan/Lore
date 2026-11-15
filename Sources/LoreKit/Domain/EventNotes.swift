import Foundation

/// What one event-notes request may contain. Built only from text inside the event range, minus
/// every range that the user excluded from AI.
public struct EventNotesInput: Sendable, Equatable {
    public struct Source: Sendable, Equatable {
        public enum Kind: String, Sendable { case utterance, memo }
        public var label: String
        public var kind: Kind
        public var timelineID: String
        public var recordID: String
        public var at: Date
        public var text: String
    }

    public var occurrence: EventOccurrence
    public var title: String
    public var start: Date
    public var end: Date
    public var sources: [Source]

    public var spokenCharacters: Int {
        sources.filter { $0.kind == .utterance }.reduce(0) { $0 + $1.text.count }
    }
}

public enum EventNotesPolicy {
    /// Below this much utterance text in the range there is nothing worth a request.
    public static let minimumSpokenCharacters = 120

    public static func input(
        for event: CalendarEventSnapshot,
        day: LifeLogDay,
        settings: LifeLogAISettings,
        excludedEventIDs: Set<String>,
        excludedCalendarEvents: [CalendarEventSnapshot] = [],
        calendar: Calendar = .current
    ) -> EventNotesInput {
        // Snapshots cover only the calendars shown in the timeline, so the caller passes the events of
        // excluded calendars read straight from the calendar. An all-day exclusion covers its whole span.
        let excludedRanges = (day.calendarEvents.filter { settings.excludes($0, excludedEventIDs: excludedEventIDs) } + excludedCalendarEvents)
            .map { $0.startsAt..<$0.endsAt }
        func allowed(_ start: Date, _ end: Date) -> Bool {
            event.startsAt <= start && start < event.endsAt
                && !excludedRanges.contains { $0.lowerBound < max(end, start.addingTimeInterval(0.001)) && start < $0.upperBound }
        }
        let utterances = day.utterances.filter { allowed($0.startedAt, $0.endedAt) }
            .map { (at: $0.startedAt, kind: EventNotesInput.Source.Kind.utterance, timelineID: "u-\($0.id)", id: $0.id, text: $0.text) }
        let memos = day.memos.filter { allowed($0.createdAt, $0.createdAt) }
            .map { (at: $0.createdAt, kind: EventNotesInput.Source.Kind.memo, timelineID: "m-\($0.id)", id: $0.id, text: $0.text) }
        let sources = (utterances + memos)
            .sorted { $0.at < $1.at }
            .enumerated()
            .map { index, value in
                EventNotesInput.Source(label: "S\(index + 1)", kind: value.kind, timelineID: value.timelineID,
                                       recordID: value.id, at: value.at, text: value.text)
            }
        return EventNotesInput(
            occurrence: EventOccurrence(event, calendar: calendar),
            title: event.title,
            start: event.startsAt,
            end: event.endsAt,
            sources: sources
        )
    }

    static let instructions = """
        You write short meeting notes from a personal Life Log.
        The Life Log records only the user's own microphone. In an online meeting it does not contain what the other participants said. Never claim that the notes cover the whole meeting or what others said.
        Each source line has a label such as S1, a time, a kind (utterance or memo), and text. Utterances are automatic speech recognition and may contain errors.
        Answer with one item per line, in exactly one of these forms:
        DECISION (S1): a decision that was made
        ACTION (S2) [owner]: a task, with the owner in brackets only when a source names who will do it
        QUESTION (S3): a question that is still open
        Rules:
        - Use only what the sources say. Do not invent decisions, tasks, owners, dates, or facts.
        - Put the labels of the supporting sources in the parentheses, separated by commas.
        - Keep each item to one short sentence, in the language of the sources.
        - If there is nothing to note, answer with the single line NONE.
        - Write nothing else.
        """

    /// The prompt and the sources that fit the engine budget. Only those sources count as cited.
    public static func prompt(
        for input: EventNotesInput,
        characterBudget: Int,
        timeZone: TimeZone = .current
    ) -> (prompt: FormattingPrompt, sent: [EventNotesInput.Source]) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = timeZone
        clock.dateFormat = "HH:mm:ss"
        var user = "Event: \(input.title)\nTime: \(formatter.string(from: input.start)) to \(formatter.string(from: input.end))\nSources:\n"
        let budget = max(0, characterBudget - instructions.count - user.count)
        var used = 0
        var sent: [EventNotesInput.Source] = []
        for source in input.sources {
            let line = "\(source.label) [\(clock.string(from: source.at))] \(source.kind.rawValue): \(source.text)\n"
            guard used + line.count <= budget else { break }
            used += line.count
            user += line
            sent.append(source)
        }
        return (FormattingPrompt(system: instructions, user: user), sent)
    }

    public enum ParseError: LocalizedError, Sendable {
        case unreadable

        public var errorDescription: String? {
            String(lore: "AIの応答を読み取れませんでした")
        }
    }

    private static var itemPattern: Regex<(Substring, Substring, Substring, Substring?, Substring)> { /^\W*(DECISION|ACTION|QUESTION)\W*\(([^)]*)\)\s*(?:\[([^\]]*)\])?\s*[:：]\s*(.+)$/ }

    /// Reads one item per line. Drops every item without a label that was actually sent, so nothing
    /// untraceable is stored. An answer with no readable line and no NONE is an error, not "nothing to note".
    public static func parse(_ output: String, sent: [EventNotesInput.Source]) throws -> [GeneratedNoteSection] {
        let byLabel = Dictionary(uniqueKeysWithValues: sent.map { ($0.label, $0) })
        var items: [GeneratedNoteSectionKind: [GeneratedNoteItem]] = [:]
        var understood = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.trimmingCharacters(in: .punctuationCharacters).uppercased() == "NONE" { understood = true; continue }
            guard let match = line.wholeMatch(of: itemPattern) else { continue }
            understood = true
            let kind: GeneratedNoteSectionKind = switch match.1 {
            case "DECISION": .decisions
            case "ACTION": .actionItems
            default: .openQuestions
            }
            var seen = Set<String>()
            let sources = match.2.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "、" })
                .compactMap { byLabel[String($0)]?.timelineID }
                .filter { seen.insert($0).inserted }
            let text = String(match.4).trimmingCharacters(in: .whitespaces)
            guard !sources.isEmpty, !text.isEmpty else { continue }
            let owner = kind == .actionItems ? match.3.map { String($0).trimmingCharacters(in: .whitespaces) } : nil
            items[kind, default: []].append(GeneratedNoteItem(
                text: text,
                owner: owner.flatMap { $0.isEmpty || ["null", "none", "owner"].contains($0.lowercased()) ? nil : $0 },
                sources: sources
            ))
        }
        guard understood else { throw ParseError.unreadable }
        return GeneratedNoteSectionKind.allCases.map { GeneratedNoteSection(kind: $0, items: items[$0] ?? []) }
    }
}

public enum EventNotesSkipReason: Equatable, Sendable {
    case notAllowed
    case manualTrigger
    case allDay
    case outsideLookBack
    case alreadyGenerated
    case deletedByUser
    case excluded
    case tooLittleSpeech
}

public enum EventNotesDecision: Equatable, Sendable {
    case generate
    case waitUntil(Date)
    case waitForTranscription
    case skip(EventNotesSkipReason)
}

/// When an ended event gets notes on its own. Pure, so every trigger source (launch, wake, timer,
/// calendar refresh, transcription finished) reaches the same answer for the same state.
public enum EventNotesTrigger {
    /// Lets the burst that was running at the end of the event reach the store first.
    public static let settleTime: TimeInterval = 15

    public static func decide(
        event: CalendarEventSnapshot,
        now: Date,
        settings: LifeLogAISettings,
        isExcluded: Bool,
        hasNote: Bool,
        wasDeleted: Bool = false,
        spokenCharacters: Int,
        oldestUntranscribedAudio: Date?,
        calendar: Calendar = .current
    ) -> EventNotesDecision {
        guard settings.sendPermission == .allowed else { return .skip(.notAllowed) }
        guard settings.eventNotesTrigger == .automatic else { return .skip(.manualTrigger) }
        guard !event.isAllDay else { return .skip(.allDay) }
        // "Today" is the day that contains the earliest moment the event could become ready, so an
        // event that ends at midnight still counts for the day it ended on.
        guard event.endsAt >= calendar.startOfDay(for: now.addingTimeInterval(-settleTime)) else { return .skip(.outsideLookBack) }
        let ready = event.endsAt.addingTimeInterval(settleTime)
        guard ready <= now else { return .waitUntil(ready) }
        guard !hasNote else { return .skip(.alreadyGenerated) }
        guard !wasDeleted else { return .skip(.deletedByUser) }
        guard !isExcluded else { return .skip(.excluded) }
        if let oldestUntranscribedAudio, oldestUntranscribedAudio < event.endsAt { return .waitForTranscription }
        guard spokenCharacters >= EventNotesPolicy.minimumSpokenCharacters else { return .skip(.tooLittleSpeech) }
        return .generate
    }
}
