import Foundation
import Synchronization
import Testing
@testable import KoeKit

@Suite("日をまたぐプロジェクト話題")
struct TopicTests {
    @Test("既存話題は対象日以前90日から最近の表記を優先し100件まで返す")
    func recentTopics() async throws {
        let database = try await KoeDatabase.inMemory()
        let calendar = Calendar(identifier: .gregorian)
        let day = try #require(LifeLogDateKey.date(from: "2026-09-05", calendar: calendar))
        func save(offset: Int, topics: [String]) async throws {
            let date = try #require(calendar.date(byAdding: .day, value: offset, to: day))
            try await database.lifeLog.save(summary: DailySummary(
                day: LifeLogDateKey.string(for: date, calendar: calendar), summary: "本文は不要",
                commitments: [], topics: topics, calendarEventCount: 0, capturedDurationSeconds: 0,
                utteranceCount: 0, summarizedThrough: date, isFinal: true
            ))
        }
        try await save(offset: 1, topics: ["未来"])
        try await save(offset: -91, topics: ["範囲外"])
        try await save(offset: -90, topics: ["境界"])
        try await save(offset: -1, topics: ["koe", "Henry"])
        try await save(offset: 0, topics: ["Ｋｏｅ", " "])
        #expect(try await database.lifeLog.existingTopics(for: day, calendar: calendar) == ["Ｋｏｅ", "Henry", "境界"])
        try await save(offset: -2, topics: (1...110).map { "Project \($0)" })
        let topics = try await database.lifeLog.existingTopics(for: day, calendar: calendar)
        #expect(topics.count == 100)
        #expect(topics.prefix(3) == ["Ｋｏｅ", "Henry", "Project 1"])
    }

    @Test("破損した話題JSONの読み込み失敗を呼び出し元へ返す")
    func invalidTopicData() async throws {
        let database = try await KoeDatabase.inMemory()
        let day = Date()
        let key = LifeLogDateKey.string(for: day)
        try await database.lifeLog.save(summary: DailySummary(
            day: key, summary: "", commitments: [], topics: [], calendarEventCount: 0,
            capturedDurationSeconds: 0, utteranceCount: 0, summarizedThrough: day, isFinal: true
        ))
        try await database.queue.write { db in
            try db.execute(sql: "UPDATE daily_summaries SET topics = ? WHERE day = ?", arguments: ["invalid", key])
        }
        await #expect(throws: (any Error).self) { try await database.lifeLog.existingTopics(for: day) }
    }

    @Test("既存プロジェクト名を照合させ、大小文字・文字幅の表記揺れを統合し最大5件にする")
    func canonicalTopics() async throws {
        let llm = TopicLlm()
        let result = try await LifeLogDerivationService(llm: llm).summarize(
            day: LifeLogDay(utterances: [], conversations: [], calendarEvents: [], summary: nil),
            prompt: "日報", existingTopics: ["Koe", "Henry"]
        )
        #expect(result.topics == ["Koe", "Henry", "新企画", "採用", "会計"])
        #expect(llm.prompt.withLock { $0?.system.contains("<existing_topics>\n- Koe\n- Henry\n</existing_topics>") } == true)
        #expect(llm.prompt.withLock { $0?.system.contains("同じプロジェクト・活動なら既存の表記をそのまま") } == true)
    }
}

private final class TopicLlm: LlmEngine, Sendable {
    let identifier = EngineIdentifier.foundationModels
    let modelName: String? = "topic-test"
    let inputCharacterBudget = 20_000
    let prompt = Mutex<FormattingPrompt?>(nil)
    func availability() async -> EngineAvailability { .ready }
    func complete(prompt: FormattingPrompt, timeout: Duration) async throws -> String {
        self.prompt.withLock { $0 = prompt }
        return #"{"summary":"日報","topics":[" ｋｏｅ ","Koe","HENRY","新企画","採用","会計","余剰",""],"todos":[]}"#
    }
    func unload() async {}
}
