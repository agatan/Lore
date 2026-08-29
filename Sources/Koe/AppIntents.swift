import AppIntents
import KoeKit

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

enum LifeLogIntentAction {
    @MainActor
    static func setCaptureEnabled(_ enabled: Bool) throws {
        guard let environment = AppEnvironment.current else {
            throw LifeLogIntentError.appNotReady
        }
        environment.setLifeLogCaptureEnabled(enabled)
    }
}

enum LifeLogIntentError: LocalizedError {
    case appNotReady

    var errorDescription: String? {
        "Koeの起動準備が完了していません。もう一度実行してください。"
    }
}
