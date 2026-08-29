import Foundation
import GRDB

public struct LifeLogStore: Sendable {
    let queue: DatabaseQueue
    init(queue: DatabaseQueue) { self.queue = queue }

    public func save(audioChunk value: LifeLogAudioChunk) async throws {
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO life_log_audio_chunks VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET capture_ended_at=excluded.capture_ended_at,
                local_path=excluded.local_path, transcription_state=excluded.transcription_state,
                processing_state=excluded.processing_state, failure_reason=excluded.failure_reason,
                peak_level=excluded.peak_level
                """, arguments: [value.id, date(value.captureStartedAt), date(value.captureEndedAt), value.localPath,
                                   value.transcriptionState.rawValue, value.processingState.rawValue, value.failureReason,
                                   value.peakLevel])
        }
    }

    public func pendingAudioChunks() async throws -> [LifeLogAudioChunk] {
        try await queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM life_log_audio_chunks WHERE transcription_state IN ('captured','failed') OR processing_state != 'extracted' ORDER BY capture_started_at").map(decodeChunk) }
    }

    public func audioFileURLs(endedBefore cutoff: Date? = nil) async throws -> [URL] {
        try await queue.read { db in
            let rows: [Row]
            if let cutoff {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT local_path FROM life_log_audio_chunks
                        WHERE capture_ended_at < ? AND transcription_state = 'transcribed' AND processing_state = 'extracted'
                        ORDER BY capture_ended_at
                        """,
                    arguments: [date(cutoff)]
                )
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT local_path FROM life_log_audio_chunks ORDER BY capture_ended_at")
            }
            return rows.map { URL(fileURLWithPath: $0["local_path"]) }
        }
    }

    /// 発話・予定・メモ・TODO・要約を同じ境界で削除する。音声ファイルは呼び出し側が先に消す。
    public func deleteAll() async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM life_log_utterances")
            try db.execute(sql: "DELETE FROM life_log_conversations")
            try db.execute(sql: "DELETE FROM life_log_memos")
            try db.execute(sql: "DELETE FROM life_log_todos")
            try db.execute(sql: "DELETE FROM todo_extraction_rules")
            try db.execute(sql: "DELETE FROM daily_summaries")
            try db.execute(sql: "DELETE FROM calendar_event_snapshots")
            try db.execute(sql: "DELETE FROM life_log_audio_chunks")
        }
    }

    public func save(calendarEvents values: [CalendarEventSnapshot]) async throws {
        try await queue.write { db in
            for value in values {
                try db.execute(sql: """
                    INSERT INTO calendar_event_snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET title=excluded.title, starts_at=excluded.starts_at,
                    ends_at=excluded.ends_at, calendar_title=excluded.calendar_title, is_all_day=excluded.is_all_day,
                    participation_status=excluded.participation_status
                    """, arguments: [value.id, value.externalIdentifier, value.title, date(value.startsAt), date(value.endsAt), value.calendarTitle, value.isAllDay, value.participationStatus.rawValue])
            }
        }
    }

    public func save(utterance value: LifeLogUtterance) async throws {
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO life_log_utterances VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET started_at=excluded.started_at, ended_at=excluded.ended_at,
                text=excluded.text, calendar_event_id=excluded.calendar_event_id, conversation_id=excluded.conversation_id
                """, arguments: [value.id, date(value.startedAt), date(value.endedAt), value.text, value.audioChunkID,
                                   value.calendarEventID, value.conversationID])
        }
    }

    public func save(conversation: LifeLogConversation, utterances: [LifeLogUtterance]) async throws {
        try await queue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO life_log_conversations VALUES (?, ?, ?, ?)",
                           arguments: [conversation.id, date(conversation.startedAt), date(conversation.endedAt), conversation.calendarEventID])
            for utterance in utterances {
                try db.execute(sql: "UPDATE life_log_utterances SET conversation_id=? WHERE id=?", arguments: [conversation.id, utterance.id])
            }
        }
    }

    public func day(_ dateValue: Date, calendar: Calendar = .current, participatingOnly: Bool = false) async throws -> LifeLogDay {
        let interval = calendar.dateInterval(of: .day, for: dateValue)!
        return try await queue.read { db in
            let args: StatementArguments = [date(interval.start), date(interval.end)]
            let utterances = try Row.fetchAll(db, sql: "SELECT * FROM life_log_utterances WHERE started_at >= ? AND started_at < ? ORDER BY started_at", arguments: args).map(decodeUtterance)
            let memos = try Row.fetchAll(db, sql: "SELECT * FROM life_log_memos WHERE created_at >= ? AND created_at < ? ORDER BY created_at", arguments: args).map(decodeMemo)
            let conversations = try Row.fetchAll(db, sql: "SELECT * FROM life_log_conversations WHERE started_at >= ? AND started_at < ? ORDER BY started_at", arguments: args).map(decodeConversation)
            let participationClause = participatingOnly ? " AND participation_status IN ('none', 'accepted')" : ""
            let events = try Row.fetchAll(db, sql: "SELECT * FROM calendar_event_snapshots WHERE ends_at > ? AND starts_at < ?\(participationClause) ORDER BY starts_at", arguments: args).map(decodeEvent)
            let summary = try Row.fetchOne(db, sql: "SELECT * FROM daily_summaries WHERE day=?", arguments: [LifeLogDateKey.string(for: dateValue, calendar: calendar)]).map(decodeSummary)
            return LifeLogDay(utterances: utterances, memos: memos, conversations: conversations, calendarEvents: events, summary: summary)
        }
    }

    public func activity(start: Date, end: Date, calendar: Calendar = .current, participatingOnly: Bool = false) async throws -> [String: LifeLogDayActivity] {
        try await queue.read { db in
            var result: [String: LifeLogDayActivity] = [:]
            let arguments: StatementArguments = [date(start), date(end)]
            let utterances = try Row.fetchAll(
                db,
                sql: "SELECT started_at, ended_at FROM life_log_utterances WHERE started_at >= ? AND started_at < ?",
                arguments: arguments
            )
            for row in utterances {
                let startedAt = try parse(row["started_at"])
                let endedAt = try parse(row["ended_at"])
                let key = LifeLogDateKey.string(for: startedAt, calendar: calendar)
                var value = result[key, default: LifeLogDayActivity()]
                value.capturedDuration += max(0, endedAt.timeIntervalSince(startedAt))
                result[key] = value
            }
            let events = try Row.fetchAll(
                db,
                sql: "SELECT starts_at FROM calendar_event_snapshots WHERE ends_at > ? AND starts_at < ?" + (participatingOnly ? " AND participation_status IN ('none', 'accepted')" : ""),
                arguments: arguments
            )
            for row in events {
                let startsAt = try parse(row["starts_at"])
                let key = LifeLogDateKey.string(for: startsAt, calendar: calendar)
                var value = result[key, default: LifeLogDayActivity()]
                value.calendarEventCount += 1
                result[key] = value
            }
            return result
        }
    }

    public func searchUtterances(_ query: String, start: Date, end: Date) async throws -> [LifeLogUtterance] {
        try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT u.* FROM life_log_utterances u JOIN life_log_utterances_fts f ON f.rowid=u.rowid
                WHERE life_log_utterances_fts MATCH ? AND u.started_at >= ? AND u.started_at < ? ORDER BY u.started_at
                """, arguments: [query.replacingOccurrences(of: "\"", with: "\"\""), date(start), date(end)]).map(decodeUtterance)
        }
    }

    /// 日本語の部分一致を主用途にした横断検索。3文字以上はFTS5 trigram、短い語はLIKEを使う。
    public func search(_ query: String, limit: Int = 100, calendar: Calendar = .current) async throws -> [LifeLogSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let rows = try queue.read { db in
            if trimmed.count >= 3 {
                let phrase = "\"\(trimmed.replacingOccurrences(of: "\"", with: "\"\""))\""
                return try Row.fetchAll(db, sql: Self.ftsSearchSQL, arguments: [phrase, phrase, phrase, phrase, max(1, limit)])
            }
            let escaped = trimmed
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let pattern = "%\(escaped)%"
            return try Row.fetchAll(db, sql: Self.likeSearchSQL, arguments: [pattern, pattern, pattern, pattern, pattern, pattern, max(1, limit)])
        }
        return try rows.map { row in
            let occurredAt = try parse(row["occurred_at"])
            return LifeLogSearchResult(
                id: "\(row["kind"] as String)-\(row["id"] as String)",
                kind: LifeLogSearchResult.Kind(rawValue: row["kind"])!,
                text: row["text"],
                occurredAt: occurredAt,
                day: (row["day"] as String?) ?? LifeLogDateKey.string(for: occurredAt, calendar: calendar),
                todoStatus: (row["status"] as String?).flatMap(LifeLogTodo.Status.init(rawValue:))
            )
        }
    }
    public func utterance(id: String) async throws -> LifeLogUtterance? {
        try await queue.read { db in try Row.fetchOne(db, sql: "SELECT * FROM life_log_utterances WHERE id=?", arguments: [id]).map(decodeUtterance) }
    }
    public func utterances(audioChunkID: String) async throws -> [LifeLogUtterance] {
        try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM life_log_utterances WHERE audio_chunk_id=? ORDER BY started_at", arguments: [audioChunkID]).map(decodeUtterance)
        }
    }
    public func deleteUtterances(audioChunkID: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM life_log_utterances WHERE audio_chunk_id=?", arguments: [audioChunkID])
        }
    }
    public func save(memo value: LifeLogMemo) async throws {
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO life_log_memos VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET text=excluded.text
                """, arguments: [value.id, date(value.createdAt), value.text])
        }
    }
    public func deleteMemo(id: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM life_log_memos WHERE id=?", arguments: [id])
        }
    }

    public func todos() async throws -> [LifeLogTodo] {
        try await queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM life_log_todos ORDER BY status, created_at DESC").map(decodeTodo) }
    }
    public func todo(id: String) async throws -> LifeLogTodo? {
        try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM life_log_todos WHERE id=?", arguments: [id]).map(decodeTodo)
        }
    }
    public func save(todo value: LifeLogTodo) async throws {
        try await queue.write { db in try db.execute(sql: """
            INSERT INTO life_log_todos (id,title,status,created_at,due_at,source_conversation_id,source_utterance_ids,confidence,source_memo_ids,completed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title,status=excluded.status,due_at=excluded.due_at,completed_at=excluded.completed_at
            """, arguments: [value.id, value.title, value.status.rawValue, date(value.createdAt), value.dueAt.map(date),
                               value.sourceConversationID, try PersistenceCoding.encode(value.sourceUtteranceIDs), value.confidence,
                               try PersistenceCoding.encode(value.sourceMemoIDs), value.completedAt.map(date)]) }
    }
    public func deleteTodo(id: String) async throws { try await queue.write { db in try db.execute(sql: "DELETE FROM life_log_todos WHERE id=?", arguments: [id]) } }
    /// Summaryと同じ派生処理の成果物を原子的に置き換える。確定済みTODOには触れない。
    public func save(summary value: DailySummary, replacingDrafts drafts: [LifeLogTodo]) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM life_log_todos WHERE status='draft'")
            for draft in drafts {
                try db.execute(sql: "INSERT INTO life_log_todos (id,title,status,created_at,due_at,source_conversation_id,source_utterance_ids,confidence,source_memo_ids,completed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
                    draft.id, draft.title, draft.status.rawValue, date(draft.createdAt), draft.dueAt.map(date),
                    draft.sourceConversationID, try PersistenceCoding.encode(draft.sourceUtteranceIDs), draft.confidence,
                    try PersistenceCoding.encode(draft.sourceMemoIDs), draft.completedAt.map(date)
                ])
            }
            try db.execute(sql: "INSERT OR REPLACE INTO daily_summaries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
                value.day, value.summary, try PersistenceCoding.encode(value.commitments), try PersistenceCoding.encode(value.topics),
                value.calendarEventCount, value.capturedDurationSeconds, value.utteranceCount, date(value.summarizedThrough), value.isFinal
            ])
        }
    }
    public func rules() async throws -> [TodoExtractionRule] { try await queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM todo_extraction_rules ORDER BY created_at").map { TodoExtractionRule(id: $0["id"], instruction: $0["instruction"], createdAt: try parse($0["created_at"])) } } }
    public func save(rule: TodoExtractionRule) async throws { try await queue.write { db in try db.execute(sql: "INSERT OR REPLACE INTO todo_extraction_rules VALUES (?, ?, ?)", arguments: [rule.id, rule.instruction, date(rule.createdAt)]) } }
    public func deleteRule(id: String) async throws { try await queue.write { db in try db.execute(sql: "DELETE FROM todo_extraction_rules WHERE id=?", arguments: [id]) } }
    public func save(summary value: DailySummary) async throws { try await queue.write { db in try db.execute(sql: "INSERT OR REPLACE INTO daily_summaries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [value.day, value.summary, try PersistenceCoding.encode(value.commitments), try PersistenceCoding.encode(value.topics), value.calendarEventCount, value.capturedDurationSeconds, value.utteranceCount, date(value.summarizedThrough), value.isFinal]) } }

    private func date(_ value: Date) -> String { PersistenceCoding.encode(date: value) }
    private func parse(_ value: String) throws -> Date { try PersistenceCoding.decodeDate(value) }
    private func decodeChunk(_ r: Row) throws -> LifeLogAudioChunk { LifeLogAudioChunk(id: r["id"], captureStartedAt: try parse(r["capture_started_at"]), captureEndedAt: try parse(r["capture_ended_at"]), localPath: r["local_path"], transcriptionState: LifeLogProcessingState(rawValue: r["transcription_state"])!, processingState: LifeLogProcessingState(rawValue: r["processing_state"])!, failureReason: r["failure_reason"], peakLevel: r["peak_level"]) }
    private func decodeUtterance(_ r: Row) throws -> LifeLogUtterance { LifeLogUtterance(id: r["id"], startedAt: try parse(r["started_at"]), endedAt: try parse(r["ended_at"]), text: r["text"], audioChunkID: r["audio_chunk_id"], calendarEventID: r["calendar_event_id"], conversationID: r["conversation_id"]) }
    private func decodeMemo(_ r: Row) throws -> LifeLogMemo { LifeLogMemo(id: r["id"], createdAt: try parse(r["created_at"]), text: r["text"]) }
    private func decodeConversation(_ r: Row) throws -> LifeLogConversation { LifeLogConversation(id: r["id"], startedAt: try parse(r["started_at"]), endedAt: try parse(r["ended_at"]), calendarEventID: r["calendar_event_id"]) }
    private func decodeEvent(_ r: Row) throws -> CalendarEventSnapshot { CalendarEventSnapshot(id: r["id"], externalIdentifier: r["external_identifier"], title: r["title"], startsAt: try parse(r["starts_at"]), endsAt: try parse(r["ends_at"]), calendarTitle: r["calendar_title"], isAllDay: r["is_all_day"], participationStatus: CalendarParticipationStatus(rawValue: r["participation_status"]) ?? .unknown) }
    private func decodeTodo(_ r: Row) throws -> LifeLogTodo { LifeLogTodo(id: r["id"], title: r["title"], status: LifeLogTodo.Status(rawValue: r["status"])!, createdAt: try parse(r["created_at"]), completedAt: try (r["completed_at"] as String?).map(parse), dueAt: try (r["due_at"] as String?).map(parse), sourceConversationID: r["source_conversation_id"], sourceUtteranceIDs: try PersistenceCoding.decode([String].self, from: r["source_utterance_ids"]), sourceMemoIDs: try PersistenceCoding.decode([String].self, from: r["source_memo_ids"]), confidence: r["confidence"]) }
    private func decodeSummary(_ r: Row) throws -> DailySummary { DailySummary(day: r["day"], summary: r["summary"], commitments: try PersistenceCoding.decode([String].self, from: r["commitments"]), topics: try PersistenceCoding.decode([String].self, from: r["topics"]), calendarEventCount: r["calendar_event_count"], capturedDurationSeconds: r["captured_duration_seconds"], utteranceCount: r["utterance_count"], summarizedThrough: try parse(r["summarized_through"]), isFinal: r["is_final"]) }

    private static let ftsSearchSQL = """
        SELECT 'utterance' kind, u.id, u.text, u.started_at occurred_at, NULL day, NULL status
        FROM life_log_utterances u JOIN life_log_utterances_fts f ON f.rowid=u.rowid WHERE life_log_utterances_fts MATCH ?
        UNION ALL
        SELECT 'memo', m.id, m.text, m.created_at, NULL, NULL
        FROM life_log_memos m JOIN life_log_memos_fts f ON f.rowid=m.rowid WHERE life_log_memos_fts MATCH ?
        UNION ALL
        SELECT 'todo', t.id, t.title, t.created_at, NULL, t.status
        FROM life_log_todos t JOIN life_log_todos_fts f ON f.rowid=t.rowid WHERE life_log_todos_fts MATCH ?
        UNION ALL
        SELECT 'summary', s.day, s.summary, s.summarized_through, s.day, NULL
        FROM daily_summaries s JOIN daily_summaries_fts f ON f.rowid=s.rowid WHERE daily_summaries_fts MATCH ?
        ORDER BY occurred_at DESC LIMIT ?
        """

    private static let likeSearchSQL = """
        SELECT 'utterance' kind, id, text, started_at occurred_at, NULL day, NULL status FROM life_log_utterances WHERE text LIKE ? ESCAPE '\\'
        UNION ALL SELECT 'memo', id, text, created_at, NULL, NULL FROM life_log_memos WHERE text LIKE ? ESCAPE '\\'
        UNION ALL SELECT 'todo', id, title, created_at, NULL, status FROM life_log_todos WHERE title LIKE ? ESCAPE '\\'
        UNION ALL SELECT 'summary', day, summary, summarized_through, day, NULL FROM daily_summaries
          WHERE summary LIKE ? ESCAPE '\\' OR commitments LIKE ? ESCAPE '\\' OR topics LIKE ? ESCAPE '\\'
        ORDER BY occurred_at DESC LIMIT ?
        """
}
