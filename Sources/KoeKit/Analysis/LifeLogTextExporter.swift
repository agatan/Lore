import Foundation

/// LLMが予定・発話・メモの境界を保ったまま時系列を解釈できる、安定したテキスト形式。
public enum LifeLogTextExporter {
    public static func render(
        date: Date,
        day: LifeLogDay,
        todos: [LifeLogTodo],
        calendar: Calendar = .current
    ) -> String {
        var lines = [
            "# Koe Life Log Export v1",
            "DATE: \(LifeLogDateKey.string(for: date, calendar: calendar))",
            "",
        ]

        if let summary = day.summary {
            lines.append("## SUMMARY")
            lines.append(summary.summary)
            if !summary.topics.isEmpty { lines.append("TOPICS: \(summary.topics.joined(separator: ", "))") }
            if !summary.commitments.isEmpty { lines.append("COMMITMENTS: \(summary.commitments.joined(separator: " | "))") }
            lines.append("")
        }

        lines.append("## TIMELINE")
        let items = day.calendarEvents.map { Item(date: $0.startsAt, line: eventLine($0, calendar: calendar)) }
            + day.utterances.map { Item(date: $0.startedAt, line: utteranceLine($0, calendar: calendar)) }
            + day.memos.map { Item(date: $0.createdAt, line: memoLine($0, calendar: calendar)) }
        if items.isEmpty {
            lines.append("(empty)")
        } else {
            lines.append(contentsOf: items.sorted { $0.date < $1.date }.map(\.line))
        }

        let utteranceIDs = Set(day.utterances.map(\.id))
        let memoIDs = Set(day.memos.map(\.id))
        let relatedTodos = todos.filter { todo in
            !utteranceIDs.isDisjoint(with: todo.sourceUtteranceIDs)
                || !memoIDs.isDisjoint(with: todo.sourceMemoIDs)
                || (todo.sourceUtteranceIDs.isEmpty && todo.sourceMemoIDs.isEmpty
                    && calendar.isDate(todo.createdAt, inSameDayAs: date))
        }
        if !relatedTodos.isEmpty {
            lines.append("")
            lines.append("## TODO")
            lines.append(contentsOf: relatedTodos.map { "[TODO status=\($0.status.rawValue)] \($0.title)" })
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
        "[SPEECH \(time(value.startedAt, calendar: calendar))-\(time(value.endedAt, calendar: calendar))] \(value.text)"
    }

    private static func memoLine(_ value: LifeLogMemo, calendar: Calendar) -> String {
        "[MEMO \(time(value.createdAt, calendar: calendar))] \(value.text)"
    }

    private static func time(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", components.hour ?? 0, components.minute ?? 0, components.second ?? 0)
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
