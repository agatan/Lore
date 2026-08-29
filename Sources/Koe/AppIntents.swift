import AppIntents
import AppKit
import KoeKit
import UniformTypeIdentifiers

struct StartLifeLogIntent: AppIntent {
    static let title: LocalizedStringResource = "ライフログを開始"
    static let description = IntentDescription("Koeのライフログ記録を開始します。")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult {
        try await LifeLogIntentAction.setCaptureEnabled(true)
        return .result()
    }
}

struct StopLifeLogIntent: AppIntent {
    static let title: LocalizedStringResource = "ライフログを終了"
    static let description = IntentDescription("Koeのライフログ記録を終了し、一日の要約を更新します。")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult {
        try await LifeLogIntentAction.setCaptureEnabled(false)
        return .result()
    }
}

struct CopyTodayLifeLogIntent: AppIntent {
    static let title: LocalizedStringResource = "ライフログを書き出してコピー"
    static let description = IntentDescription("予定・発話・メモを、LLMが読みやすい時系列テキストとしてクリップボードへコピーします。")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "日付", description: "省略すると今日", kind: .date)
    var date: Date?
    @Parameter(title: "予定", default: true) var includesCalendarEvents: Bool
    @Parameter(title: "発話", default: true) var includesUtterances: Bool
    @Parameter(title: "メモ", default: true) var includesMemos: Bool
    @Parameter(title: "要約", default: true) var includesSummary: Bool
    @Parameter(title: "この日に作った未実施TODO", default: true) var includesOpenTodosCreatedOnDay: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await LifeLogIntentAction.exportText(for: date ?? Date(), options: options)
        let copied = await MainActor.run {
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        }
        guard copied else { throw LifeLogIntentError.clipboardWriteFailed }
        return .result(dialog: "ライフログをコピーしました。")
    }

    private var options: LifeLogTextExporter.Options {
        .init(includesCalendarEvents: includesCalendarEvents, includesUtterances: includesUtterances,
              includesMemos: includesMemos, includesSummary: includesSummary,
              includesOpenTodosCreatedOnDay: includesOpenTodosCreatedOnDay)
    }
}

struct ExportTodayLifeLogIntent: AppIntent {
    static let title: LocalizedStringResource = "ライフログをファイルにする"
    static let description = IntentDescription("予定・発話・メモを、LLMが読みやすいテキストファイルとして次のショートカット処理へ渡します。")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "日付", description: "省略すると今日", kind: .date)
    var date: Date?
    @Parameter(title: "予定", default: true) var includesCalendarEvents: Bool
    @Parameter(title: "発話", default: true) var includesUtterances: Bool
    @Parameter(title: "メモ", default: true) var includesMemos: Bool
    @Parameter(title: "要約", default: true) var includesSummary: Bool
    @Parameter(title: "この日に作った未実施TODO", default: true) var includesOpenTodosCreatedOnDay: Bool

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let date = date ?? Date()
        let text = try await LifeLogIntentAction.exportText(for: date, options: options)
        let file = IntentFile(
            data: Data(text.utf8),
            filename: "Koe-LifeLog-\(LifeLogDateKey.string(for: date)).txt",
            type: .plainText
        )
        return .result(value: file)
    }

    private var options: LifeLogTextExporter.Options {
        .init(includesCalendarEvents: includesCalendarEvents, includesUtterances: includesUtterances,
              includesMemos: includesMemos, includesSummary: includesSummary,
              includesOpenTodosCreatedOnDay: includesOpenTodosCreatedOnDay)
    }
}

struct CopyOpenTodosIntent: AppIntent {
    static let title: LocalizedStringResource = "未実施TODOをすべてコピー"
    static let description = IntentDescription("確定済みで未実施のTODO全体をクリップボードへコピーします。")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await LifeLogIntentAction.exportOpenTodos()
        let copied = await MainActor.run {
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        }
        guard copied else { throw LifeLogIntentError.clipboardWriteFailed }
        return .result(dialog: "未実施TODOをコピーしました。")
    }
}

struct ExportOpenTodosIntent: AppIntent {
    static let title: LocalizedStringResource = "未実施TODOをファイルにする"
    static let description = IntentDescription("確定済みで未実施のTODO全体をテキストファイルとして渡します。")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let text = try await LifeLogIntentAction.exportOpenTodos()
        return .result(value: IntentFile(data: Data(text.utf8), filename: "Koe-Open-TODO.txt", type: .plainText))
    }
}

enum LifeLogIntentAction {
    @MainActor
    static func setCaptureEnabled(_ enabled: Bool) throws {
        guard let environment = AppEnvironment.current else {
            throw LifeLogIntentError.appNotReady
        }
        if enabled, !environment.settings.lifeLogAudioStorageConfirmed {
            environment.setLifeLogCaptureEnabled(true)
            throw LifeLogIntentError.audioStorageConsentRequired
        }
        environment.setLifeLogCaptureEnabled(enabled)
    }

    @MainActor
    static func exportText(for date: Date, options: LifeLogTextExporter.Options) async throws -> String {
        guard options.hasSelection else { throw LifeLogIntentError.emptyExportSelection }
        guard let environment = AppEnvironment.current,
              let database = environment.database else {
            throw LifeLogIntentError.appNotReady
        }
        let day = try await database.lifeLog.day(
            date,
            participatingOnly: environment.settings.lifeLogParticipatingEventsOnly
        )
        let todos = try await database.lifeLog.todos()
        return LifeLogTextExporter.render(date: date, day: day, todos: todos, options: options)
    }

    @MainActor
    static func exportOpenTodos() async throws -> String {
        guard let database = AppEnvironment.current?.database else {
            throw LifeLogIntentError.appNotReady
        }
        return LifeLogTextExporter.renderOpenTodos(try await database.lifeLog.todos())
    }
}

enum LifeLogIntentError: LocalizedError {
    case appNotReady
    case audioStorageConsentRequired
    case clipboardWriteFailed
    case emptyExportSelection

    var errorDescription: String? {
        switch self {
        case .appNotReady:
            "Koeの起動準備が完了していません。もう一度実行してください。"
        case .audioStorageConsentRequired:
            "Koeを開き、ライフログ音声の保存を一度確認してください。"
        case .clipboardWriteFailed:
            "クリップボードへ書き込めませんでした。"
        case .emptyExportSelection:
            "書き出す項目を1つ以上選んでください。"
        }
    }
}
