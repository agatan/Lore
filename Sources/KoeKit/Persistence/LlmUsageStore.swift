import Foundation
import GRDB

public struct DailyLlmUsage: Sendable, Equatable, Identifiable {
    public var id: String { "\(day)-\(purpose.rawValue)" }
    public let day: String
    public let purpose: LlmPurpose
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    public let requestCount: Int
}

public struct LlmUsageStore: Sendable {
    let queue: DatabaseQueue

    init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func record(_ event: LlmUsageEvent, calendar: Calendar = .current) async throws {
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO llm_usage_events (
                      id, occurred_at, day, purpose, provider, model,
                      input_tokens, output_tokens, total_tokens
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    event.id,
                    PersistenceCoding.encode(date: event.occurredAt),
                    LifeLogDateKey.string(for: event.occurredAt, calendar: calendar),
                    event.purpose.rawValue,
                    event.provider.rawValue,
                    event.model,
                    event.usage.inputTokens,
                    event.usage.outputTokens,
                    event.usage.totalTokens,
                ]
            )
        }
    }

    public func daily(since date: Date, calendar: Calendar = .current) async throws -> [DailyLlmUsage] {
        let sinceDay = LifeLogDateKey.string(for: date, calendar: calendar)
        return try await queue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT day, purpose,
                           SUM(input_tokens) AS input_tokens,
                           SUM(output_tokens) AS output_tokens,
                           SUM(total_tokens) AS total_tokens,
                           COUNT(*) AS request_count
                    FROM llm_usage_events
                    WHERE day >= ?
                    GROUP BY day, purpose
                    ORDER BY day DESC, purpose ASC
                    """,
                arguments: [sinceDay]
            ).map { row in
                let purposeValue: String = row["purpose"]
                guard let purpose = LlmPurpose(rawValue: purposeValue) else {
                    throw PersistenceError.invalidStoredValue(column: "purpose", value: purposeValue)
                }
                return DailyLlmUsage(
                    day: row["day"],
                    purpose: purpose,
                    inputTokens: row["input_tokens"],
                    outputTokens: row["output_tokens"],
                    totalTokens: row["total_tokens"],
                    requestCount: row["request_count"]
                )
            }
        }
    }
}
