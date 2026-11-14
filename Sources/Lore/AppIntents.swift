import AppIntents
import LoreKit

struct StartLifeLogIntent: AppIntent {
    static let title: LocalizedStringResource = "ライフログを開始"
    static let description = IntentDescription("Loreのライフログ記録を開始します。")
    static let supportedModes: IntentModes = .foreground(.immediate)

    func perform() async throws -> some IntentResult {
        try await LifeLogIntentAction.startCapture()
        return .result()
    }
}

struct StopLifeLogIntent: AppIntent {
    static let title: LocalizedStringResource = "ライフログを終了"
    static let description = IntentDescription("Loreのライフログ記録を終了し、保存と文字起こしが確定するまで待ちます。")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult {
        try await LifeLogIntentAction.stopCaptureAndWait()
        return .result()
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
    case finalizationTimedOut

    var errorDescription: String? {
        switch self {
        case .appNotReady:
            "Loreの起動準備が完了していません。もう一度実行してください。"
        case .audioStorageConsentRequired:
            "Loreを開き、ライフログ音声の保存を一度確認してください。"
        case .finalizationTimedOut:
            "保存と文字起こしの完了を待てませんでした。保存済み音声は次回起動時に再処理されます。"
        }
    }
}
