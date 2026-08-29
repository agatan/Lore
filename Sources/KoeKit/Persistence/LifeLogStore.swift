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
    public func save(todo value: LifeLogTodo) async throws {
        try await queue.write { db in try db.execute(sql: """
            INSERT INTO life_log_todos VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title,status=excluded.status,due_at=excluded.due_at
            """, arguments: [value.id, value.title, value.status.rawValue, date(value.createdAt), value.dueAt.map(date),
                               value.sourceConversationID, try PersistenceCoding.encode(value.sourceUtteranceIDs), value.confidence,
                               try PersistenceCoding.encode(value.sourceMemoIDs)]) }
    }
    public func deleteTodo(id: String) async throws { try await queue.write { db in try db.execute(sql: "DELETE FROM life_log_todos WHERE id=?", arguments: [id]) } }
    /// Summaryと同じ派生処理の成果物を原子的に置き換える。確定済みTODOには触れない。
    public func save(summary value: DailySummary, replacingDrafts drafts: [LifeLogTodo]) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM life_log_todos WHERE status='draft'")
            for draft in drafts {
                try db.execute(sql: "INSERT INTO life_log_todos VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
                    draft.id, draft.title, draft.status.rawValue, date(draft.createdAt), draft.dueAt.map(date),
                    draft.sourceConversationID, try PersistenceCoding.encode(draft.sourceUtteranceIDs), draft.confidence,
                    try PersistenceCoding.encode(draft.sourceMemoIDs)
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
    private func decodeTodo(_ r: Row) throws -> LifeLogTodo { LifeLogTodo(id: r["id"], title: r["title"], status: LifeLogTodo.Status(rawValue: r["status"])!, createdAt: try parse(r["created_at"]), dueAt: try (r["due_at"] as String?).map(parse), sourceConversationID: r["source_conversation_id"], sourceUtteranceIDs: try PersistenceCoding.decode([String].self, from: r["source_utterance_ids"]), sourceMemoIDs: try PersistenceCoding.decode([String].self, from: r["source_memo_ids"]), confidence: r["confidence"]) }
    private func decodeSummary(_ r: Row) throws -> DailySummary { DailySummary(day: r["day"], summary: r["summary"], commitments: try PersistenceCoding.decode([String].self, from: r["commitments"]), topics: try PersistenceCoding.decode([String].self, from: r["topics"]), calendarEventCount: r["calendar_event_count"], capturedDurationSeconds: r["captured_duration_seconds"], utteranceCount: r["utterance_count"], summarizedThrough: try parse(r["summarized_through"]), isFinal: r["is_final"]) }
}
