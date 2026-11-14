import Foundation

public enum KoeAutomationNotification {
    public static let dataChanged = Notification.Name("dev.agatan.Koe.automation.dataChanged")
}

/// CLIとMCPが共有する読み取り中心のユースケース。
@MainActor
public final class KoeAutomationService {
    public let database: KoeDatabase
    public let settings: AppSettings

    public init(database: KoeDatabase, settings: AppSettings) {
        self.database = database
        self.settings = settings
    }

    public static func openDefault() async throws -> KoeAutomationService {
        guard let defaults = UserDefaults(suiteName: "dev.agatan.Koe") else {
            throw AutomationError.preferencesUnavailable
        }
        return KoeAutomationService(database: try await KoeDatabase.openDefault(), settings: AppSettings(defaults: defaults))
    }

    public func exportDay(_ date: Date, options: LifeLogTextExporter.Options) async throws -> String {
        guard options.hasSelection else { throw AutomationError.emptyExportSelection }
        let day = try await database.lifeLog.day(
            date,
            participatingOnly: settings.lifeLogParticipatingEventsOnly
        )
        return LifeLogTextExporter.render(date: date, day: day, options: options)
    }

    public func search(_ query: String, limit: Int = 100) async throws -> [LifeLogSearchResult] {
        try await database.lifeLog.search(query, limit: limit)
    }
}

public enum AutomationError: LocalizedError, Sendable {
    case preferencesUnavailable
    case emptyExportSelection

    public var errorDescription: String? {
        switch self {
        case .preferencesUnavailable: "Koeの設定を開けませんでした"
        case .emptyExportSelection: "書き出す項目を1つ以上選んでください"
        }
    }
}
