import Foundation
import GRDB

public final class KoeDatabase: Sendable {
    let queue: DatabaseQueue
    public let fileURL: URL?

    private init(queue: DatabaseQueue, fileURL: URL?) throws {
        self.queue = queue
        self.fileURL = fileURL
        try Self.migrator.migrate(queue)
    }

    /// ~/Library/Application Support/Koe/koe.sqlite を開き、マイグレーションとビルトインモードの投入まで済ませる
    public static func openDefault() async throws -> KoeDatabase {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koe", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("koe.sqlite", isDirectory: false)
        let database = try KoeDatabase(queue: DatabaseQueue(path: url.path, configuration: configuration), fileURL: url)
        try await database.modes.seedBuiltinsIfNeeded()
        return database
    }

    public static func inMemory() async throws -> KoeDatabase {
        let database = try KoeDatabase(queue: DatabaseQueue(configuration: configuration), fileURL: nil)
        try await database.modes.seedBuiltinsIfNeeded()
        return database
    }

    public var history: HistoryStore { HistoryStore(queue: queue) }
    public var modes: ModeStore { ModeStore(queue: queue) }
    public var sharedRules: SharedRulesStore { SharedRulesStore(queue: queue) }
    public var vocabulary: VocabularyStore { VocabularyStore(queue: queue) }
    public var meta: MetaStore { MetaStore(queue: queue) }
    public var lifeLog: LifeLogStore { LifeLogStore(queue: queue) }

    private static var configuration: Configuration {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return configuration
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE sessions (
                  id TEXT PRIMARY KEY,
                  started_at TEXT NOT NULL,
                  ended_at TEXT,
                  status TEXT NOT NULL CHECK (status IN ('interrupted', 'completed', 'cancelled', 'failed', 'fallback', 'clipboard_only')),
                  app_bundle_id TEXT,
                  app_name TEXT,
                  mode_id TEXT,
                  mode_snapshot TEXT NOT NULL,
                  stt_engine TEXT NOT NULL,
                  stt_model TEXT,
                  llm_engine TEXT,
                  llm_model TEXT,
                  language TEXT,
                  raw_transcript TEXT NOT NULL,
                  formatted_text TEXT,
                  error TEXT,
                  audio_duration_ms INTEGER,
                  stt_latency_ms INTEGER,
                  llm_latency_ms INTEGER,
                  insert_latency_ms INTEGER
                );

                CREATE VIRTUAL TABLE sessions_fts USING fts5(
                  raw_transcript,
                  formatted_text,
                  content='sessions',
                  content_rowid='rowid',
                  tokenize='trigram'
                );

                CREATE TRIGGER sessions_fts_insert AFTER INSERT ON sessions BEGIN
                  INSERT INTO sessions_fts(rowid, raw_transcript, formatted_text)
                  VALUES (new.rowid, new.raw_transcript, new.formatted_text);
                END;

                CREATE TRIGGER sessions_fts_delete AFTER DELETE ON sessions BEGIN
                  INSERT INTO sessions_fts(sessions_fts, rowid, raw_transcript, formatted_text)
                  VALUES ('delete', old.rowid, old.raw_transcript, old.formatted_text);
                END;

                CREATE TRIGGER sessions_fts_update AFTER UPDATE ON sessions BEGIN
                  INSERT INTO sessions_fts(sessions_fts, rowid, raw_transcript, formatted_text)
                  VALUES ('delete', old.rowid, old.raw_transcript, old.formatted_text);
                  INSERT INTO sessions_fts(rowid, raw_transcript, formatted_text)
                  VALUES (new.rowid, new.raw_transcript, new.formatted_text);
                END;

                CREATE TABLE modes (
                  id TEXT PRIMARY KEY,
                  name TEXT NOT NULL,
                  bundle_ids TEXT NOT NULL,
                  prompt TEXT NOT NULL,
                  llm_model TEXT,
                  language_pref TEXT NOT NULL DEFAULT 'auto',
                  sort_order INTEGER NOT NULL,
                  is_builtin INTEGER NOT NULL DEFAULT 0,
                  updated_at TEXT NOT NULL
                );

                CREATE TABLE vocabulary (
                  id TEXT PRIMARY KEY,
                  surface TEXT NOT NULL,
                  reading TEXT,
                  misrecognitions TEXT NOT NULL,
                  note TEXT,
                  source TEXT NOT NULL,
                  enabled INTEGER NOT NULL DEFAULT 1,
                  created_at TEXT NOT NULL
                );

                CREATE TABLE vocab_suggestions (
                  id TEXT PRIMARY KEY,
                  surface TEXT NOT NULL UNIQUE,
                  evidence TEXT NOT NULL,
                  status TEXT NOT NULL,
                  created_at TEXT NOT NULL
                );

                CREATE TABLE meta (
                  key TEXT PRIMARY KEY,
                  value TEXT NOT NULL
                );
                """)
        }

        // 語彙のメモ欄を廃止(C-43)。辞書はモデルへのヒントだけを持つ。
        migrator.registerMigration("v2-drop-vocabulary-note") { db in
            try db.alter(table: "vocabulary") { table in
                table.drop(column: "note")
            }
        }
        migrator.registerMigration("v3-daily-life-log") { db in
            try db.execute(sql: """
                CREATE TABLE life_log_audio_chunks (
                  id TEXT PRIMARY KEY, capture_started_at TEXT NOT NULL, capture_ended_at TEXT NOT NULL,
                  local_path TEXT NOT NULL UNIQUE, transcription_state TEXT NOT NULL,
                  processing_state TEXT NOT NULL, failure_reason TEXT
                );
                CREATE TABLE calendar_event_snapshots (
                  id TEXT PRIMARY KEY, external_identifier TEXT, title TEXT NOT NULL,
                  starts_at TEXT NOT NULL, ends_at TEXT NOT NULL, calendar_title TEXT NOT NULL,
                  is_all_day INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE life_log_conversations (
                  id TEXT PRIMARY KEY, started_at TEXT NOT NULL, ended_at TEXT NOT NULL,
                  calendar_event_id TEXT REFERENCES calendar_event_snapshots(id)
                );
                CREATE TABLE life_log_utterances (
                  id TEXT PRIMARY KEY, started_at TEXT NOT NULL, ended_at TEXT NOT NULL, text TEXT NOT NULL,
                  audio_chunk_id TEXT NOT NULL REFERENCES life_log_audio_chunks(id),
                  calendar_event_id TEXT REFERENCES calendar_event_snapshots(id),
                  conversation_id TEXT REFERENCES life_log_conversations(id)
                );
                CREATE INDEX life_log_utterances_started_at ON life_log_utterances(started_at);
                CREATE VIRTUAL TABLE life_log_utterances_fts USING fts5(text, content='life_log_utterances', content_rowid='rowid', tokenize='trigram');
                CREATE TRIGGER life_log_utterances_fts_insert AFTER INSERT ON life_log_utterances BEGIN
                  INSERT INTO life_log_utterances_fts(rowid, text) VALUES (new.rowid, new.text);
                END;
                CREATE TRIGGER life_log_utterances_fts_delete AFTER DELETE ON life_log_utterances BEGIN
                  INSERT INTO life_log_utterances_fts(life_log_utterances_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
                END;
                CREATE TRIGGER life_log_utterances_fts_update AFTER UPDATE ON life_log_utterances BEGIN
                  INSERT INTO life_log_utterances_fts(life_log_utterances_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
                  INSERT INTO life_log_utterances_fts(rowid, text) VALUES (new.rowid, new.text);
                END;
                CREATE TABLE life_log_todos (
                  id TEXT PRIMARY KEY, title TEXT NOT NULL, status TEXT NOT NULL,
                  created_at TEXT NOT NULL, due_at TEXT, source_conversation_id TEXT,
                  source_utterance_ids TEXT NOT NULL, confidence REAL
                );
                CREATE TABLE todo_extraction_rules (id TEXT PRIMARY KEY, instruction TEXT NOT NULL, created_at TEXT NOT NULL);
                CREATE TABLE daily_summaries (
                  day TEXT PRIMARY KEY, summary TEXT NOT NULL, commitments TEXT NOT NULL, topics TEXT NOT NULL,
                  calendar_event_count INTEGER NOT NULL, captured_duration_seconds INTEGER NOT NULL,
                  utterance_count INTEGER NOT NULL, summarized_through TEXT NOT NULL, is_final INTEGER NOT NULL
                );
                """)
        }
        migrator.registerMigration("v4-calendar-participation-status") { db in
            try db.alter(table: "calendar_event_snapshots") { table in
                table.add(column: "participation_status", .text).notNull().defaults(to: CalendarParticipationStatus.none.rawValue)
            }
        }
        migrator.registerMigration("v5-life-log-memos") { db in
            try db.execute(sql: """
                CREATE TABLE life_log_memos (
                  id TEXT PRIMARY KEY,
                  created_at TEXT NOT NULL,
                  text TEXT NOT NULL
                );
                CREATE INDEX life_log_memos_created_at ON life_log_memos(created_at);
                """)
            try db.alter(table: "life_log_todos") { table in
                table.add(column: "source_memo_ids", .text).notNull().defaults(to: "[]")
            }
            try db.alter(table: "life_log_audio_chunks") { table in
                table.add(column: "peak_level", .double)
            }
        }
        return migrator
    }
}

enum PersistenceCoding {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(value.utf8))
    }

    static func encode(date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func decodeDate(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else {
            throw PersistenceError.invalidDate(value)
        }
        return date
    }
}

enum PersistenceError: Error {
    case invalidDate(String)
    case invalidStoredValue(column: String, value: String)
}
