import Foundation
import KoeKit

@main
@MainActor
struct KoeMCP {
    static func main() async {
        do {
            let service = try await KoeAutomationService.openDefault()
            while let line = readLine() {
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let response = await handle(line, service: service)
                if let response { write(response) }
            }
        } catch {
            FileHandle.standardError.write(Data("koe-mcp: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func handle(_ line: String, service: KoeAutomationService) async -> [String: Any]? {
        do {
            guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = request["method"] as? String else {
                return errorResponse(id: nil, code: -32600, message: "Invalid Request")
            }
            let id = request["id"]
            if id == nil { return nil }
            switch method {
            case "initialize":
                return success(id: id, result: [
                    "protocolVersion": "2025-03-26",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "Koe", "version": "1.0.0"],
                ])
            case "tools/list":
                return success(id: id, result: ["tools": tools])
            case "tools/call":
                guard let params = request["params"] as? [String: Any], let name = params["name"] as? String else {
                    return errorResponse(id: id, code: -32602, message: "name is required")
                }
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let text = try await call(name, arguments: arguments, service: service)
                return success(id: id, result: ["content": [["type": "text", "text": text]], "isError": false])
            default:
                return errorResponse(id: id, code: -32601, message: "Method not found")
            }
        } catch {
            let id = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["id"]
            return success(id: id, result: [
                "content": [["type": "text", "text": error.localizedDescription]],
                "isError": true,
            ])
        }
    }

    private static func call(_ name: String, arguments: [String: Any], service: KoeAutomationService) async throws -> String {
        switch name {
        case "life_log_export":
            let date = try (arguments["date"] as? String).map(parseDay) ?? Date()
            return try await service.exportDay(date, options: exportOptions(arguments["include"] as? [String]))
        case "life_log_search":
            let query = try requiredString("query", in: arguments)
            let results = try await service.search(query, limit: arguments["limit"] as? Int ?? 100)
            return results.map { "\($0.day)\t\($0.kind.rawValue)\t\($0.text.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n")
        default:
            throw MCPError.unknownTool(name)
        }
    }

    private static func requiredString(_ name: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[name] as? String, !value.isEmpty else { throw MCPError.missingArgument(name) }
        return value
    }

    private static func parseDay(_ value: String) throws -> Date {
        guard let date = LifeLogDateKey.date(from: value) else { throw MCPError.invalidArgument("date") }
        return date
    }

    private static func exportOptions(_ values: [String]?) -> LifeLogTextExporter.Options {
        guard let values else { return .init() }
        let names = Set(values)
        return .init(
            includesCalendarEvents: names.contains("calendar"),
            includesUtterances: names.contains("speech"),
            includesDictations: names.contains("voice-input"),
            includesMemos: names.contains("memos")
        )
    }

    private static var tools: [[String: Any]] { [
        tool("life_log_export", "指定日の予定・発話・音声入力・メモを選択して読みやすいMarkdownにする", properties: [
            "date": stringSchema("YYYY-MM-DD。省略時は今日"),
            "include": ["type": "array", "items": ["type": "string", "enum": ["calendar", "speech", "voice-input", "memos"]]],
        ]),
        tool("life_log_search", "日本語部分一致で発話・音声入力・メモを横断検索する", properties: ["query": stringSchema("検索語"), "limit": ["type": "integer", "minimum": 1]], required: ["query"]),
    ] }

    private static func stringSchema(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    private static func tool(_ name: String, _ description: String, properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
    }

    private static func success(id: Any?, result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    private static func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private static func write(_ value: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: value)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("koe-mcp: response encoding failed: \(error.localizedDescription)\n".utf8))
        }
    }
}

private enum MCPError: LocalizedError {
    case missingArgument(String)
    case invalidArgument(String)
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name): "引数が必要です: \(name)"
        case .invalidArgument(let name): "引数が不正です: \(name)"
        case .unknownTool(let name): "不明なツールです: \(name)"
        }
    }
}
