import Foundation

/// 人が日記として読みやすく、Markdownの構造をLLMもそのまま解釈できる書き出し形式。
public enum LifeLogTextExporter {
    public struct Options: Sendable, Equatable {
        public var includesCalendarEvents: Bool
        public var includesUtterances: Bool
        public var includesDictations: Bool
        public var includesMemos: Bool
        /// Off by default: AI notes are derived text and join an export only when asked for.
        public var includesAINotes: Bool
        /// Off by default: the description and attendees of each event, which hold other people's email addresses.
        public var includesEventDetails: Bool

        public init(
            includesCalendarEvents: Bool = true,
            includesUtterances: Bool = true,
            includesDictations: Bool = true,
            includesMemos: Bool = true,
            includesAINotes: Bool = false,
            includesEventDetails: Bool = false
        ) {
            self.includesCalendarEvents = includesCalendarEvents
            self.includesUtterances = includesUtterances
            self.includesDictations = includesDictations
            self.includesMemos = includesMemos
            self.includesAINotes = includesAINotes
            self.includesEventDetails = includesEventDetails
        }

        public var hasSelection: Bool {
            includesCalendarEvents || includesUtterances || includesDictations || includesMemos || includesAINotes
        }

        /// The `include` names of the MCP tools. Only a day export takes `ai-notes` and `event-details`.
        public static func unknownIncludeNames(in names: Set<String>, isExport: Bool) -> [String] {
            let allowed = Set(["calendar", "speech", "voice-input", "memos"] + (isExport ? ["ai-notes", "event-details"] : []))
            return names.subtracting(allowed).sorted()
        }

        /// Only the named kinds are on. Check `unknownIncludeNames` first: an unknown name is ignored here.
        public init(includeNames names: Set<String>) {
            self.init(
                includesCalendarEvents: names.contains("calendar"),
                includesUtterances: names.contains("speech"),
                includesDictations: names.contains("voice-input"),
                includesMemos: names.contains("memos"),
                includesAINotes: names.contains("ai-notes"),
                includesEventDetails: names.contains("event-details")
            )
        }
    }

    public static func render(
        date: Date,
        day: LifeLogDay,
        options: Options = Options(),
        eventDetails: [CalendarEventDetails] = [],
        calendar: Calendar = .current
    ) -> String {
        let dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        var lines = ["# \(dateComponents.year ?? 0)年\(dateComponents.month ?? 0)月\(dateComponents.day ?? 0)日のライフログ", ""]

        if options.includesCalendarEvents || options.includesUtterances || options.includesDictations || options.includesMemos {
            lines.append("## タイムライン")
            let items = (options.includesCalendarEvents ? day.calendarEvents.map { Item(date: $0.startsAt, line: eventLine($0, details: options.includesEventDetails ? eventDetails.occurrence(eventID: $0.id, startsAt: $0.startsAt) : nil, calendar: calendar)) } : [])
                + (options.includesUtterances ? day.utterances.map { Item(date: $0.startedAt, line: $0.text, speechEnd: $0.endedAt) } : [])
                + (options.includesDictations ? day.dictations.map { Item(date: $0.startedAt, line: dictationLine($0, calendar: calendar)) } : [])
                + (options.includesMemos ? day.memos.map { Item(date: $0.createdAt, line: memoLine($0, calendar: calendar)) } : [])
            if items.isEmpty {
                lines.append("記録はありません。")
            } else {
                var speechStart: Date?
                var speechEnd: Date?
                var speech: [String] = []
                func flushSpeech() {
                    guard let start = speechStart, let end = speechEnd else { return }
                    lines.append("- **\(time(start, calendar: calendar))–\(time(end, calendar: calendar)) 発話** \(readable(speech.joined(separator: " ")))")
                    speechStart = nil
                    speechEnd = nil
                    speech.removeAll(keepingCapacity: true)
                }
                for item in items.sorted(by: { $0.date < $1.date }) {
                    if let end = item.speechEnd {
                        if let previousEnd = speechEnd, item.date.timeIntervalSince(previousEnd) >= 90 { flushSpeech() }
                        if speechStart == nil { speechStart = item.date }
                        speechEnd = max(speechEnd ?? end, end)
                        speech.append(item.line)
                    } else {
                        flushSpeech()
                        lines.append(item.line)
                    }
                }
                flushSpeech()
            }
        }

        if options.includesAINotes {
            lines += ["", "## AIが生成したノート"]
            if day.generatedNotes.isEmpty {
                lines.append("AIが生成したノートはありません。")
            }
            for note in day.generatedNotes {
                let title = day.event(of: note, calendar: calendar)?.title ?? "予定"
                lines += ["", GeneratedNoteMarkdown.render(note, title: title, headingLevel: 3, calendar: calendar)
                    .trimmingCharacters(in: .newlines)]
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private struct Item {
        var date: Date
        var line: String
        var speechEnd: Date? = nil
    }

    private static func eventLine(_ value: CalendarEventSnapshot, details: CalendarEventDetails?, calendar: Calendar) -> String {
        let schedule = value.isAllDay
            ? "終日"
            : "\(time(value.startsAt, calendar: calendar))–\(time(value.endsAt, calendar: calendar))"
        let line = "- **\(schedule) 予定** \(readable(value.title))（\(readable(value.calendarTitle))）"
        return ([line] + (details.map(detailLines) ?? [])).joined(separator: "\n")
    }

    /// Indented under the event line. Nothing for a missing description or no attendees.
    private static func detailLines(_ details: CalendarEventDetails) -> [String] {
        var lines: [String] = []
        if let notes = details.notes?.nonBlank {
            lines.append("  - 説明:")
            lines += notes.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { $0.isEmpty ? "" : "    \($0)" }
        }
        let attendees = details.attendees.map { attendee -> String in
            let name = [attendee.name?.nonBlank, attendee.email?.nonBlank.map { "<\($0)>" }].compactMap(\.self).joined(separator: " ")
            return "    - \(name.isEmpty ? "不明" : name)（\(attendee.status.rawValue), \(attendee.role.rawValue)）"
        }
        if !attendees.isEmpty { lines += ["  - 参加者:"] + attendees }
        return lines
    }

    private static func dictationLine(_ value: LifeLogDictation, calendar: Calendar) -> String {
        "- **\(time(value.startedAt, calendar: calendar)) 音声入力** \(readable(value.text))"
    }

    private static func memoLine(_ value: LifeLogMemo, calendar: Calendar) -> String {
        "- **\(time(value.createdAt, calendar: calendar)) メモ** \(readable(value.text))"
    }

    private static func time(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    private static func readable(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: "  \n  ")
    }
}

extension String {
    /// The text without surrounding whitespace, or nil when nothing is left.
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
