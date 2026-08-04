import Foundation
import GRDB

public struct LatencyStats: Sendable, Equatable {
    public var count: Int
    public var p50Ms: Int
    public var p95Ms: Int

    public init(count: Int, p50Ms: Int, p95Ms: Int) {
        self.count = count
        self.p50Ms = p50Ms
        self.p95Ms = p95Ms
    }
}

/// エンジン・モデル別の実測レイテンシ。
public struct MeasuredLatencies: Sendable, Equatable {
    /// 聞き取り(停止 → 確定)。キーは `"engine|model"`。
    public var transcription: [String: LatencyStats]
    /// 仕上げ(整形の所要時間)。
    public var formatting: [String: LatencyStats]

    public init(transcription: [String: LatencyStats] = [:], formatting: [String: LatencyStats] = [:]) {
        self.transcription = transcription
        self.formatting = formatting
    }
}

public struct HistoryStore: Sendable {
    let queue: DatabaseQueue

    init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// STT 確定直後と後続処理で同じ監査行を更新する。
    public func save(_ record: SessionRecord) async throws {
        let row = try SessionRow(record: record)
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (
                      id, started_at, ended_at, status, app_bundle_id, app_name, mode_id,
                      mode_snapshot, stt_engine, stt_model, llm_engine, llm_model, language,
                      raw_transcript, formatted_text, error, audio_duration_ms, stt_latency_ms,
                      llm_latency_ms, insert_latency_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      started_at = excluded.started_at,
                      ended_at = excluded.ended_at,
                      status = excluded.status,
                      app_bundle_id = excluded.app_bundle_id,
                      app_name = excluded.app_name,
                      mode_id = excluded.mode_id,
                      mode_snapshot = excluded.mode_snapshot,
                      stt_engine = excluded.stt_engine,
                      stt_model = excluded.stt_model,
                      llm_engine = excluded.llm_engine,
                      llm_model = excluded.llm_model,
                      language = excluded.language,
                      raw_transcript = excluded.raw_transcript,
                      formatted_text = excluded.formatted_text,
                      error = excluded.error,
                      audio_duration_ms = excluded.audio_duration_ms,
                      stt_latency_ms = excluded.stt_latency_ms,
                      llm_latency_ms = excluded.llm_latency_ms,
                      insert_latency_ms = excluded.insert_latency_ms
                    """,
                arguments: row.arguments
            )
        }
    }

    public func record(id: String) async throws -> SessionRecord? {
        try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [id])
                .map(SessionRow.init(row:))?.record()
        }
    }

    public func recent(limit: Int) async throws -> [SessionRecord] {
        try await fetch(sql: "SELECT * FROM sessions ORDER BY started_at DESC LIMIT ?", arguments: [max(0, limit)])
    }

    public func search(query: String, limit: Int) async throws -> [SessionRecord] {
        guard !query.isEmpty else { return try await recent(limit: limit) }
        let quoted = "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""
        do {
            return try await fetch(
                sql: """
                    SELECT sessions.* FROM sessions
                    JOIN sessions_fts ON sessions_fts.rowid = sessions.rowid
                    WHERE sessions_fts MATCH ?
                    ORDER BY sessions.started_at DESC LIMIT ?
                    """,
                arguments: [quoted, max(0, limit)]
            )
        } catch {
            let escaped = query
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            return try await fetch(
                sql: """
                    SELECT * FROM sessions
                    WHERE raw_transcript LIKE ? ESCAPE '\\' OR formatted_text LIKE ? ESCAPE '\\'
                    ORDER BY started_at DESC LIMIT ?
                    """,
                arguments: ["%\(escaped)%", "%\(escaped)%", max(0, limit)]
            )
        }
    }

    public func sessions(since: Date?, limit: Int) async throws -> [SessionRecord] {
        if let since {
            return try await fetch(
                sql: "SELECT * FROM sessions WHERE started_at >= ? ORDER BY started_at ASC LIMIT ?",
                arguments: [PersistenceCoding.encode(date: since), max(0, limit)]
            )
        }
        return try await fetch(sql: "SELECT * FROM sessions ORDER BY started_at ASC LIMIT ?", arguments: [max(0, limit)])
    }

    public func latestInserted() async throws -> SessionRecord? {
        try await queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM sessions WHERE status IN ('completed', 'fallback') ORDER BY started_at DESC LIMIT 1"
            ).map(SessionRow.init(row:))?.record()
        }
    }

    public func count() async throws -> Int {
        try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions") ?? 0
        }
    }

    public func delete(id: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [id])
        }
    }

    public func deleteAll() async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM sessions")
        }
    }

    public func purge(retentionDays: Int) async throws -> Int {
        guard retentionDays > 0 else { return 0 }
        let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -retentionDays, to: Date())!
        return try await queue.write { db in
            try db.execute(
                sql: "DELETE FROM sessions WHERE started_at < ?",
                arguments: [PersistenceCoding.encode(date: cutoff)]
            )
            return db.changesCount
        }
    }

    public func latencyStats(limit: Int) async throws -> LatencyStats? {
        let values = try await queue.read { db in
            try Int.fetchAll(
                db,
                sql: """
                    SELECT insert_latency_ms FROM (
                      SELECT insert_latency_ms FROM sessions
                      ORDER BY started_at DESC LIMIT ?
                    ) WHERE insert_latency_ms IS NOT NULL
                    ORDER BY insert_latency_ms ASC
                    """,
                arguments: [max(0, limit)]
            )
        }
        guard !values.isEmpty else { return nil }
        return LatencyStats(
            count: values.count,
            p50Ms: percentile(0.50, values: values),
            p95Ms: percentile(0.95, values: values)
        )
    }

    /// エンジン・モデルごとの実測レイテンシ。キーは `"engine|model"`。
    ///
    /// 「このモデルは自分の環境で何秒か」をカタログの目安ではなく実測で見せるために使う。
    public func measuredLatencies(limit: Int) async throws -> MeasuredLatencies {
        let rows = try await queue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT stt_engine, stt_model, stt_latency_ms, llm_engine, llm_model, llm_latency_ms
                    FROM sessions
                    ORDER BY started_at DESC LIMIT ?
                    """,
                arguments: [max(0, limit)]
            )
        }

        var transcription: [String: [Int]] = [:]
        var formatting: [String: [Int]] = [:]

        for row in rows {
            if let latency: Int = row["stt_latency_ms"] {
                let engine: String = row["stt_engine"]
                let model: String? = row["stt_model"]
                transcription[Self.key(engine, model), default: []].append(latency)
            }
            if let latency: Int = row["llm_latency_ms"], let engine: String? = row["llm_engine"], let engine {
                let model: String? = row["llm_model"]
                formatting[Self.key(engine, model), default: []].append(latency)
            }
        }

        return MeasuredLatencies(
            transcription: transcription.compactMapValues(stats(from:)),
            formatting: formatting.compactMapValues(stats(from:))
        )
    }

    public static func key(_ engine: String, _ model: String?) -> String {
        "\(engine)|\(model ?? "")"
    }

    private func stats(from values: [Int]) -> LatencyStats? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return LatencyStats(
            count: sorted.count,
            p50Ms: percentile(0.50, values: sorted),
            p95Ms: percentile(0.95, values: sorted)
        )
    }

    private func fetch(sql: String, arguments: StatementArguments) async throws -> [SessionRecord] {
        try await queue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).map { try SessionRow(row: $0).record() }
        }
    }

    private func percentile(_ percentile: Double, values: [Int]) -> Int {
        let rank = max(1, Int(ceil(percentile * Double(values.count))))
        return values[rank - 1]
    }
}
