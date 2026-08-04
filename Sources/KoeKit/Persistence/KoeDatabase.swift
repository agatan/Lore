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
