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
    static let title: LocalizedStringResource = "今日のライフログをコピー"
    static let description = IntentDescription("予定・発話・メモを、LLMが読みやすい時系列テキストとしてクリップボードへコピーします。")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await LifeLogIntentAction.exportText(for: Date())
        let copied = await MainActor.run {
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        }
        guard copied else { throw LifeLogIntentError.clipboardWriteFailed }
        return .result(dialog: "今日のライフログをコピーしました。")
    }
}

struct ExportTodayLifeLogIntent: AppIntent {
    static let title: LocalizedStringResource = "今日のライフログをファイルにする"
    static let description = IntentDescription("予定・発話・メモを、LLMが読みやすいテキストファイルとして次のショートカット処理へ渡します。")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let date = Date()
        let text = try await LifeLogIntentAction.exportText(for: date)
        let file = IntentFile(
            data: Data(text.utf8),
            filename: "Koe-LifeLog-\(LifeLogDateKey.string(for: date)).txt",
            type: .plainText
        )
        return .result(value: file)
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
    static func exportText(for date: Date) async throws -> String {
        guard let environment = AppEnvironment.current,
              let database = environment.database else {
            throw LifeLogIntentError.appNotReady
        }
        let day = try await database.lifeLog.day(
            date,
            participatingOnly: environment.settings.lifeLogParticipatingEventsOnly
        )
        let todos = try await database.lifeLog.todos()
        return LifeLogTextExporter.render(date: date, day: day, todos: todos)
    }
}

enum LifeLogIntentError: LocalizedError {
    case appNotReady
    case audioStorageConsentRequired
    case clipboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .appNotReady:
            "Koeの起動準備が完了していません。もう一度実行してください。"
        case .audioStorageConsentRequired:
            "Koeを開き、ライフログ音声の保存を一度確認してください。"
        case .clipboardWriteFailed:
            "クリップボードへ書き込めませんでした。"
        }
    }
}
