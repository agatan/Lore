import Foundation

/// What one daily-digest request may contain: the day's events, fresh event notes, memos, and
/// utterances, minus every range that the user excluded from AI.
public struct DailyDigestInput: Sendable, Equatable {
    public var day: String
    public var sources: [GeneratedNoteSource]
    /// Utterance text outside excluded ranges, counted before event notes replace utterances.
    public var spokenCharacters: Int
}

public enum DailyDigestPolicy {
    /// Below this much utterance text in the day there is nothing worth a digest.
    public static let minimumSpokenCharacters = 300
    public static let sections: [GeneratedNoteSectionKind] = [.summary, .commitments, .requests, .decisions]

    /// `day` is read without the participation filter, so exclusions see every event. Event titles are
    /// sent only for `listedEvents`, the ones the timeline shows.
    public static func input(
        dayKey: String,
        day: LifeLogDay,
        listedEvents: [CalendarEventSnapshot],
        settings: LifeLogAISettings,
        excludedEventIDs: Set<String>,
        excludedCalendarEvents: [CalendarEventSnapshot] = [],
        calendar: Calendar = .current
    ) -> DailyDigestInput {
        let excluded = settings.excludedRanges(in: day, excludedEventIDs: excludedEventIDs, excludedCalendarEvents: excludedCalendarEvents)
        let events = listedEvents.filter { !settings.excludes($0, excludedEventIDs: excludedEventIDs) }
        var eventSources: [GeneratedNoteSource] = []
        var noteSources: [GeneratedNoteSource] = []
        var summarizedRanges: [Range<Date>] = []
        for event in events {
            let occurrence = EventOccurrence(event, calendar: calendar)
            eventSources.append(GeneratedNoteSource(kind: .event, timelineID: occurrence.timelineItemID, recordID: event.id,
                                                    at: event.startsAt, end: event.endsAt, text: event.title))
            guard !event.isAllDay, let note = day.eventNotes(for: event, calendar: calendar), note.staleReasons.isEmpty else { continue }
            summarizedRanges.append(event.startsAt..<event.endsAt)
            for section in note.sections where section.kind != .summary {
                for item in section.items {
                    noteSources.append(GeneratedNoteSource(kind: .note, timelineID: occurrence.timelineItemID, recordID: note.id,
                                                           at: event.startsAt, text: "\(event.title) / \(Self.tag(section.kind)): \(item.text)"))
                }
            }
        }
        let utterances = day.utterances.filter { !GeneratedNoteSource.overlaps($0.startedAt, $0.endedAt, excluded) }
        let memos = day.memos.filter { !GeneratedNoteSource.overlaps($0.createdAt, $0.createdAt, excluded) }
        let rawUtterances = utterances
            .filter { utterance in !summarizedRanges.contains { $0.contains(utterance.startedAt) } }
            .map(GeneratedNoteSource.init(utterance:))
        return DailyDigestInput(
            day: dayKey,
            sources: GeneratedNoteSource.labeled(eventSources + noteSources + memos.map(GeneratedNoteSource.init(memo:)) + rawUtterances),
            spokenCharacters: utterances.reduce(0) { $0 + $1.text.count }
        )
    }

    private static func tag(_ kind: GeneratedNoteSectionKind) -> String {
        switch kind {
        case .summary: "summary"
        case .commitments: "commitment"
        case .requests: "request"
        case .decisions: "decision"
        }
    }

    /// The order in which kinds are kept when the day does not fit.
    static let priority: [GeneratedNoteSource.Kind] = [.event, .note, .memo, .utterance]

    /// The reduction rule. A kind that fits whole is sent whole. In the first kind that does not fit,
    /// every k-th source in time order, starting with the first, for the smallest k that fits. Kinds of
    /// lower priority are left out. `cost` is the characters one source takes in the prompt.
    public static func reduce(
        _ sources: [GeneratedNoteSource],
        budget: Int,
        cost: (GeneratedNoteSource) -> Int
    ) -> (sent: [GeneratedNoteSource], omitted: Int) {
        var remaining = budget
        var kept: [GeneratedNoteSource] = []
        for kind in priority {
            let tier = sources.filter { $0.kind == kind }
            guard !tier.isEmpty else { continue }
            let costs = tier.map(cost)
            if costs.reduce(0, +) <= remaining {
                kept += tier
                remaining -= costs.reduce(0, +)
                continue
            }
            for stride in 2...max(2, tier.count) {
                let picked = Swift.stride(from: 0, to: tier.count, by: stride)
                let total = picked.reduce(0) { $0 + costs[$1] }
                if total <= remaining {
                    kept += picked.map { tier[$0] }
                    break
                }
            }
            break
        }
        let ordered = GeneratedNoteSource.labeled(kept)
        return (ordered, sources.count - kept.count)
    }

    static let instructions = """
        You write a short digest of one day from a personal Life Log, covering the user's own side: what the user took on, what the user asked others for, and what the user decided.
        The Life Log records only the user's own microphone. In an online meeting it does not contain what the other participants said. Never claim that the digest covers what others said.
        Each source line has a label such as S1, a time, and text. A line whose text starts with a kind is that kind: "event:" (a calendar event title and its time), "note:" (an item of notes already written for an event), or "memo:" (written by the user). Every other line is an utterance: automatic speech recognition, which may contain errors.
        Answer with one item per line, in exactly one of these forms:
        SUMMARY (S1, S4): one line about what the day was about
        COMMIT (S2): something the user said they would do
        ASK (S3) [person]: something the user asked another person to do or answer, with the person in brackets only when a source names them
        DECIDE (S5): a decision the user made or agreed to
        Rules:
        - Write one to three SUMMARY lines first, then the other items.
        - Memos are always the user's own words. Utterances are speech recognition of this Mac's microphone: mostly the user's voice, but other voices in the room may appear, and no speaker is labeled.
        - Write an item only when the sources show it is the user's own commitment, request, or decision. Leave it out when you are unsure who said it.
        - Use only what the sources say. Do not invent commitments, requests, decisions, people, dates, or facts.
        - Put the labels of the supporting sources in the parentheses, separated by commas.
        - Keep each item to one short sentence, in the language of the sources.
        - If there is nothing to note, answer with the single line NONE.
        - Write nothing else.
        """

    /// The prompt, the sources that fit the engine budget, and how many were left out.
    public static func prompt(
        for input: DailyDigestInput,
        characterBudget: Int,
        timeZone: TimeZone = .current
    ) -> (prompt: FormattingPrompt, sent: [GeneratedNoteSource], omitted: Int) {
        let header = "Day: \(input.day)\nSources:\n"
        // Relabeling can lengthen a label, so each line is costed with the longest label it could get.
        let widest = "S\(input.sources.count)".count
        let (sent, omitted) = reduce(input.sources, budget: max(0, characterBudget - instructions.count - header.count)) { source in
            source.line(timeZone: timeZone).count - source.label.count + widest
        }
        let user = header + sent.map { $0.line(timeZone: timeZone) }.joined()
        return (FormattingPrompt(system: instructions, user: user), sent, omitted)
    }

    public static func parse(_ output: String, sent: [GeneratedNoteSource]) throws -> [GeneratedNoteSection] {
        try GeneratedNoteResponse.parse(output, sent: sent, sections: sections)
    }
}

/// When a day gets its digest on its own. Pure, so launch, wake, the timer, and finished transcription
/// reach the same answer for the same state.
public enum DailyDigestTrigger {
    /// The end of the scheduled window that starts on `day` when the schedule is on and the day is
    /// scheduled, otherwise `day` at `minute`.
    public static func digestTime(for day: Date, schedule: LifeLogSchedule, minute: Int, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: day)
        if let window = schedule.window(startingOn: start, calendar: calendar) { return window.end }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: start,
                             matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) ?? start
    }

    public static func decide(
        day: Date,
        now: Date,
        digestTime: Date,
        settings: LifeLogAISettings,
        hasDigest: Bool,
        wasDeleted: Bool,
        spokenCharacters: Int,
        oldestUntranscribedAudio: Date?,
        calendar: Calendar = .current
    ) -> GenerationDecision {
        guard settings.sendPermission == .allowed else { return .skip(.notAllowed) }
        guard settings.dailyDigestTrigger == .automatic else { return .skip(.manualTrigger) }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let start = calendar.startOfDay(for: day)
        guard start == today || start == yesterday else { return .skip(.outsideLookBack) }
        guard digestTime <= now else { return .waitUntil(digestTime) }
        guard !hasDigest else { return .skip(.alreadyGenerated) }
        guard !wasDeleted else { return .skip(.deletedByUser) }
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: start) ?? digestTime
        if let oldestUntranscribedAudio, oldestUntranscribedAudio < min(digestTime, dayEnd) { return .waitForTranscription }
        guard spokenCharacters >= DailyDigestPolicy.minimumSpokenCharacters else { return .skip(.tooLittleSpeech) }
        return .generate
    }
}

/// The numbers the "digest is ready" notification carries. Lore already shows them in the inspector.
public enum DailyDigestNotification {
    public static func body(_ summary: LifeLogDaySummary, events: Int) -> String {
        String(lore: "話した時間 \(duration(summary.spokenDuration))・予定\(events)件・メモ\(summary.memoCount)件")
    }

    static func duration(_ interval: TimeInterval) -> String {
        if interval > 0 && interval < 60 { return String(lore: "1分未満") }
        let minutes = max(0, Int((interval / 60).rounded()))
        let (hours, rest) = (minutes / 60, minutes % 60)
        if hours == 0 { return String(lore: "\(rest)分") }
        return rest == 0 ? String(lore: "\(hours)時間") : String(lore: "\(hours)時間\(rest)分")
    }
}
