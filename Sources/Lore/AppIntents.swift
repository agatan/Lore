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

struct PauseLifeLogIntent: AppIntent {
    static let title: LocalizedStringResource = "ライフログを一時停止"
    static let description = IntentDescription("Loreのライフログ記録を一時停止します。選んだ時間が過ぎると自動で再開します。")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "長さ", default: .thirtyMinutes)
    var length: LifeLogPauseLengthOption

    func perform() async throws -> some IntentResult {
        try await LifeLogIntentAction.pause(length.domainValue)
        return .result()
    }
}

struct ResumeLifeLogIntent: AppIntent {
    static let title: LocalizedStringResource = "ライフログを再開"
    static let description = IntentDescription("一時停止したLoreのライフログ記録を再開します。一時停止していなければ何もしません。")
    static let supportedModes: IntentModes = .foreground(.immediate)

    func perform() async throws -> some IntentResult {
        try await LifeLogIntentAction.resume()
        return .result()
    }
}

enum LifeLogPauseLengthOption: String, AppEnum {
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case untilEventEnds

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "一時停止の長さ"
    static let caseDisplayRepresentations: [LifeLogPauseLengthOption: DisplayRepresentation] = [
        .fifteenMinutes: "15分",
        .thirtyMinutes: "30分",
        .oneHour: "1時間",
        .untilEventEnds: "いまの予定が終わるまで",
    ]

    var domainValue: LifeLogPauseLength {
        switch self {
        case .fifteenMinutes: .fifteenMinutes
        case .thirtyMinutes: .thirtyMinutes
        case .oneHour: .oneHour
        case .untilEventEnds: .untilEventEnds
        }
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
    static func pause(_ length: LifeLogPauseLength) async throws {
        try await readyEnvironment().pauseLifeLog(length)
    }

    @MainActor
    static func resume() async throws {
        try await readyEnvironment().resumeLifeLog()
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
