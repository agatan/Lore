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
        case "search": try await search(Array(arguments.dropFirst()), service: service)
        case "days": try await days(Array(arguments.dropFirst()), service: service)
        case "range": try await range(Array(arguments.dropFirst()), service: service)
        case "memo": try await memo(Array(arguments.dropFirst()), service: service)
        case "help", "--help", "-h": print(usage)
        default: throw CLIError.usage("不明なコマンド: \(command)\n\n\(usage)")
        }
    }

    private static func export(_ arguments: [String], service: KoeAutomationService) async throws {
        guard arguments.first == "day" else { throw CLIError.usage("使い方: koe export day [options]") }
        let date = try value(after: "--date", in: arguments).map(parseDay) ?? Date()
        let options = try exportOptions(value(after: "--include", in: arguments))
        let text = try await service.exportDay(date, options: options)
        try write(text, arguments: arguments, defaultFilename: "Koe-LifeLog-\(LifeLogDateKey.string(for: date)).md")
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

    private static func days(_ arguments: [String], service: KoeAutomationService) async throws {
        let from = try value(after: "--from", in: arguments).map(parseDay)
        let to = try value(after: "--to", in: arguments).map(parseDay)
        print(try LifeLogJSON.encode(try await service.days(from: from, to: to)))
    }

    private static func range(_ arguments: [String], service: KoeAutomationService) async throws {
        guard let from = try value(after: "--from", in: arguments).map(parseDay) else {
            throw CLIError.usage("使い方: koe range --from YYYY-MM-DD [--to YYYY-MM-DD] [--include ...]")
        }
        let to = try value(after: "--to", in: arguments).map(parseDay)
        let options = try exportOptions(value(after: "--include", in: arguments))
        print(try LifeLogJSON.encode(try await service.range(from: from, to: to, options: options)))
    }

    private static func memo(_ arguments: [String], service: KoeAutomationService) async throws {
        guard arguments.first == "add" else { throw CLIError.usage("使い方: koe memo add \"本文\" [--at ISO8601]") }
        let rest = Array(arguments.dropFirst())
        let text = try positional(at: 0, in: rest, label: "メモの本文")
        let at = try value(after: "--at", in: rest).map { value in
            guard let date = LifeLogEntry.parseTimestamp(value) else { throw CLIError.invalidValue("at", value) }
            return date
        } ?? Date()
        print(try await service.addMemo(text, at: at).id)
    }

    private static func exportOptions(_ value: String?) throws -> LifeLogTextExporter.Options {
        guard let value else { return .init() }
        let names = Set(value.split(separator: ",").map(String.init))
        let allowed = Set(["calendar", "speech", "voice-input", "memos"])
        let unknown = names.subtracting(allowed)
        guard unknown.isEmpty else { throw CLIError.invalidValue("include", unknown.sorted().joined(separator: ",")) }
        return .init(
            includesCalendarEvents: names.contains("calendar"),
            includesUtterances: names.contains("speech"),
            includesDictations: names.contains("voice-input"),
            includesMemos: names.contains("memos")
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
    koe export day [--date YYYY-MM-DD] [--include calendar,speech,voice-input,memos] [--clipboard|--output PATH]
    koe search "検索語" [--limit N]
    koe days [--from YYYY-MM-DD] [--to YYYY-MM-DD]
    koe range --from YYYY-MM-DD [--to YYYY-MM-DD] [--include calendar,speech,voice-input,memos]
    koe memo add "本文" [--at ISO8601]
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
