import Foundation

/// One labeled line of a Life Log AI request. The label is what the model cites; the timeline id is
/// where a cited item jumps to.
public struct GeneratedNoteSource: Sendable, Equatable {
    public enum Kind: String, Sendable { case utterance, memo, event, note }

    public var label: String
    public var kind: Kind
    public var timelineID: String
    public var recordID: String
    public var at: Date
    /// The end of an event. Other kinds are points in time.
    public var end: Date?
    public var text: String

    public init(label: String = "", kind: Kind, timelineID: String, recordID: String, at: Date, end: Date? = nil, text: String) {
        self.label = label
        self.kind = kind
        self.timelineID = timelineID
        self.recordID = recordID
        self.at = at
        self.end = end
        self.text = text
    }

    init(utterance: LifeLogUtterance) {
        self.init(kind: .utterance, timelineID: "u-\(utterance.id)", recordID: utterance.id, at: utterance.startedAt, text: utterance.text)
    }

    init(memo: LifeLogMemo) {
        self.init(kind: .memo, timelineID: "m-\(memo.id)", recordID: memo.id, at: memo.createdAt, text: memo.text)
    }

    /// Sorts by time and labels `S1`, `S2`, … in that order.
    static func labeled(_ sources: [GeneratedNoteSource]) -> [GeneratedNoteSource] {
        sources.enumerated()
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            .enumerated()
            .map { index, value in
                var source = value.element
                source.label = "S\(index + 1)"
                return source
            }
    }

    /// True when `start..<end` touches any excluded range. A point in time counts as a millisecond.
    static func overlaps(_ start: Date, _ end: Date, _ ranges: [Range<Date>]) -> Bool {
        ranges.contains { $0.lowerBound < max(end, start.addingTimeInterval(0.001)) && start < $0.upperBound }
    }

    func line(timeZone: TimeZone) -> String {
        let clock = Self.formatter("HH:mm:ss", timeZone: timeZone)
        let time = end.map { "\(Self.formatter("HH:mm", timeZone: timeZone).string(from: at))-\(Self.formatter("HH:mm", timeZone: timeZone).string(from: $0))" }
            ?? clock.string(from: at)
        return "\(label) [\(time)] \(kind.rawValue): \(text.replacingOccurrences(of: "\n", with: " "))\n"
    }

    static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}

/// Reads the one-item-per-line answer that every Life Log AI request asks for.
public enum GeneratedNoteResponse {
    public enum ParseError: LocalizedError, Sendable {
        case unreadable

        public var errorDescription: String? {
            String(lore: "AIの応答を読み取れませんでした")
        }
    }

    private static var itemPattern: Regex<(Substring, Substring, Substring, Substring?, Substring)> { /^\W*(SUMMARY|COMMIT|ASK|DECIDE)\W*\(([^)]*)\)\s*(?:\[([^\]]*)\])?\s*[:：]\s*(.+)$/ }

    /// Drops every item without a label that was actually sent, and every item of a section kind the
    /// request did not ask for, so nothing untraceable is stored. An answer with no readable line and
    /// no NONE is an error, not "nothing to note".
    public static func parse(_ output: String, sent: [GeneratedNoteSource], sections: [GeneratedNoteSectionKind]) throws -> [GeneratedNoteSection] {
        let byLabel = Dictionary(uniqueKeysWithValues: sent.map { ($0.label, $0) })
        var items: [GeneratedNoteSectionKind: [GeneratedNoteItem]] = [:]
        var understood = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.trimmingCharacters(in: .punctuationCharacters).uppercased() == "NONE" { understood = true; continue }
            guard let match = line.wholeMatch(of: itemPattern) else { continue }
            understood = true
            let kind: GeneratedNoteSectionKind = switch match.1 {
            case "SUMMARY": .summary
            case "COMMIT": .commitments
            case "ASK": .requests
            default: .decisions
            }
            guard sections.contains(kind) else { continue }
            var seen = Set<String>()
            let sources = match.2.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "、" })
                .compactMap { byLabel[String($0)]?.timelineID }
                .filter { seen.insert($0).inserted }
            let text = String(match.4).trimmingCharacters(in: .whitespaces)
            guard !sources.isEmpty, !text.isEmpty else { continue }
            let owner = kind == .requests ? match.3.map { String($0).trimmingCharacters(in: .whitespaces) } : nil
            items[kind, default: []].append(GeneratedNoteItem(
                text: text,
                owner: owner.flatMap { $0.isEmpty || ["null", "none", "owner"].contains($0.lowercased()) ? nil : $0 },
                sources: sources
            ))
        }
        guard understood else { throw ParseError.unreadable }
        return sections.map { GeneratedNoteSection(kind: $0, items: items[$0] ?? []) }
    }
}
