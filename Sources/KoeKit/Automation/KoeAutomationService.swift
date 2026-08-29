import Foundation

public enum KoeAutomationNotification {
    public static let dataChanged = Notification.Name("dev.agatan.Koe.automation.dataChanged")
    public static let settingsChanged = Notification.Name("dev.agatan.Koe.automation.settingsChanged")
}

@MainActor
public final class KoeAutomationService {
    public enum PromptKind: String, CaseIterable, Sendable {
        case summary
        case todo
    }

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
        return LifeLogTextExporter.render(date: date, day: day, todos: try await database.lifeLog.todos(), options: options)
    }

    public func exportOpenTodos() async throws -> String {
        LifeLogTextExporter.renderOpenTodos(try await database.lifeLog.todos())
    }

    public func todos(status: LifeLogTodo.Status? = nil) async throws -> [LifeLogTodo] {
        let values = try await database.lifeLog.todos()
        return status.map { status in values.filter { $0.status == status } } ?? values
    }

    @discardableResult
    public func addTodo(title: String, dueAt: Date? = nil) async throws -> LifeLogTodo {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw AutomationError.emptyTodoTitle }
        let todo = LifeLogTodo(title: title, dueAt: dueAt)
        try await database.lifeLog.save(todo: todo)
        notify(KoeAutomationNotification.dataChanged)
        return todo
    }

    @discardableResult
    public func updateTodo(id: String, title: String? = nil, status: LifeLogTodo.Status? = nil, dueAt: Date?? = nil) async throws -> LifeLogTodo {
        guard var todo = try await database.lifeLog.todo(id: id) else { throw AutomationError.todoNotFound(id) }
        if let title {
            let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw AutomationError.emptyTodoTitle }
            todo.title = value
        }
        if let status { todo.transition(to: status) }
        if let dueAt { todo.dueAt = dueAt }
        try await database.lifeLog.save(todo: todo)
        notify(KoeAutomationNotification.dataChanged)
        return todo
    }

    public func deleteTodo(id: String) async throws {
        guard try await database.lifeLog.todo(id: id) != nil else { throw AutomationError.todoNotFound(id) }
        try await database.lifeLog.deleteTodo(id: id)
        notify(KoeAutomationNotification.dataChanged)
    }

    public func search(_ query: String, limit: Int = 100) async throws -> [LifeLogSearchResult] {
        try await database.lifeLog.search(query, limit: limit)
    }

    public func prompt(_ kind: PromptKind) -> String {
        switch kind {
        case .summary: settings.lifeLogSummaryPrompt
        case .todo: settings.lifeLogTodoPrompt
        }
    }

    public func setPrompt(_ value: String, kind: PromptKind) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AutomationError.emptyPrompt }
        switch kind {
        case .summary: settings.lifeLogSummaryPrompt = value
        case .todo: settings.lifeLogTodoPrompt = value
        }
        notify(KoeAutomationNotification.settingsChanged)
    }

    private func notify(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

public enum AutomationError: LocalizedError, Sendable {
    case preferencesUnavailable
    case emptyExportSelection
    case emptyTodoTitle
    case todoNotFound(String)
    case emptyPrompt

    public var errorDescription: String? {
        switch self {
        case .preferencesUnavailable: "Koeの設定を開けませんでした"
        case .emptyExportSelection: "書き出す項目を1つ以上選んでください"
        case .emptyTodoTitle: "TODOのタイトルが空です"
        case .todoNotFound(let id): "TODOが見つかりません: \(id)"
        case .emptyPrompt: "プロンプトを空にはできません"
        }
    }
}
