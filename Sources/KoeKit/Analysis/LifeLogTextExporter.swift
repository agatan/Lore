import Foundation

/// 人が日記として読みやすく、Markdownの構造をLLMもそのまま解釈できる書き出し形式。
public enum LifeLogTextExporter {
    public struct Options: Sendable, Equatable {
        public var includesCalendarEvents: Bool
        public var includesUtterances: Bool
        public var includesDictations: Bool
        public var includesMemos: Bool
        public var includesSummary: Bool
        public var includesTodosForDay: Bool

        public init(
            includesCalendarEvents: Bool = true,
            includesUtterances: Bool = true,
            includesDictations: Bool = true,
            includesMemos: Bool = true,
            includesSummary: Bool = true,
            includesTodosForDay: Bool = true
        ) {
            self.includesCalendarEvents = includesCalendarEvents
            self.includesUtterances = includesUtterances
            self.includesDictations = includesDictations
            self.includesMemos = includesMemos
            self.includesSummary = includesSummary
            self.includesTodosForDay = includesTodosForDay
        }

        public var hasSelection: Bool {
            includesCalendarEvents || includesUtterances || includesDictations || includesMemos || includesSummary || includesTodosForDay
        }
    }

    public static func render(
        date: Date,
        day: LifeLogDay,
        todos: [LifeLogTodo],
        options: Options = Options(),
        calendar: Calendar = .current
    ) -> String {
        let dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        var lines = ["# \(dateComponents.year ?? 0)年\(dateComponents.month ?? 0)月\(dateComponents.day ?? 0)日のライフログ", ""]

        if options.includesSummary, let summary = day.summary {
            lines.append("## 一日のまとめ")
            lines.append(summary.summary)
            if !summary.topics.isEmpty {
                lines.append("")
                lines.append("### 主な話題")
                lines.append(contentsOf: summary.topics.map { "- \($0)" })
            }
            lines.append("")
        }

        if options.includesCalendarEvents || options.includesUtterances || options.includesDictations || options.includesMemos {
            lines.append("## タイムライン")
            let items = (options.includesCalendarEvents ? day.calendarEvents.map { Item(date: $0.startsAt, line: eventLine($0, calendar: calendar)) } : [])
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

        let createdTodos = todos.filter {
            $0.status != .draft && calendar.isDate($0.createdAt, inSameDayAs: date)
        }
        let completedTodos = todos.filter {
            $0.status == .completed && $0.completedAt.map { calendar.isDate($0, inSameDayAs: date) } == true
        }
        if options.includesTodosForDay {
            if !createdTodos.isEmpty {
                lines.append("")
                lines.append("## この日発生したタスク")
                lines.append(contentsOf: createdTodos.map { todoLine($0, calendar: calendar) })
            }
            if !completedTodos.isEmpty {
                lines.append("")
                lines.append("## この日完了したタスク")
                lines.append(contentsOf: completedTodos.map { completedTodoLine($0, calendar: calendar) })
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func renderOpenTodos(_ todos: [LifeLogTodo], calendar: Calendar = .current) -> String {
        var lines = ["# 未実施TODO", ""]
        let open = todos.filter { $0.status == .open }.sorted { $0.createdAt < $1.createdAt }
        if open.isEmpty {
            lines.append("未実施のTODOはありません。")
        } else {
            lines.append(contentsOf: open.map { todoLine($0, calendar: calendar) })
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private struct Item {
        var date: Date
        var line: String
        var speechEnd: Date? = nil
    }

    private static func eventLine(_ value: CalendarEventSnapshot, calendar: Calendar) -> String {
        let schedule = value.isAllDay
            ? "終日"
            : "\(time(value.startsAt, calendar: calendar))–\(time(value.endsAt, calendar: calendar))"
        return "- **\(schedule) 予定** \(readable(value.title))（\(readable(value.calendarTitle))）"
    }

    private static func dictationLine(_ value: LifeLogDictation, calendar: Calendar) -> String {
        "- **\(time(value.startedAt, calendar: calendar)) 音声入力** \(readable(value.text))"
    }

    private static func memoLine(_ value: LifeLogMemo, calendar: Calendar) -> String {
        "- **\(time(value.createdAt, calendar: calendar)) メモ** \(readable(value.text))"
    }

    private static func todoLine(_ value: LifeLogTodo, calendar: Calendar) -> String {
        let due = value.dueAt.map { "、期限 \(LifeLogDateKey.string(for: $0, calendar: calendar))" } ?? ""
        return "- [\(value.status == .completed ? "x" : " ")] \(readable(value.title))（\(time(value.createdAt, calendar: calendar))に追加\(due)）"
    }

    private static func completedTodoLine(_ value: LifeLogTodo, calendar: Calendar) -> String {
        let completed = value.completedAt.map { time($0, calendar: calendar) } ?? "時刻不明"
        return "- [x] \(readable(value.title))（\(completed)に完了）"
    }

    private static func time(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    private static func readable(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: "  \n  ")
    }
}
