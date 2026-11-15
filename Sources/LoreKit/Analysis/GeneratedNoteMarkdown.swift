import Foundation

/// Markdown for one AI note, shared by "Copy as Markdown" and the day export.
/// It always says that the text is AI-generated and from which provider and model.
public enum GeneratedNoteMarkdown {
    public static func render(_ note: GeneratedNote, title: String, headingLevel: Int = 2, calendar: Calendar = .current) -> String {
        let heading = String(repeating: "#", count: max(1, headingLevel))
        let sub = heading + "#"
        var lines = [
            "\(heading) \(title)（\(time(note.rangeStart, calendar))–\(time(note.rangeEnd, calendar))）",
            "",
            "_AIが生成したノート（\(note.backend.displayName) / \(note.model)）。このMacのマイクの記録だけから作成。_",
        ]
        if note.staleReasons.contains(.eventChanged) { lines.append("_予定が変更されたため、内容が古い可能性があります。_") }
        if note.staleReasons.contains(.sourcesDeleted) { lines.append("_元の発話またはメモが削除されています。_") }
        if note.isEmpty {
            lines += ["", "記録する決定事項・やること・未解決の問いはありませんでした。"]
        }
        for section in note.sections where !section.items.isEmpty {
            lines += ["", "\(sub) \(sectionTitle(section.kind))"]
            for item in section.items {
                let owner = item.owner.map { "（\($0)）" } ?? ""
                lines.append("- \(item.text.replacingOccurrences(of: "\n", with: " "))\(owner)")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func sectionTitle(_ kind: GeneratedNoteSectionKind) -> String {
        switch kind {
        case .decisions: "決定事項"
        case .actionItems: "やること"
        case .openQuestions: "未解決の問い"
        }
    }

    private static func time(_ date: Date, _ calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}
