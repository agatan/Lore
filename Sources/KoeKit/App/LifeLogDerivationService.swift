import Foundation

public enum BuiltinLifeLogPrompts {
    public static let todo = """
    発話から、話者自身が引き受けた具体的な作業・約束だけをTODOとして抽出してください。
    曖昧な検討、他人への依頼、すでに完了したことは除外してください。
    """

    public static let summary = """
    一日の発話・予定・TODOから、重複を避けた簡潔な日次要約を作ってください。
    事実だけを使い、推測や一般論を追加しないでください。
    """
}

public struct LifeLogDerivedSummary: Sendable, Equatable {
    public var text: String
    public var topics: [String]
    public var todoTitles: [String]

    public init(text: String, topics: [String], todoTitles: [String] = []) {
        self.text = text
        self.topics = topics
        self.todoTitles = todoTitles
    }
}

/// 発話をsource of truthとして、LLM生成物を型付きの派生データへ変換する。
public struct LifeLogDerivationService: Sendable {
    private let llm: any LlmEngine
    public init(llm: any LlmEngine) { self.llm = llm }

    public func extractTodoTitles(from utterances: [LifeLogUtterance], prompt: String) async throws -> [String] {
        guard !utterances.isEmpty else { return [] }
        let transcript = utterances.map { "[\($0.startedAt.formatted(date: .omitted, time: .shortened))] \($0.text)" }.joined(separator: "\n")
        let system = prompt + "\nJSON以外は出力しないでください。形式: {\"todos\":[\"TODO\"]}"
        let response = try await llm.complete(
            prompt: FormattingPrompt(
                system: system,
                user: clipped(transcript, reserving: system.count),
                expectedOutputCharacters: 1_200
            ),
            timeout: .seconds(30)
        )
        let output = try decode(TodoOutput.self, from: response)
        return Array(Set(output.todos.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }

    public func summarize(day: LifeLogDay, prompt: String,
                          todoPrompt: String = BuiltinLifeLogPrompts.todo) async throws -> LifeLogDerivedSummary {
        let system = prompt + "\n\nTODO抽出:\n" + todoPrompt
            + "\n以下は対象日の全データです。以前の要約を引き継がず、このデータだけから一日全体を要約してください。"
            + "\nTODOは確定せず提案として返してください。JSON以外は出力しないでください。形式: {\"summary\":\"要約\",\"topics\":[\"話題\"],\"todos\":[\"TODO案\"]}"
        let output = try await summarizeAll(Self.timelineItems(day: day), system: system, depth: 0)
        return LifeLogDerivedSummary(
            text: output.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            topics: output.topics.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            todoTitles: Array(Set((output.todos ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        )
    }

    static func timelineItems(day: LifeLogDay) -> [String] {
        let utterances = day.utterances.map {
            ($0.startedAt, "[発話 \(time($0.startedAt))–\(time($0.endedAt))] \($0.text)")
        }
        let memos = day.memos.map { ($0.createdAt, "[メモ \(time($0.createdAt))] \($0.text)") }
        let events = day.calendarEvents.map {
            ($0.startsAt, "[予定 \(time($0.startsAt))–\(time($0.endsAt))] \($0.title)")
        }
        return (utterances + memos + events).sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func summarizeAll(_ items: [String], system: String, depth: Int) async throws -> SummaryOutput {
        guard depth < 8 else { throw LifeLogDerivationError.inputTooLarge }
        let header = depth == 0 ? "対象日の全タイムライン:" : "対象日の分割要約:"
        let values = items.isEmpty ? ["なし"] : items
        let directBudget = max(200, llm.inputCharacterBudget - system.count - header.count - 2)
        let directBatches = batches(of: values, characterLimit: directBudget)
        if directBatches.count == 1 {
            return try await requestSummary(system: system, user: header + "\n" + directBatches[0], expectedOutputCharacters: 1_500)
        }

        let partialSystem = system
            + "\nこれは一日の全データを分割した一部分です。後で統合できるよう、事実・話題・TODO案を短く保持してください。"
        let partialBudget = max(200, llm.inputCharacterBudget - partialSystem.count - 32)
        let batches = batches(of: values, characterLimit: partialBudget)
        var partials: [String] = []
        for (index, batch) in batches.enumerated() {
            let output = try await requestSummary(
                system: partialSystem,
                user: "分割 \(index + 1)/\(batches.count):\n" + batch,
                expectedOutputCharacters: 600
            )
            partials.append(try String(decoding: JSONEncoder().encode(output), as: UTF8.self))
        }
        return try await summarizeAll(partials, system: system, depth: depth + 1)
    }

    private func requestSummary(system: String, user: String, expectedOutputCharacters: Int) async throws -> SummaryOutput {
        let response = try await llm.complete(
            prompt: FormattingPrompt(system: system, user: user, expectedOutputCharacters: expectedOutputCharacters),
            timeout: .seconds(30)
        )
        return try decode(SummaryOutput.self, from: response)
    }

    private func batches(of items: [String], characterLimit: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for item in items {
            for part in stride(from: 0, to: item.count, by: characterLimit).map({ offset in
                let start = item.index(item.startIndex, offsetBy: offset)
                let end = item.index(start, offsetBy: min(characterLimit, item.count - offset))
                return String(item[start..<end])
            }) {
                if current.isEmpty { current = part }
                else if current.count + 1 + part.count <= characterLimit { current += "\n" + part }
                else { result.append(current); current = part }
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func decode<T: Decodable>(_ type: T.Type, from response: String) throws -> T {
        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}"), start <= end else {
            throw LifeLogDerivationError.invalidJSON(response)
        }
        return try JSONDecoder().decode(type, from: Data(response[start...end].utf8))
    }

    private func clipped(_ input: String, reserving systemCharacters: Int) -> String {
        String(input.suffix(max(200, llm.inputCharacterBudget - systemCharacters)))
    }

    private struct TodoOutput: Decodable { var todos: [String] }
    private struct SummaryOutput: Codable { var summary: String; var topics: [String]; var todos: [String]? }
}

public enum LifeLogDerivationError: LocalizedError, Sendable {
    case invalidJSON(String), inputTooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidJSON: "ライフログのLLM応答をJSONとして読み取れませんでした"
        case .inputTooLarge: "一日のライフログが長すぎて要約を統合できませんでした"
        }
    }
}
