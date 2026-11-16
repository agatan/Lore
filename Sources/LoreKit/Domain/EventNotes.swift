import Foundation

/// What one event-notes request may contain. Built only from text inside the event range, minus
/// every range that the user excluded from AI.
public struct EventNotesInput: Sendable, Equatable {
    public var occurrence: EventOccurrence
    public var title: String
    public var start: Date
    public var end: Date
    public var sources: [GeneratedNoteSource]

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
        let excluded = settings.excludedRanges(in: day, excludedEventIDs: excludedEventIDs, excludedCalendarEvents: excludedCalendarEvents)
        func allowed(_ start: Date, _ end: Date) -> Bool {
            event.startsAt <= start && start < event.endsAt && !GeneratedNoteSource.overlaps(start, end, excluded)
        }
        let sources = GeneratedNoteSource.labeled(
            day.utterances.filter { allowed($0.startedAt, $0.endedAt) }.map(GeneratedNoteSource.init(utterance:))
                + day.memos.filter { allowed($0.createdAt, $0.createdAt) }.map(GeneratedNoteSource.init(memo:))
        )
        return EventNotesInput(
            occurrence: EventOccurrence(event, calendar: calendar),
            title: event.title,
            start: event.startsAt,
            end: event.endsAt,
            sources: sources
        )
    }

    static let instructions = """
        You write short notes of the user's own side of an event from a personal Life Log: what the user took on, what the user asked others for, and what the user decided.
        The Life Log records only the user's own microphone. In an online meeting it does not contain what the other participants said. Never claim that the notes cover the whole meeting or what others said.
        Each source line has a label such as S1, a time, a kind (utterance or memo), and text. Utterances are automatic speech recognition and may contain errors.
        Answer with one item per line, in exactly one of these forms:
        COMMIT (S1): something the user said they would do
        ASK (S2) [person]: something the user asked another person to do or answer, with the person in brackets only when a source names them
        DECIDE (S3): a decision the user made or agreed to
        Rules:
        - Memos are always the user's own words. Utterances are speech recognition of this Mac's microphone: mostly the user's voice, but other voices in the room may appear, and no speaker is labeled.
        - Write an item only when the sources show it is the user's own commitment, request, or decision. Leave it out when you are unsure who said it.
        - Use only what the sources say. Do not invent commitments, requests, decisions, people, dates, or facts.
        - Put the labels of the supporting sources in the parentheses, separated by commas.
        - Keep each item to one short sentence, in the language of the sources.
        - If there is nothing to note, answer with the single line NONE.
        - Write nothing else.
        """

    /// The prompt and the earliest sources that fit the engine budget. Only those sources count as cited.
    public static func prompt(
        for input: EventNotesInput,
        characterBudget: Int,
        timeZone: TimeZone = .current
    ) -> (prompt: FormattingPrompt, sent: [GeneratedNoteSource]) {
        let formatter = GeneratedNoteSource.formatter("yyyy-MM-dd HH:mm", timeZone: timeZone)
        var user = "Event: \(input.title)\nTime: \(formatter.string(from: input.start)) to \(formatter.string(from: input.end))\nSources:\n"
        let budget = max(0, characterBudget - instructions.count - user.count)
        var used = 0
        var sent: [GeneratedNoteSource] = []
        for source in input.sources {
            let line = source.line(timeZone: timeZone)
            guard used + line.count <= budget else { break }
            used += line.count
            user += line
            sent.append(source)
        }
        return (FormattingPrompt(system: instructions, user: user), sent)
    }

    public static func parse(_ output: String, sent: [GeneratedNoteSource]) throws -> [GeneratedNoteSection] {
        try GeneratedNoteResponse.parse(output, sent: sent, sections: [.commitments, .requests, .decisions])
    }
}

public enum GenerationSkipReason: Equatable, Sendable {
    case notAllowed
    case manualTrigger
    case allDay
    case outsideLookBack
    case alreadyGenerated
    case deletedByUser
    case excluded
    case tooLittleSpeech
}

public enum GenerationDecision: Equatable, Sendable {
    case generate
    case waitUntil(Date)
    case waitForTranscription
    case skip(GenerationSkipReason)
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
    ) -> GenerationDecision {
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
