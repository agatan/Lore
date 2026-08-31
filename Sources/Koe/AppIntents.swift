import AppIntents
import AppKit
import KoeKit
import UniformTypeIdentifiers

struct StartLifeLogIntent: AppIntent {
    static let title: LocalizedStringResource = "ライフログを開始"
    static let description = IntentDescription("Koeのライフログ記録を開始します。")
    static let supportedModes: IntentModes = .foreground(.immediate)

    func perform() async throws -> some IntentResult {
        try await LifeLogIntentAction.startCapture()
        return .result()
    }
}

struct StopLifeLogIntent: AppIntent {
    static let title: LocalizedStringResource = "ライフログを終了"
    static let description = IntentDescription("Koeのライフログ記録を終了し、保存と文字起こしが確定するまで待ちます。")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult {
        try await LifeLogIntentAction.stopCaptureAndWait()
        return .result()
    }
}

struct CopyTodayLifeLogIntent: AppIntent {
    static let title: LocalizedStringResource = "ライフログを書き出してコピー"
    static let description = IntentDescription("予定・発話・音声入力・メモを、読みやすいMarkdownとしてクリップボードへコピーします。")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "対象日（未指定なら今日）", description: "空欄のまま実行すると、その時点の今日を書き出します。", kind: .date)
    var date: Date?
    @Parameter(title: "予定", default: true) var includesCalendarEvents: Bool
    @Parameter(title: "発話", default: true) var includesUtterances: Bool
    @Parameter(title: "音声入力", default: true) var includesDictations: Bool
    @Parameter(title: "メモ", default: true) var includesMemos: Bool
    @Parameter(title: "要約", default: true) var includesSummary: Bool
    @Parameter(title: "この日に作成・完了したTODO", default: true) var includesTodosForDay: Bool

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
              includesDictations: includesDictations,
              includesMemos: includesMemos, includesSummary: includesSummary,
              includesTodosForDay: includesTodosForDay)
    }
}

struct ExportTodayLifeLogIntent: AppIntent {
    static let title: LocalizedStringResource = "ライフログをファイルにする"
    static let description = IntentDescription("日付を省略すると今日のライフログを書き出します。出力先フォルダを指定すると、そのフォルダへ直接保存します。")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "対象日（未指定なら今日）", description: "空欄のまま実行すると、その時点の今日を書き出します。", kind: .date)
    var date: Date?
    @Parameter(title: "出力先フォルダ（未指定なら次へ渡す）", description: "指定するとKoeが直接保存します。空欄なら、作成したファイルを次のアクションへ渡します。", supportedContentTypes: [.folder])
    var outputFolder: IntentFile?
    @Parameter(title: "ファイル名（{{date}}＝yyyyMMdd）", description: "例: lifelog-{{date}}.md は lifelog-20260830.md になります。", default: "lifelog-{{date}}.md")
    var filenameTemplate: String
    @Parameter(title: "予定", default: true) var includesCalendarEvents: Bool
    @Parameter(title: "発話", default: true) var includesUtterances: Bool
    @Parameter(title: "音声入力", default: true) var includesDictations: Bool
    @Parameter(title: "メモ", default: true) var includesMemos: Bool
    @Parameter(title: "要約", default: true) var includesSummary: Bool
    @Parameter(title: "この日に作成・完了したTODO", default: true) var includesTodosForDay: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("ライフログを \(\.$outputFolder) へ \(\.$filenameTemplate) で保存") {
            \.$date
            \.$includesCalendarEvents
            \.$includesUtterances
            \.$includesDictations
            \.$includesMemos
            \.$includesSummary
            \.$includesTodosForDay
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let targetDate = date ?? Date()
        let text = try await LifeLogIntentAction.exportText(for: targetDate, options: options)
        let filename = try LifeLogExportFilename.resolve(template: filenameTemplate, date: targetDate)
        let data = Data(text.utf8)
        let file: IntentFile
        if let outputFolder {
            guard let folderURL = outputFolder.fileURL else { throw LifeLogIntentError.invalidOutputFolder }
            let hasScopedAccess = folderURL.startAccessingSecurityScopedResource()
            defer { if hasScopedAccess { folderURL.stopAccessingSecurityScopedResource() } }
            guard try folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw LifeLogIntentError.invalidOutputFolder
            }
            let outputURL = folderURL.appending(path: filename, directoryHint: .notDirectory)
            try data.write(to: outputURL, options: .atomic)
            file = IntentFile(fileURL: outputURL, filename: filename, type: .plainText)
        } else {
            file = IntentFile(data: data, filename: filename, type: .plainText)
        }
        return .result(value: file)
    }

    private var options: LifeLogTextExporter.Options {
        .init(includesCalendarEvents: includesCalendarEvents, includesUtterances: includesUtterances,
              includesDictations: includesDictations,
              includesMemos: includesMemos, includesSummary: includesSummary,
              includesTodosForDay: includesTodosForDay)
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
        return .result(value: IntentFile(data: Data(text.utf8), filename: "Koe-Open-TODO.md", type: .plainText))
    }
}

enum LifeLogIntentAction {
    @MainActor
    static func startCapture() async throws {
        let environment = try await readyEnvironment()
        if !environment.settings.lifeLogAudioStorageConfirmed {
            environment.setLifeLogCaptureEnabled(true)
            throw LifeLogIntentError.audioStorageConsentRequired
        }
        environment.setLifeLogCaptureEnabled(true)
    }

    @MainActor
    static func stopCaptureAndWait() async throws {
        let environment = try await readyEnvironment()
        environment.setLifeLogCaptureEnabled(false)
        guard await environment.lifeLog.stopAndWait() else {
            throw LifeLogIntentError.finalizationTimedOut
        }
    }

    @MainActor
    static func exportText(for date: Date, options: LifeLogTextExporter.Options) async throws -> String {
        guard options.hasSelection else { throw LifeLogIntentError.emptyExportSelection }
        let environment = try await readyEnvironment()
        guard let database = environment.database else {
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
        let environment = try await readyEnvironment()
        guard let database = environment.database else {
            throw LifeLogIntentError.appNotReady
        }
        return LifeLogTextExporter.renderOpenTodos(try await database.lifeLog.todos())
    }

    @MainActor
    private static func readyEnvironment() async throws -> AppEnvironment {
        guard let environment = AppEnvironment.current else {
            throw LifeLogIntentError.appNotReady
        }
        await environment.boot()
        guard environment.bootError == nil, environment.database != nil else {
            throw LifeLogIntentError.appNotReady
        }
        return environment
    }
}

enum LifeLogIntentError: LocalizedError {
    case appNotReady
    case audioStorageConsentRequired
    case clipboardWriteFailed
    case emptyExportSelection
    case invalidOutputFolder
    case finalizationTimedOut

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
        case .invalidOutputFolder:
            "書き出し先のフォルダを選び直してください。"
        case .finalizationTimedOut:
            "保存と文字起こしの完了を待てませんでした。保存済み音声は次回起動時に再処理されます。"
        }
    }
}
