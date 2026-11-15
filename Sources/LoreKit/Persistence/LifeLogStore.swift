import Foundation
import GRDB

public struct LifeLogStore: Sendable {
    let queue: DatabaseQueue
    init(queue: DatabaseQueue) { self.queue = queue }

    /// `fromRoot`配下を指す保存audioのpathを、`toRoot`配下の同じ相対pathへ付け替える。
    /// 該当がなければ何も書かない。
    @discardableResult
    public func rewriteAudioPaths(fromRoot: URL, toRoot: URL) async throws -> Int {
        let oldPrefix = fromRoot.standardizedFileURL.path.hasSuffix("/") ? fromRoot.standardizedFileURL.path : fromRoot.standardizedFileURL.path + "/"
        let newPrefix = toRoot.standardizedFileURL.path.hasSuffix("/") ? toRoot.standardizedFileURL.path : toRoot.standardizedFileURL.path + "/"
        return try await queue.write { db in
            try db.execute(
                sql: """
                    UPDATE life_log_audio_chunks
                    SET local_path = ? || substr(local_path, ?)
                    WHERE substr(local_path, 1, ?) = ?
                    """,
                arguments: [newPrefix, oldPrefix.unicodeScalars.count + 1, oldPrefix.unicodeScalars.count, oldPrefix]
            )
            return db.changesCount
        }
    }

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

    public func deletableAudioFileURLs(endedBefore cutoff: Date?) async throws -> [URL] {
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
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT local_path FROM life_log_audio_chunks
                        WHERE transcription_state = 'transcribed' AND processing_state = 'extracted'
                        ORDER BY capture_ended_at
                        """
                )
            }
            return rows.map { URL(fileURLWithPath: $0["local_path"]) }
        }
    }

    /// 発話・予定・メモを同じ境界で削除する。音声ファイルは呼び出し側が先に消す。
    public func deleteAll() async throws {
        // 一括削除はこのMacだけに適用し、同期先のMacへは伝えない。
        try await queue.write { db in
            try SyncStore.withoutRecordingChanges(db) {
                try db.execute(sql: "DELETE FROM life_log_utterances")
                try db.execute(sql: "DELETE FROM life_log_memos")
                try db.execute(sql: "DELETE FROM calendar_event_snapshots")
                try db.execute(sql: "DELETE FROM life_log_audio_chunks")
                try db.execute(sql: "DELETE FROM generated_notes")
                try db.execute(sql: "DELETE FROM life_log_ai_event_exclusions")
                try db.execute(sql: "DELETE FROM life_log_ai_dismissed_scopes")
            }
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
                INSERT INTO life_log_utterances (id, started_at, ended_at, text, audio_chunk_id, calendar_event_id)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET started_at=excluded.started_at, ended_at=excluded.ended_at,
                text=excluded.text, calendar_event_id=excluded.calendar_event_id
                """, arguments: [value.id, date(value.startedAt), date(value.endedAt), value.text, value.audioChunkID,
                                   value.calendarEventID])
        }
    }

    public func day(_ dateValue: Date, calendar: Calendar = .current, participatingOnly: Bool = false) async throws -> LifeLogDay {
        let interval = calendar.dateInterval(of: .day, for: dateValue)!
        return try await queue.read { db in
            let args: StatementArguments = [date(interval.start), date(interval.end)]
            let storedUtterances = try Row.fetchAll(db, sql: "SELECT * FROM life_log_utterances WHERE started_at >= ? AND started_at < ? ORDER BY started_at", arguments: args).map(decodeUtterance)
            let dictations = try Row.fetchAll(db, sql: """
                SELECT * FROM sessions
                WHERE started_at >= ? AND started_at < ?
                  AND status IN ('completed', 'fallback', 'clipboard_only')
                  AND trim(raw_transcript) != ''
                ORDER BY started_at
                """, arguments: args).map(decodeDictation)
            let utterances = LifeLogSpeechProjection.visibleUtterances(storedUtterances, preferring: dictations)
            let memos = try Row.fetchAll(db, sql: "SELECT * FROM life_log_memos WHERE created_at >= ? AND created_at < ? ORDER BY created_at", arguments: args).map(decodeMemo)
            let participationClause = participatingOnly ? " AND participation_status IN ('none', 'accepted')" : ""
            let events = try Row.fetchAll(db, sql: "SELECT * FROM calendar_event_snapshots WHERE ends_at > ? AND starts_at < ?\(participationClause) ORDER BY starts_at", arguments: args).map(decodeEvent)
            let notes = try Row.fetchAll(db, sql: "SELECT * FROM generated_notes WHERE scope_day = ? ORDER BY range_start", arguments: [LifeLogDateKey.string(for: dateValue, calendar: calendar)])
                .map { try decodeGeneratedNote($0, db: db) }
            var previous: [String: PreviousEventOccurrence] = [:]
            for event in events where !event.isAllDay {
                previous[event.id] = try previousOccurrence(of: event, db: db, calendar: calendar)
            }
            return LifeLogDay(utterances: utterances, dictations: dictations, memos: memos, calendarEvents: events,
                              generatedNotes: notes, previousOccurrences: previous)
        }
    }

    /// The latest earlier day with speech under the same event identifier. Comparing with the start of
    /// this occurrence, not of this day, keeps an event that crosses midnight from finding itself.
    private func previousOccurrence(of event: CalendarEventSnapshot, db: Database, calendar: Calendar) throws -> PreviousEventOccurrence? {
        guard let latest = try String.fetchOne(db, sql: """
            SELECT started_at FROM life_log_utterances WHERE calendar_event_id = ? AND started_at < ?
            ORDER BY started_at DESC LIMIT 1
            """, arguments: [event.id, date(event.startsAt)]) else { return nil }
        let latestStart = try parse(latest)
        guard let interval = calendar.dateInterval(of: .day, for: latestStart),
              let firstID = try String.fetchOne(db, sql: """
                SELECT id FROM life_log_utterances WHERE calendar_event_id = ? AND started_at >= ? AND started_at <= ?
                ORDER BY started_at LIMIT 1
                """, arguments: [event.id, date(interval.start), latest]) else { return nil }
        let occurrence = EventOccurrence(eventID: event.id, day: LifeLogDateKey.string(for: latestStart, calendar: calendar))
        let notes = try Row.fetchOne(db, sql: "SELECT * FROM generated_notes WHERE kind = ? AND scope_key = ?",
                                     arguments: [GeneratedNoteKind.eventNotes.rawValue, GeneratedNoteScope.event(occurrence).key])
            .map { try decodeGeneratedNote($0, db: db) }
        return PreviousEventOccurrence(occurrence: occurrence, firstUtteranceID: firstID, notes: notes)
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
        let fetchLimit = max(1, limit) * 2
        // GRDBの`Row`はSendableではないため、read closure内で検索結果へ変換してから返す。
        let storedResults = try await queue.read { db in
            let rows: [Row]
            if trimmed.count >= 3 {
                let phrase = "\"\(trimmed.replacingOccurrences(of: "\"", with: "\"\""))\""
                rows = try Row.fetchAll(db, sql: Self.ftsSearchSQL, arguments: [phrase, phrase, fetchLimit])
            } else {
                let escaped = trimmed
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                let pattern = "%\(escaped)%"
                rows = try Row.fetchAll(db, sql: Self.likeSearchSQL, arguments: [pattern, pattern, fetchLimit])
            }
            return try rows.map { row in
                let occurredAt = try PersistenceCoding.decodeDate(row["occurred_at"])
                return LifeLogSearchResult(
                    id: "\(row["kind"] as String)-\(row["id"] as String)",
                    kind: LifeLogSearchResult.Kind(rawValue: row["kind"])!,
                    text: row["text"],
                    occurredAt: occurredAt,
                    day: LifeLogDateKey.string(for: occurredAt, calendar: calendar)
                )
            }
        }
        let utteranceDays = Set(storedResults.filter { $0.kind == .utterance }.map { LifeLogDateKey.string(for: $0.occurredAt, calendar: calendar) })
        var visibleUtteranceIDs: Set<String> = []
        for dayKey in utteranceDays {
            guard let date = LifeLogDateKey.date(from: dayKey, calendar: calendar) else { continue }
            visibleUtteranceIDs.formUnion(try await day(date, calendar: calendar).utterances.map { "utterance-\($0.id)" })
        }
        let projectedResults = storedResults.filter { $0.kind != .utterance || visibleUtteranceIDs.contains($0.id) }
        let dictationResults = try await searchDictations(trimmed, limit: fetchLimit, calendar: calendar)
        return Array((projectedResults + dictationResults).sorted { $0.occurredAt > $1.occurredAt }.prefix(max(1, limit)))
    }

    private func searchDictations(_ query: String, limit: Int, calendar: Calendar) async throws -> [LifeLogSearchResult] {
        try await queue.read { db in
            let rows: [Row]
            if query.count >= 3 {
                let phrase = "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""
                rows = try Row.fetchAll(db, sql: """
                    SELECT s.id, s.raw_transcript text, s.started_at occurred_at
                    FROM sessions s JOIN sessions_fts f ON f.rowid=s.rowid
                    WHERE sessions_fts MATCH ?
                      AND s.status IN ('completed', 'fallback', 'clipboard_only')
                      AND trim(s.raw_transcript) != ''
                    ORDER BY s.started_at DESC LIMIT ?
                    """, arguments: [phrase, limit])
            } else {
                let escaped = query
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                rows = try Row.fetchAll(db, sql: """
                    SELECT id, raw_transcript text, started_at occurred_at FROM sessions
                    WHERE raw_transcript LIKE ? ESCAPE '\\'
                      AND status IN ('completed', 'fallback', 'clipboard_only')
                      AND trim(raw_transcript) != ''
                    ORDER BY started_at DESC LIMIT ?
                    """, arguments: ["%\(escaped)%", limit])
            }
            return try rows.map { row in
                let occurredAt = try PersistenceCoding.decodeDate(row["occurred_at"])
                return LifeLogSearchResult(
                    id: "dictation-\(row["id"] as String)",
                    kind: .dictation,
                    text: row["text"],
                    occurredAt: occurredAt,
                    day: LifeLogDateKey.string(for: occurredAt, calendar: calendar)
                )
            }
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
    public func memo(id: String) async throws -> LifeLogMemo? {
        try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM life_log_memos WHERE id=?", arguments: [id]).map(decodeMemo)
        }
    }
    /// 本文だけを書き換える。作成時刻はtimeline上の位置なので変えない。
    public func updateMemo(id: String, text: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "UPDATE life_log_memos SET text=? WHERE id=?", arguments: [text, id])
            guard db.changesCount > 0 else { throw LifeLogStoreError.memoNotFound }
        }
    }
    public func deleteMemo(id: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM life_log_memos WHERE id=?", arguments: [id])
        }
    }

    // MARK: Life Log AI

    /// One note per kind and scope. Regenerating replaces the stored note.
    public func save(generatedNote value: GeneratedNote) async throws {
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO generated_notes (id, kind, scope_key, scope_day, event_id, range_start, range_end, provider, model,
                  created_at, source_utterance_ids, source_memo_ids, content)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(kind, scope_key) DO UPDATE SET id=excluded.id, range_start=excluded.range_start,
                range_end=excluded.range_end, provider=excluded.provider, model=excluded.model, created_at=excluded.created_at,
                source_utterance_ids=excluded.source_utterance_ids, source_memo_ids=excluded.source_memo_ids, content=excluded.content
                """, arguments: [value.id, value.kind.rawValue, value.scope.key, value.scope.day, value.scope.eventID,
                                   date(value.rangeStart), date(value.rangeEnd), value.backend.rawValue, value.model,
                                   date(value.createdAt), try PersistenceCoding.encode(value.sourceUtteranceIDs),
                                   try PersistenceCoding.encode(value.sourceMemoIDs), try PersistenceCoding.encode(value.sections)])
            try db.execute(sql: "DELETE FROM life_log_ai_dismissed_scopes WHERE scope_key = ?", arguments: [Self.dismissalKey(value.kind, value.scope)])
        }
    }

    private static func dismissalKey(_ kind: GeneratedNoteKind, _ scope: GeneratedNoteScope) -> String { "\(kind.rawValue)|\(scope.key)" }

    /// True after the user deleted the note of this scope. Automatic generation leaves it alone.
    public func isGeneratedNoteDismissed(kind: GeneratedNoteKind, scope: GeneratedNoteScope) async throws -> Bool {
        try await queue.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM life_log_ai_dismissed_scopes WHERE scope_key = ?", arguments: [Self.dismissalKey(kind, scope)]) ?? false
        }
    }

    public func generatedNote(kind: GeneratedNoteKind, scope: GeneratedNoteScope) async throws -> GeneratedNote? {
        try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM generated_notes WHERE kind = ? AND scope_key = ?", arguments: [kind.rawValue, scope.key])
                .map { try decodeGeneratedNote($0, db: db) }
        }
    }

    /// Notes whose scope day falls in `[from, to]`, oldest first, with their current staleness.
    public func generatedNotes(fromDay: String, throughDay: String) async throws -> [GeneratedNote] {
        try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM generated_notes WHERE scope_day >= ? AND scope_day <= ? ORDER BY range_start",
                             arguments: [fromDay, throughDay])
                .map { try decodeGeneratedNote($0, db: db) }
        }
    }

    /// Deletes the note and remembers the deletion, so the automatic trigger does not send its text again.
    public func deleteGeneratedNote(_ note: GeneratedNote) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM generated_notes WHERE id = ?", arguments: [note.id])
            try db.execute(sql: "INSERT OR IGNORE INTO life_log_ai_dismissed_scopes (scope_key) VALUES (?)",
                           arguments: [Self.dismissalKey(note.kind, note.scope)])
        }
    }

    public func aiExcludedEventIDs() async throws -> Set<String> {
        try await queue.read { db in Set(try String.fetchAll(db, sql: "SELECT event_id FROM life_log_ai_event_exclusions")) }
    }

    public func setAIExcluded(_ excluded: Bool, eventID: String) async throws {
        try await queue.write { db in
            if excluded {
                try db.execute(sql: "INSERT OR IGNORE INTO life_log_ai_event_exclusions (event_id) VALUES (?)", arguments: [eventID])
            } else {
                try db.execute(sql: "DELETE FROM life_log_ai_event_exclusions WHERE event_id = ?", arguments: [eventID])
            }
        }
    }

    private func decodeGeneratedNote(_ r: Row, db: Database) throws -> GeneratedNote {
        let kindValue: String = r["kind"]
        let providerValue: String = r["provider"]
        guard let kind = GeneratedNoteKind(rawValue: kindValue) else { throw PersistenceError.invalidStoredValue(column: "kind", value: kindValue) }
        guard let backend = FormattingBackend(rawValue: providerValue) else { throw PersistenceError.invalidStoredValue(column: "provider", value: providerValue) }
        guard let eventID: String = r["event_id"] else { throw PersistenceError.invalidStoredValue(column: "event_id", value: "NULL") }
        let utteranceIDs = try PersistenceCoding.decode([String].self, from: r["source_utterance_ids"])
        let memoIDs = try PersistenceCoding.decode([String].self, from: r["source_memo_ids"])
        let rangeStart = try parse(r["range_start"])
        let rangeEnd = try parse(r["range_end"])
        let scopeDay: String = r["scope_day"]
        let eventState: GeneratedNote.EventSnapshotState = try Row.fetchOne(db, sql: "SELECT * FROM calendar_event_snapshots WHERE id = ?", arguments: [eventID])
            .map(decodeEvent)
            .map { LifeLogDateKey.string(for: $0.startsAt) == scopeDay ? .occurrence($0) : .otherOccurrence } ?? .missing
        let existingUtterances = try Self.count(db, table: "life_log_utterances", ids: utteranceIDs)
        let existingMemos = try Self.count(db, table: "life_log_memos", ids: memoIDs)
        return GeneratedNote(
            id: r["id"],
            kind: kind,
            scope: .event(EventOccurrence(eventID: eventID, day: scopeDay)),
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            backend: backend,
            model: r["model"],
            createdAt: try parse(r["created_at"]),
            sourceUtteranceIDs: utteranceIDs,
            sourceMemoIDs: memoIDs,
            sections: try PersistenceCoding.decode([GeneratedNoteSection].self, from: r["content"]),
            staleReasons: GeneratedNote.staleReasons(
                rangeStart: rangeStart,
                rangeEnd: rangeEnd,
                event: eventState,
                missingSourceCount: utteranceIDs.count + memoIDs.count - existingUtterances - existingMemos
            )
        )
    }

    private static func count(_ db: Database, table: String, ids: [String]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table) WHERE id IN (\(placeholders))", arguments: StatementArguments(ids)) ?? 0
    }

    private func date(_ value: Date) -> String { PersistenceCoding.encode(date: value) }
    private func parse(_ value: String) throws -> Date { try PersistenceCoding.decodeDate(value) }
    private func decodeChunk(_ r: Row) throws -> LifeLogAudioChunk { LifeLogAudioChunk(id: r["id"], captureStartedAt: try parse(r["capture_started_at"]), captureEndedAt: try parse(r["capture_ended_at"]), localPath: r["local_path"], transcriptionState: LifeLogProcessingState(rawValue: r["transcription_state"])!, processingState: LifeLogProcessingState(rawValue: r["processing_state"])!, failureReason: r["failure_reason"], peakLevel: r["peak_level"]) }
    private func decodeUtterance(_ r: Row) throws -> LifeLogUtterance { LifeLogUtterance(id: r["id"], startedAt: try parse(r["started_at"]), endedAt: try parse(r["ended_at"]), text: r["text"], audioChunkID: r["audio_chunk_id"], calendarEventID: r["calendar_event_id"]) }
    private func decodeDictation(_ r: Row) throws -> LifeLogDictation {
        let record = try SessionRow(row: r).record()
        let endedAt = record.audioDurationMs.map { record.startedAt.addingTimeInterval(Double($0) / 1_000) }
            ?? record.endedAt
            ?? record.startedAt
        return LifeLogDictation(id: record.id, startedAt: record.startedAt, endedAt: endedAt, text: record.rawTranscript)
    }
    private func decodeMemo(_ r: Row) throws -> LifeLogMemo { LifeLogMemo(id: r["id"], createdAt: try parse(r["created_at"]), text: r["text"]) }
    private func decodeEvent(_ r: Row) throws -> CalendarEventSnapshot { CalendarEventSnapshot(id: r["id"], externalIdentifier: r["external_identifier"], title: r["title"], startsAt: try parse(r["starts_at"]), endsAt: try parse(r["ends_at"]), calendarTitle: r["calendar_title"], isAllDay: r["is_all_day"], participationStatus: CalendarParticipationStatus(rawValue: r["participation_status"]) ?? .unknown) }

    private static let ftsSearchSQL = """
        SELECT 'utterance' kind, u.id, u.text, u.started_at occurred_at
        FROM life_log_utterances u JOIN life_log_utterances_fts f ON f.rowid=u.rowid WHERE life_log_utterances_fts MATCH ?
        UNION ALL
        SELECT 'memo', m.id, m.text, m.created_at
        FROM life_log_memos m JOIN life_log_memos_fts f ON f.rowid=m.rowid WHERE life_log_memos_fts MATCH ?
        ORDER BY occurred_at DESC LIMIT ?
        """

    private static let likeSearchSQL = """
        SELECT 'utterance' kind, id, text, started_at occurred_at FROM life_log_utterances WHERE text LIKE ? ESCAPE '\\'
        UNION ALL SELECT 'memo', id, text, created_at FROM life_log_memos WHERE text LIKE ? ESCAPE '\\'
        ORDER BY occurred_at DESC LIMIT ?
        """
}

public enum LifeLogStoreError: LocalizedError, Sendable {
    case memoNotFound

    public var errorDescription: String? {
        switch self {
        case .memoNotFound: String(lore: "編集するメモが見つかりません。すでに削除された可能性があります")
        }
    }
}
