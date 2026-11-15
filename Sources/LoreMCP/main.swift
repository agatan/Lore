import Foundation
import LoreKit

@main
@MainActor
struct LoreMCP {
    static func main() async {
        do {
            let service = try await LoreAutomationService.openDefault(eventDetails: CalendarProvider())
            while let line = readLine() {
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let response = await handle(line, service: service)
                if let response { write(response) }
            }
        } catch {
            FileHandle.standardError.write(Data("lore-mcp: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func handle(_ line: String, service: LoreAutomationService) async -> [String: Any]? {
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
                    "serverInfo": ["name": "Lore", "version": "1.0.0"],
                    "instructions": instructions,
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

    private static func call(_ name: String, arguments: [String: Any], service: LoreAutomationService) async throws -> String {
        switch name {
        case "life_log_export":
            let date = try optionalDay("date", in: arguments) ?? Date()
            return try await service.exportDay(date, options: exportOptions(arguments["include"], isExport: true))
        case "life_log_days":
            let from = try optionalDay("from", in: arguments)
            let to = try optionalDay("to", in: arguments)
            return try LifeLogJSON.encode(try await service.days(from: from, to: to))
        case "life_log_range":
            let from = try parseDay(requiredString("from", in: arguments), argument: "from")
            let to = try optionalDay("to", in: arguments)
            let options = try exportOptions(arguments["include"])
            return try LifeLogJSON.encode(try await service.range(from: from, to: to, options: options))
        case "life_log_ai_notes":
            let from = try optionalDay("from", in: arguments)
            let to = try optionalDay("to", in: arguments)
            return try LifeLogJSON.encode(try await service.aiNotes(from: from, to: to))
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

    private static func parseDay(_ value: String, argument: String) throws -> Date {
        guard let date = LifeLogDateKey.date(from: value) else { throw MCPError.invalidArgument(argument) }
        return date
    }

    private static func optionalDay(_ name: String, in arguments: [String: Any]) throws -> Date? {
        guard let value = arguments[name] else { return nil }
        guard let text = value as? String else { throw MCPError.invalidArgument(name) }
        return try parseDay(text, argument: name)
    }

    /// 省略時は全項目。未知の種類はAIの綴り違いを黙って無視しないようerrorにする。
    private static func exportOptions(_ value: Any?, isExport: Bool = false) throws -> LifeLogTextExporter.Options {
        guard let value else { return .init() }
        guard let values = value as? [String] else { throw MCPError.invalidArgument("include") }
        let names = Set(values)
        guard LifeLogTextExporter.Options.unknownIncludeNames(in: names, isExport: isExport).isEmpty else {
            throw MCPError.invalidArgument("include")
        }
        return .init(includeNames: names)
    }

    private static let instructions = """
        Loreは、利用者の発話(ライフログと音声入力)、メモ、カレンダーの予定を日ごとにMac上へ保存するアプリ。このサーバーは読み取り専用で、記録を書き換えず、ネットワークにも接続しない。
        使い方: まずlife_log_daysで記録がある日を確かめ、life_log_rangeで期間を構造化JSONとして読む(最大31日)。人にそのまま見せるMarkdownはlife_log_export、語句を探すときはlife_log_search。
        要約、TODOの抽出、雑なメモ(kind=memo)の清書や別のメモアプリ・タスク管理への転記は呼び出し側の仕事で、Loreへ書き戻す手段はない。
        life_log_ai_notesとlife_log_exportのai-notesが返すノートと1日のまとめ(kind=daily_digest)、life_log_searchの種類generatedの行は、LoreのAIが生成したもので、利用者の発言ではない。内容が重要なときは、各項目のsources(u-<発話id>、m-<メモid>)が指す元の発話・メモと照らして確かめる。録音はこのMacのマイクだけなので、オンライン会議の他の参加者の発言はノートにも記録にも含まれない。
        """

    private static let includeSchema: [String: Any] = [
        "type": "array",
        "description": "含める種類。calendar=予定、speech=ライフログの発話、voice-input=音声入力の結果、memos=手入力とボイスメモ。省略時はすべて",
        "items": ["type": "string", "enum": ["calendar", "speech", "voice-input", "memos"]],
    ]

    private static let exportIncludeSchema: [String: Any] = [
        "type": "array",
        "description": "含める種類。calendar=予定、speech=ライフログの発話、voice-input=音声入力の結果、memos=手入力とボイスメモ、ai-notes=LoreのAIが生成した予定のノート、event-details=各予定の説明と参加者(メールアドレスを含む。calendarと一緒に指定する)。省略時はai-notesとevent-details以外のすべて",
        "items": ["type": "string", "enum": ["calendar", "speech", "voice-input", "memos", "ai-notes", "event-details"]],
    ]

    private static var tools: [[String: Any]] { [
        tool("life_log_days",
             "記録がある日の目次を返す。期間を決める前にまず使う。結果はJSON配列で、各要素はday(YYYY-MM-DD)、utterances(ライフログ発話数)、dictations(音声入力数)、memos、events(予定数)、spokenSeconds(発話の合計秒)。記録が何もない日は含まない",
             properties: [
                "from": stringSchema("開始日YYYY-MM-DD。省略時はtoの29日前"),
                "to": stringSchema("終了日YYYY-MM-DD(含む)。省略時は今日。期間は最大366日"),
             ]),
        tool("life_log_range",
             "期間内の予定・発話・音声入力・メモを時刻順の構造化JSON配列で返す。各要素はid、kind(event|utterance|dictation|memo)、day、start、end(任意)、text。eventはtitle、calendar、allDayに加え、分かる場合だけexternalIdentifier(カレンダーサーバーが予定に付ける識別子。GoogleカレンダーやDriveのコネクタの予定と突き合わせる)、conferenceURL(Meet/Zoom/Teams/Webexの参加リンク)、description、organizer(name、email)、attendees(name、email、response=accepted|declined|tentative|pending|unknown、role=required|optional|chair|nonParticipant|unknown)を持つ。分からない項目は省略される。繰り返し予定の回はstartで区別する。時刻はローカル時差付きISO8601。週や月の振り返り、要約、TODO抽出、雑なメモ(kind=memo、include=[memos])を読んで別のメモアプリやタスク管理へ清書・転記する材料に使う。Loreは読み取り専用で、転記先への書き込みは呼び出し側が行う",
             properties: [
                "from": stringSchema("開始日YYYY-MM-DD"),
                "to": stringSchema("終了日YYYY-MM-DD(含む)。省略時はfromの1日だけ。期間は最大31日"),
                "include": includeSchema,
             ],
             required: ["from"]),
        tool("life_log_export",
             "1日分の予定・発話・音声入力・メモを人が読むMarkdownで返す。人へそのまま見せる用途向け。機械的に処理するならlife_log_rangeを使う",
             properties: [
                "date": stringSchema("YYYY-MM-DD。省略時は今日"),
                "include": exportIncludeSchema,
             ]),
        tool("life_log_ai_notes",
             "LoreのライフログAIが予定ごとに生成したノートと、1日のまとめをJSON配列で返す。利用者の発言やメモそのものではなく、generated=trueのAI生成物なので、重要な内容は各itemのsources(u-<発話id>、m-<メモid>)が指す元の記録と照らして確かめる。各要素はid、kind(event_notes|daily_digest)、day、eventId(daily_digestには無い)、start、end、provider、model、createdAt、stale(event_changed|sources_deletedの配列。空でなければ内容が古い)、omittedSources(入力上限に収めるため省いた記録の件数)、sourceUtteranceIds、sourceMemoIds、sections(kind=summary(daily_digestのみ)|decisions|action_items|open_questions、itemsはtext、owner(任意)、sources)。録音はこのMacのマイクだけなので、オンライン会議では他の参加者の発言を含まない",
             properties: [
                "from": stringSchema("開始日YYYY-MM-DD。省略時はtoと同じ日"),
                "to": stringSchema("終了日YYYY-MM-DD(含む)。省略時は今日。期間は最大31日"),
             ]),
        tool("life_log_search",
             "発話・音声入力・メモと、ライフログAIが生成したノートとまとめを日本語部分一致で横断検索し、新しい順に「日付<TAB>種類<TAB>本文」の行で返す。種類generatedはAIの生成物で、利用者の発言ではない。前後の文脈はlife_log_rangeでその日を読む",
             properties: ["query": stringSchema("検索語"), "limit": ["type": "integer", "minimum": 1, "description": "最大件数。省略時は100"]],
             required: ["query"]),
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
            FileHandle.standardError.write(Data("lore-mcp: response encoding failed: \(error.localizedDescription)\n".utf8))
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
