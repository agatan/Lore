import AppKit
import Foundation
import KoeKit

@main
@MainActor
struct KoeCLI {
    static func main() async {
        do {
            let service = try await KoeAutomationService.openDefault()
            try await run(Array(CommandLine.arguments.dropFirst()), service: service)
        } catch {
            FileHandle.standardError.write(Data("koe: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(_ arguments: [String], service: KoeAutomationService) async throws {
        guard let command = arguments.first else { throw CLIError.usage(Self.usage) }
        switch command {
        case "export": try await export(Array(arguments.dropFirst()), service: service)
        case "todo": try await todo(Array(arguments.dropFirst()), service: service)
        case "prompt": try await prompt(Array(arguments.dropFirst()), service: service)
        case "search": try await search(Array(arguments.dropFirst()), service: service)
        case "help", "--help", "-h": print(usage)
        default: throw CLIError.usage("不明なコマンド: \(command)\n\n\(usage)")
        }
    }

    private static func export(_ arguments: [String], service: KoeAutomationService) async throws {
        guard let target = arguments.first else { throw CLIError.usage("使い方: koe export day|todos [options]") }
        let text: String
        let defaultFilename: String
        switch target {
        case "day":
            let date = try value(after: "--date", in: arguments).map(parseDay) ?? Date()
            let options = try exportOptions(value(after: "--include", in: arguments))
            text = try await service.exportDay(date, options: options)
            defaultFilename = "Koe-LifeLog-\(LifeLogDateKey.string(for: date)).txt"
        case "todos":
            text = try await service.exportOpenTodos()
            defaultFilename = "Koe-Open-TODO.txt"
        default: throw CLIError.usage("書き出し対象は day または todos です")
        }
        try write(text, arguments: arguments, defaultFilename: defaultFilename)
    }

    private static func todo(_ arguments: [String], service: KoeAutomationService) async throws {
        guard let action = arguments.first else { throw CLIError.usage("使い方: koe todo list|add|complete|reopen|delete") }
        switch action {
        case "list":
            let statusValue = value(after: "--status", in: arguments)
            let status = try statusValue.flatMap { value -> LifeLogTodo.Status? in
                if value == "all" { return nil }
                guard let parsed = LifeLogTodo.Status(rawValue: value) else { throw CLIError.invalidValue("status", value) }
                return parsed
            }
            for todo in try await service.todos(status: statusValue == nil ? .open : status) {
                print("\(todo.id)\t\(todo.status.rawValue)\t\(todo.title)")
            }
        case "add":
            let title = try positional(at: 1, in: arguments, label: "タイトル")
            let todo = try await service.addTodo(title: title)
            print(todo.id)
        case "complete", "reopen":
            let id = try positional(at: 1, in: arguments, label: "TODO ID")
            let todo = try await service.updateTodo(id: id, status: action == "complete" ? .completed : .open)
            print("\(todo.id)\t\(todo.status.rawValue)\t\(todo.title)")
        case "delete":
            try await service.deleteTodo(id: positional(at: 1, in: arguments, label: "TODO ID"))
        default: throw CLIError.usage("不明なTODO操作: \(action)")
        }
    }

    private static func prompt(_ arguments: [String], service: KoeAutomationService) async throws {
        guard let action = arguments.first else { throw CLIError.usage("使い方: koe prompt get|set summary|todo") }
        let kindValue = try positional(at: 1, in: arguments, label: "summary または todo")
        guard let kind = KoeAutomationService.PromptKind(rawValue: kindValue) else { throw CLIError.invalidValue("prompt", kindValue) }
        switch action {
        case "get": print(service.prompt(kind))
        case "set":
            let source = try positional(at: 2, in: arguments, label: "プロンプトまたは -")
            let text = source == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : source
            try service.setPrompt(text, kind: kind)
        default: throw CLIError.usage("不明なプロンプト操作: \(action)")
        }
    }

    private static func search(_ arguments: [String], service: KoeAutomationService) async throws {
        let query = try positional(at: 0, in: arguments, label: "検索語")
        let limit = try value(after: "--limit", in: arguments).map { value in
            guard let parsed = Int(value) else { throw CLIError.invalidValue("limit", value) }
            return parsed
        } ?? 100
        for result in try await service.search(query, limit: limit) {
            print("\(result.day)\t\(result.kind.rawValue)\t\(result.text.replacingOccurrences(of: "\n", with: " "))")
        }
    }

    private static func exportOptions(_ value: String?) throws -> LifeLogTextExporter.Options {
        guard let value else { return .init() }
        let names = Set(value.split(separator: ",").map(String.init))
        let allowed = Set(["calendar", "speech", "memos", "summary", "todos"])
        let unknown = names.subtracting(allowed)
        guard unknown.isEmpty else { throw CLIError.invalidValue("include", unknown.sorted().joined(separator: ",")) }
        return .init(
            includesCalendarEvents: names.contains("calendar"),
            includesUtterances: names.contains("speech"),
            includesMemos: names.contains("memos"),
            includesSummary: names.contains("summary"),
            includesTodosForDay: names.contains("todos")
        )
    }

    private static func write(_ text: String, arguments: [String], defaultFilename: String) throws {
        if arguments.contains("--clipboard") {
            guard value(after: "--output", in: arguments) == nil else { throw CLIError.conflictingDestinations }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(text, forType: .string) else { throw CLIError.clipboardWriteFailed }
        } else if let path = value(after: "--output", in: arguments) {
            let url = URL(fileURLWithPath: path == "." ? defaultFilename : path)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } else {
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    }

    private static func parseDay(_ value: String) throws -> Date {
        guard let date = LifeLogDateKey.date(from: value) else { throw CLIError.invalidValue("date", value) }
        return date
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func positional(at index: Int, in arguments: [String], label: String) throws -> String {
        let values = arguments.enumerated().filter { offset, value in
            !value.hasPrefix("--") && (offset == 0 || !arguments[offset - 1].hasPrefix("--"))
        }.map(\.element)
        guard values.indices.contains(index) else { throw CLIError.usage("\(label)が必要です") }
        return values[index]
    }

    private static let usage = """
    koe export day [--date YYYY-MM-DD] [--include calendar,speech,memos,summary,todos] [--clipboard|--output PATH]
    koe export todos [--clipboard|--output PATH]
    koe todo list [--status open|draft|completed|all]
    koe todo add "タイトル" | complete ID | reopen ID | delete ID
    koe prompt get summary|todo
    koe prompt set summary|todo "プロンプト"   # - で標準入力
    koe search "検索語" [--limit N]
    """
}

private enum CLIError: LocalizedError {
    case usage(String)
    case invalidValue(String, String)
    case conflictingDestinations
    case clipboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .usage(let text): text
        case .invalidValue(let name, let value): "--\(name) の値が不正です: \(value)"
        case .conflictingDestinations: "--clipboard と --output は同時に指定できません"
        case .clipboardWriteFailed: "クリップボードへ書き込めませんでした"
        }
    }
}
