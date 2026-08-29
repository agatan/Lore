import Foundation

/// 日別ライフログの自動書き出しで使う、フォルダ内の安全なファイル名。
public enum LifeLogExportFilename {
    public static let defaultTemplate = "lifelog-{{date}}.md"

    /// `{{date}}` は対象日の `yyyyMMdd` に展開する。
    /// 出力フォルダの外へ書けないよう、パス区切りを含む名前は受け付けない。
    public static func resolve(
        template: String,
        date: Date,
        calendar: Calendar = .current
    ) throws -> String {
        let template = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { throw LifeLogExportFilenameError.empty }

        let compactDate = LifeLogDateKey.string(for: date, calendar: calendar)
            .replacingOccurrences(of: "-", with: "")
        let filename = template.replacingOccurrences(of: "{{date}}", with: compactDate)

        guard !filename.contains("{{"), !filename.contains("}}") else {
            throw LifeLogExportFilenameError.unknownPlaceholder
        }
        guard filename != ".", filename != "..",
              filename.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:\0")) == nil else {
            throw LifeLogExportFilenameError.pathComponent
        }
        return filename
    }
}

public enum LifeLogExportFilenameError: LocalizedError, Equatable {
    case empty
    case unknownPlaceholder
    case pathComponent

    public var errorDescription: String? {
        switch self {
        case .empty:
            "ファイル名を入力してください。"
        case .unknownPlaceholder:
            "使用できるプレースホルダーは {{date}} だけです。"
        case .pathComponent:
            "ファイル名にはフォルダ名やパス区切りを含められません。"
        }
    }
}
