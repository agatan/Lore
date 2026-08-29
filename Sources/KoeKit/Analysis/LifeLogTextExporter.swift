import Foundation

/// LLMが予定・発話・メモの境界を保ったまま時系列を解釈できる、安定したテキスト形式。
public enum LifeLogTextExporter {
    public struct Options: Sendable, Equatable {
        public var includesCalendarEvents: Bool
        public var includesUtterances: Bool
        public var includesMemos: Bool
        public var includesSummary: Bool
        public var includesTodosForDay: Bool

        public init(
            includesCalendarEvents: Bool = true,
            includesUtterances: Bool = true,
            includesMemos: Bool = true,
            includesSummary: Bool = true,
            includesTodosForDay: Bool = true
        ) {
            self.includesCalendarEvents = includesCalendarEvents
            self.includesUtterances = includesUtterances
            self.includesMemos = includesMemos
            self.includesSummary = includesSummary
            self.includesTodosForDay = includesTodosForDay
        }

        public var hasSelection: Bool {
            includesCalendarEvents || includesUtterances || includesMemos || includesSummary || includesTodosForDay
        }
    }

    public static func render(
        date: Date,
        day: LifeLogDay,
        todos: [LifeLogTodo],
        options: Options = Options(),
        calendar: Calendar = .current
    ) -> String {
        var lines = [
            "# Koe Life Log Export v1",
            "DATE: \(LifeLogDateKey.string(for: date, calendar: calendar))",
            "",
        ]

        if options.includesSummary, let summary = day.summary {
            lines.append("## SUMMARY")
            lines.append(summary.summary)
            if !summary.topics.isEmpty { lines.append("TOPICS: \(summary.topics.joined(separator: ", "))") }
            if !summary.commitments.isEmpty { lines.append("COMMITMENTS: \(summary.commitments.joined(separator: " | "))") }
            lines.append("")
        }

        if options.includesCalendarEvents || options.includesUtterances || options.includesMemos {
            lines.append("## TIMELINE")
            let items = (options.includesCalendarEvents ? day.calendarEvents.map { Item(date: $0.startsAt, line: eventLine($0, calendar: calendar)) } : [])
                + (options.includesUtterances ? day.utterances.map { Item(date: $0.startedAt, line: utteranceLine($0, calendar: calendar)) } : [])
                + (options.includesUtterances ? day.dictations.map { Item(date: $0.startedAt, line: dictationLine($0, calendar: calendar)) } : [])
                + (options.includesMemos ? day.memos.map { Item(date: $0.createdAt, line: memoLine($0, calendar: calendar)) } : [])
            if items.isEmpty {
                lines.append("(empty)")
            } else {
                lines.append(contentsOf: items.sorted { $0.date < $1.date }.map(\.line))
            }
        }

        let createdTodos = todos.filter {
            $0.status == .open && calendar.isDate($0.createdAt, inSameDayAs: date)
        }
        let completedTodos = todos.filter {
            $0.status == .completed && $0.completedAt.map { calendar.isDate($0, inSameDayAs: date) } == true
        }
        if options.includesTodosForDay {
            if !createdTodos.isEmpty {
                lines.append("")
                lines.append("## OPEN TODO CREATED ON THIS DAY")
                lines.append(contentsOf: createdTodos.map { todoLine($0, calendar: calendar) })
            }
            if !completedTodos.isEmpty {
                lines.append("")
                lines.append("## TODO COMPLETED ON THIS DAY")
                lines.append(contentsOf: completedTodos.map { completedTodoLine($0, calendar: calendar) })
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func renderOpenTodos(_ todos: [LifeLogTodo], calendar: Calendar = .current) -> String {
        var lines = ["# Koe Open TODO Export v1", ""]
        let open = todos.filter { $0.status == .open }.sorted { $0.createdAt < $1.createdAt }
        if open.isEmpty {
            lines.append("(empty)")
        } else {
            lines.append(contentsOf: open.map { todoLine($0, calendar: calendar) })
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private struct Item {
        var date: Date
        var line: String
    }

    private static func eventLine(_ value: CalendarEventSnapshot, calendar: Calendar) -> String {
        "[CALENDAR \(time(value.startsAt, calendar: calendar))-\(time(value.endsAt, calendar: calendar)) rsvp=\(value.participationStatus.rawValue) calendar=\(quoted(value.calendarTitle))] \(value.title)"
    }

    private static func utteranceLine(_ value: LifeLogUtterance, calendar: Calendar) -> String {
        "[SPEECH \(time(value.startedAt, calendar: calendar))] \(value.text)"
    }

    private static func dictationLine(_ value: LifeLogDictation, calendar: Calendar) -> String {
        "[VOICE_INPUT \(time(value.startedAt, calendar: calendar))] \(value.text)"
    }

    private static func memoLine(_ value: LifeLogMemo, calendar: Calendar) -> String {
        "[MEMO \(time(value.createdAt, calendar: calendar))] \(value.text)"
    }

    private static func todoLine(_ value: LifeLogTodo, calendar: Calendar) -> String {
        let created = "\(LifeLogDateKey.string(for: value.createdAt, calendar: calendar))T\(time(value.createdAt, calendar: calendar))"
        let due = value.dueAt.map { " due=\(LifeLogDateKey.string(for: $0, calendar: calendar))" } ?? ""
        return "[TODO status=open created=\(created)\(due)] \(value.title)"
    }

    private static func completedTodoLine(_ value: LifeLogTodo, calendar: Calendar) -> String {
        let created = "\(LifeLogDateKey.string(for: value.createdAt, calendar: calendar))T\(time(value.createdAt, calendar: calendar))"
        let completed = value.completedAt.map { "\(LifeLogDateKey.string(for: $0, calendar: calendar))T\(time($0, calendar: calendar))" } ?? "unknown"
        return "[TODO status=completed created=\(created) completed=\(completed)] \(value.title)"
    }

    private static func time(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", components.hour ?? 0, components.minute ?? 0, components.second ?? 0)
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
