import Foundation
import GRDB

public final class LoreDatabase: Sendable {
    let queue: DatabaseQueue
    public let fileURL: URL?

    private init(queue: DatabaseQueue, fileURL: URL?) throws {
        self.queue = queue
        self.fileURL = fileURL
        try Self.migrator.migrate(queue)
    }

    public static let directoryName = "Lore"
    public static let databaseFileName = "lore.sqlite"

    /// `~/Library/Application Support/Lore`。DB、backup、ライフログaudio、modelを置く。
    public static var dataDirectory: URL {
        applicationSupportDirectory.appending(path: directoryName, directoryHint: .isDirectory)
    }

    static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// ~/Library/Application Support/Lore/lore.sqlite を開き、マイグレーションとビルトインモードの投入まで済ませる。
    ///
    /// 開く前に旧名Koeのfolderを移す。移せなければ例外を返してDBを開かない。
    /// 新旧両方のfolderがある場合は新しい方を開き、結果を`legacyMigration`に残す。
    public static func openDefault() async throws -> (database: LoreDatabase, legacyMigration: LegacyKoeMigration.DirectoryOutcome) {
        let outcome = try LegacyKoeMigration.migrateApplicationSupport(in: applicationSupportDirectory)
        if case .leftLegacyInPlace(let legacy) = outcome {
            LoreLog.persistence.error("旧Koeのデータを移さずに残しました: \(legacy.path, privacy: .public)")
        }
        let directory = dataDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(databaseFileName, isDirectory: false)
        let database = try await open(
            fileURL: url,
            backupDirectory: directory.appendingPathComponent("Backups", isDirectory: true)
        )
        // 保存audioのpathはDBに絶対pathで入っている。folderを移した後も参照できるよう、
        // 旧folder配下を指すpathを毎回（該当があるときだけ）新しいfolderへ付け替える。
        try await database.lifeLog.rewriteAudioPaths(
            fromRoot: applicationSupportDirectory.appending(path: LegacyKoeMigration.directoryName, directoryHint: .isDirectory),
            toRoot: directory
        )
        return (database, outcome)
    }

    static func open(fileURL: URL, backupDirectory: URL, now: Date = Date()) async throws -> LoreDatabase {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existed = fileManager.fileExists(atPath: fileURL.path)
        let queue = try DatabaseQueue(path: fileURL.path, configuration: configuration)
        if existed {
            let needsMigration = try await queue.read { try !migrator.hasCompletedMigrations($0) }
            try backup(queue, to: backupDirectory, beforeMigration: needsMigration, now: now)
        }
        let database = try LoreDatabase(queue: queue, fileURL: fileURL)
        try await database.modes.seedBuiltinsIfNeeded()
        return database
    }

    public static func inMemory() async throws -> LoreDatabase {
        let database = try LoreDatabase(queue: DatabaseQueue(configuration: configuration), fileURL: nil)
        try await database.modes.seedBuiltinsIfNeeded()
        return database
    }

    public var history: HistoryStore { HistoryStore(queue: queue) }
    public var modes: ModeStore { ModeStore(queue: queue) }
    public var sharedRules: SharedRulesStore { SharedRulesStore(queue: queue) }
    public var vocabulary: VocabularyStore { VocabularyStore(queue: queue) }
    public var meta: MetaStore { MetaStore(queue: queue) }
    public var lifeLog: LifeLogStore { LifeLogStore(queue: queue) }
    public var sync: SyncStore { SyncStore(queue: queue) }

    /// 「Loreの全データを削除」にバックアップも含める。DB単体の削除では復旧点を残す。
    public func deleteBackups() throws {
        guard let fileURL else { return }
        let directory = fileURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private static func backup(
        _ source: DatabaseQueue,
        to directory: URL,
        beforeMigration: Bool,
        now: Date
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = beforeMigration ? "yyyyMMdd-HHmmss" : "yyyyMMdd"
        let prefix = beforeMigration ? "pre-migration" : "daily"
        let destination = directory.appendingPathComponent("\(prefix)-\(formatter.string(from: now)).sqlite")
        guard !fileManager.fileExists(atPath: destination.path) else { return }

        let staged = directory.appendingPathComponent(".backup-\(UUID().uuidString).sqlite")
        do {
            try source.backup(to: DatabaseQueue(path: staged.path, configuration: configuration))
            try fileManager.moveItem(at: staged, to: destination)
        } catch let backupError {
            if fileManager.fileExists(atPath: staged.path) {
                do {
                    try fileManager.removeItem(at: staged)
                } catch {
                    throw BackupError.cleanupFailed(
                        backup: backupError.localizedDescription,
                        cleanup: error.localizedDescription
                    )
                }
            }
            throw backupError
        }
        try pruneBackups(in: directory, keeping: 7)
    }

    private static func pruneBackups(in directory: URL, keeping limit: Int) throws {
        let fileManager = FileManager.default
        let backups = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
            .filter { $0.pathExtension == "sqlite" }
            .map { url in
                (url, try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in backups.dropFirst(limit) {
            try fileManager.removeItem(at: url)
        }
    }

    /// 設定(UserDefaults)と秘密(Keychain)以外の利用者データを一つのDB transactionで消す。
    public func deleteAllUserData() async throws {
        try await queue.write { db in
            // 同期を解除してから消すため、削除は同期先へ伝わらない。
            try SyncStore.reset(db)
            try db.execute(sql: "DELETE FROM life_log_utterances")
            try db.execute(sql: "DELETE FROM life_log_memos")
            try db.execute(sql: "DELETE FROM calendar_event_snapshots")
            try db.execute(sql: "DELETE FROM life_log_audio_chunks")
            try db.execute(sql: "DELETE FROM generated_notes")
            try db.execute(sql: "DELETE FROM life_log_ai_event_exclusions")
            try db.execute(sql: "DELETE FROM life_log_ai_dismissed_scopes")
            try db.execute(sql: "DELETE FROM sessions")
            try db.execute(sql: "DELETE FROM vocabulary")
            try db.execute(sql: "DELETE FROM modes")
            try db.execute(sql: "DELETE FROM meta")
        }
    }

    private static var configuration: Configuration {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return configuration
    }

    static var migrator: DatabaseMigrator {
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
        migrator.registerMigration("v6-life-log-search") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE life_log_memos_fts USING fts5(text, content='life_log_memos', content_rowid='rowid', tokenize='trigram');
                CREATE TRIGGER life_log_memos_fts_insert AFTER INSERT ON life_log_memos BEGIN
                  INSERT INTO life_log_memos_fts(rowid, text) VALUES (new.rowid, new.text);
                END;
                CREATE TRIGGER life_log_memos_fts_delete AFTER DELETE ON life_log_memos BEGIN
                  INSERT INTO life_log_memos_fts(life_log_memos_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
                END;
                CREATE TRIGGER life_log_memos_fts_update AFTER UPDATE ON life_log_memos BEGIN
                  INSERT INTO life_log_memos_fts(life_log_memos_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
                  INSERT INTO life_log_memos_fts(rowid, text) VALUES (new.rowid, new.text);
                END;

                CREATE VIRTUAL TABLE life_log_todos_fts USING fts5(title, content='life_log_todos', content_rowid='rowid', tokenize='trigram');
                CREATE TRIGGER life_log_todos_fts_insert AFTER INSERT ON life_log_todos BEGIN
                  INSERT INTO life_log_todos_fts(rowid, title) VALUES (new.rowid, new.title);
                END;
                CREATE TRIGGER life_log_todos_fts_delete AFTER DELETE ON life_log_todos BEGIN
                  INSERT INTO life_log_todos_fts(life_log_todos_fts, rowid, title) VALUES ('delete', old.rowid, old.title);
                END;
                CREATE TRIGGER life_log_todos_fts_update AFTER UPDATE ON life_log_todos BEGIN
                  INSERT INTO life_log_todos_fts(life_log_todos_fts, rowid, title) VALUES ('delete', old.rowid, old.title);
                  INSERT INTO life_log_todos_fts(rowid, title) VALUES (new.rowid, new.title);
                END;

                CREATE VIRTUAL TABLE daily_summaries_fts USING fts5(summary, commitments, topics, content='daily_summaries', content_rowid='rowid', tokenize='trigram');
                CREATE TRIGGER daily_summaries_fts_insert AFTER INSERT ON daily_summaries BEGIN
                  INSERT INTO daily_summaries_fts(rowid, summary, commitments, topics) VALUES (new.rowid, new.summary, new.commitments, new.topics);
                END;
                CREATE TRIGGER daily_summaries_fts_delete AFTER DELETE ON daily_summaries BEGIN
                  INSERT INTO daily_summaries_fts(daily_summaries_fts, rowid, summary, commitments, topics) VALUES ('delete', old.rowid, old.summary, old.commitments, old.topics);
                END;
                CREATE TRIGGER daily_summaries_fts_update AFTER UPDATE ON daily_summaries BEGIN
                  INSERT INTO daily_summaries_fts(daily_summaries_fts, rowid, summary, commitments, topics) VALUES ('delete', old.rowid, old.summary, old.commitments, old.topics);
                  INSERT INTO daily_summaries_fts(rowid, summary, commitments, topics) VALUES (new.rowid, new.summary, new.commitments, new.topics);
                END;

                INSERT INTO life_log_memos_fts(life_log_memos_fts) VALUES ('rebuild');
                INSERT INTO life_log_todos_fts(life_log_todos_fts) VALUES ('rebuild');
                INSERT INTO daily_summaries_fts(daily_summaries_fts) VALUES ('rebuild');
                """)
        }
        migrator.registerMigration("v7-todo-completion-time") { db in
            try db.alter(table: "life_log_todos") { table in
                table.add(column: "completed_at", .text)
            }
            // 過去の完了操作時刻は復元できないため、履歴上の最小限の近似として作成日時を使う。
            try db.execute(sql: "UPDATE life_log_todos SET completed_at=created_at WHERE status='completed'")
        }
        migrator.registerMigration("v8-llm-token-usage") { db in
            try db.execute(sql: """
                CREATE TABLE llm_usage_events (
                  id TEXT PRIMARY KEY,
                  occurred_at TEXT NOT NULL,
                  day TEXT NOT NULL,
                  purpose TEXT NOT NULL CHECK (purpose IN ('dictation', 'lifeLog')),
                  provider TEXT NOT NULL,
                  model TEXT,
                  input_tokens INTEGER NOT NULL,
                  output_tokens INTEGER NOT NULL,
                  total_tokens INTEGER NOT NULL
                );
                CREATE INDEX llm_usage_events_day_purpose ON llm_usage_events(day, purpose);
                """)
        }
        migrator.registerMigration("v9-remove-todo-summary-usage") { db in
            // TODO、日次要約、話題、LLM token集計を廃止した。会話区切りは要約の入力にだけ使っていた。
            try db.execute(sql: """
                DROP TRIGGER life_log_todos_fts_insert;
                DROP TRIGGER life_log_todos_fts_delete;
                DROP TRIGGER life_log_todos_fts_update;
                DROP TABLE life_log_todos_fts;
                DROP TABLE life_log_todos;
                DROP TRIGGER daily_summaries_fts_insert;
                DROP TRIGGER daily_summaries_fts_delete;
                DROP TRIGGER daily_summaries_fts_update;
                DROP TABLE daily_summaries_fts;
                DROP TABLE daily_summaries;
                DROP TABLE llm_usage_events;

                DROP TRIGGER life_log_utterances_fts_insert;
                DROP TRIGGER life_log_utterances_fts_delete;
                DROP TRIGGER life_log_utterances_fts_update;
                DROP TABLE life_log_utterances_fts;
                CREATE TABLE life_log_utterances_new (
                  id TEXT PRIMARY KEY, started_at TEXT NOT NULL, ended_at TEXT NOT NULL, text TEXT NOT NULL,
                  audio_chunk_id TEXT NOT NULL REFERENCES life_log_audio_chunks(id),
                  calendar_event_id TEXT REFERENCES calendar_event_snapshots(id)
                );
                INSERT INTO life_log_utterances_new (id, started_at, ended_at, text, audio_chunk_id, calendar_event_id)
                  SELECT id, started_at, ended_at, text, audio_chunk_id, calendar_event_id FROM life_log_utterances;
                DROP TABLE life_log_utterances;
                ALTER TABLE life_log_utterances_new RENAME TO life_log_utterances;
                DROP TABLE life_log_conversations;
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
                INSERT INTO life_log_utterances_fts(life_log_utterances_fts) VALUES ('rebuild');
                """)
        }
        migrator.registerMigration("v10-sync") { db in
            // 他のMacから届いた発話は保存audioを持たないため、audio_chunk_idをNULL許容へ作り直す。
            try db.execute(sql: """
                DROP TRIGGER life_log_utterances_fts_insert;
                DROP TRIGGER life_log_utterances_fts_delete;
                DROP TRIGGER life_log_utterances_fts_update;
                DROP TABLE life_log_utterances_fts;
                CREATE TABLE life_log_utterances_new (
                  id TEXT PRIMARY KEY, started_at TEXT NOT NULL, ended_at TEXT NOT NULL, text TEXT NOT NULL,
                  audio_chunk_id TEXT REFERENCES life_log_audio_chunks(id),
                  calendar_event_id TEXT REFERENCES calendar_event_snapshots(id)
                );
                INSERT INTO life_log_utterances_new (id, started_at, ended_at, text, audio_chunk_id, calendar_event_id)
                  SELECT id, started_at, ended_at, text, audio_chunk_id, calendar_event_id FROM life_log_utterances;
                DROP TABLE life_log_utterances;
                ALTER TABLE life_log_utterances_new RENAME TO life_log_utterances;
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
                INSERT INTO life_log_utterances_fts(life_log_utterances_fts) VALUES ('rebuild');

                CREATE TABLE sync_control (
                  id INTEGER PRIMARY KEY CHECK (id = 1),
                  enabled INTEGER NOT NULL DEFAULT 0,
                  suppressed INTEGER NOT NULL DEFAULT 0,
                  device_id TEXT,
                  folder_bookmark BLOB,
                  next_seq INTEGER NOT NULL DEFAULT 1,
                  last_synced_at TEXT,
                  last_error TEXT
                );
                INSERT INTO sync_control (id) VALUES (1);
                CREATE TABLE sync_outbox (
                  entity TEXT NOT NULL, record_id TEXT NOT NULL, changed_at TEXT NOT NULL,
                  PRIMARY KEY (entity, record_id)
                );
                CREATE TABLE sync_versions (
                  entity TEXT NOT NULL, record_id TEXT NOT NULL, changed_at TEXT NOT NULL,
                  device_id TEXT NOT NULL, deleted INTEGER NOT NULL,
                  PRIMARY KEY (entity, record_id)
                );
                CREATE TABLE sync_cursors (
                  device_id TEXT PRIMARY KEY, last_seq INTEGER NOT NULL
                );
                """)
            // migrationは後から変えないよう、対象tableをここに固定する。
            let synced = [
                ("utterance", "life_log_utterances"), ("memo", "life_log_memos"),
                ("session", "sessions"), ("vocabulary", "vocabulary"),
            ]
            for (entity, table) in synced {
                for (event, row) in [("INSERT", "new"), ("UPDATE", "new"), ("DELETE", "old")] {
                    try db.execute(sql: """
                        CREATE TRIGGER sync_\(entity)_\(event.lowercased()) AFTER \(event) ON \(table)
                        WHEN (SELECT enabled = 1 AND suppressed = 0 FROM sync_control WHERE id = 1)
                        BEGIN
                          INSERT INTO sync_outbox (entity, record_id, changed_at)
                          VALUES ('\(entity)', \(row).id, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                          ON CONFLICT (entity, record_id) DO UPDATE SET changed_at = excluded.changed_at;
                        END;
                        """)
                }
            }
        }
        migrator.registerMigration("v11-remove-vocab-suggestions") { db in
            // 履歴からの語彙候補を廃止した。登録済みの語彙はvocabularyに残る。
            try db.execute(sql: "DROP TABLE vocab_suggestions")
            try db.execute(
                sql: "DELETE FROM meta WHERE key IN (?, ?)",
                arguments: ["vocab_analysis_watermark", "vocab_analysis_last_run"]
            )
        }
        migrator.registerMigration("v12-life-log-ai") { db in
            // Generated notes and AI exclusions stay on this Mac: no sync triggers.
            try db.execute(sql: """
                CREATE TABLE generated_notes (
                  id TEXT PRIMARY KEY,
                  kind TEXT NOT NULL,
                  scope_key TEXT NOT NULL,
                  scope_day TEXT NOT NULL,
                  event_id TEXT,
                  range_start TEXT NOT NULL,
                  range_end TEXT NOT NULL,
                  provider TEXT NOT NULL,
                  model TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  source_utterance_ids TEXT NOT NULL,
                  source_memo_ids TEXT NOT NULL,
                  content TEXT NOT NULL,
                  UNIQUE(kind, scope_key)
                );
                CREATE INDEX generated_notes_scope_day ON generated_notes(scope_day);
                CREATE TABLE life_log_ai_event_exclusions (event_id TEXT PRIMARY KEY);
                CREATE TABLE life_log_ai_dismissed_scopes (scope_key TEXT PRIMARY KEY);
                """)
        }
        migrator.registerMigration("v13-utterance-event-index") { db in
            // "Last time" looks up the latest utterance of an event identifier on every day load.
            try db.execute(sql: "CREATE INDEX life_log_utterances_event_started_at ON life_log_utterances(calendar_event_id, started_at)")
        }
        migrator.registerMigration("v14-event-occurrence-snapshots") { db in
            // EventKit shares one identifier across a repeating series, so each occurrence needs its own row.
            try db.execute(sql: """
                DROP TRIGGER life_log_utterances_fts_insert;
                DROP TRIGGER life_log_utterances_fts_delete;
                DROP TRIGGER life_log_utterances_fts_update;
                DROP TABLE life_log_utterances_fts;
                CREATE TABLE life_log_utterances_new (
                  id TEXT PRIMARY KEY, started_at TEXT NOT NULL, ended_at TEXT NOT NULL, text TEXT NOT NULL,
                  audio_chunk_id TEXT REFERENCES life_log_audio_chunks(id),
                  calendar_event_id TEXT
                );
                INSERT INTO life_log_utterances_new (id, started_at, ended_at, text, audio_chunk_id, calendar_event_id)
                  SELECT id, started_at, ended_at, text, audio_chunk_id, calendar_event_id FROM life_log_utterances;
                DROP TABLE life_log_utterances;
                ALTER TABLE life_log_utterances_new RENAME TO life_log_utterances;
                CREATE INDEX life_log_utterances_started_at ON life_log_utterances(started_at);
                CREATE INDEX life_log_utterances_event_started_at ON life_log_utterances(calendar_event_id, started_at);
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
                INSERT INTO life_log_utterances_fts(life_log_utterances_fts) VALUES ('rebuild');

                CREATE TABLE calendar_event_snapshots_new (
                  id TEXT NOT NULL, start_day TEXT NOT NULL, external_identifier TEXT, title TEXT NOT NULL,
                  starts_at TEXT NOT NULL, ends_at TEXT NOT NULL, calendar_title TEXT NOT NULL,
                  is_all_day INTEGER NOT NULL DEFAULT 0, participation_status TEXT NOT NULL DEFAULT 'none',
                  PRIMARY KEY (id, start_day)
                );
                """)
            for row in try Row.fetchAll(db, sql: "SELECT * FROM calendar_event_snapshots") {
                let startDay = LifeLogDateKey.string(for: try PersistenceCoding.decodeDate(row["starts_at"]))
                try db.execute(sql: "INSERT INTO calendar_event_snapshots_new VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
                    row["id"], startDay, row["external_identifier"], row["title"], row["starts_at"], row["ends_at"],
                    row["calendar_title"], row["is_all_day"], row["participation_status"],
                ])
            }
            try db.execute(sql: """
                INSERT INTO calendar_event_snapshots_new (id, start_day, external_identifier, title, starts_at, ends_at,
                  calendar_title, is_all_day, participation_status)
                SELECT n.event_id, n.scope_day, s.external_identifier, s.title, n.range_start, n.range_end,
                  s.calendar_title, s.is_all_day, s.participation_status
                FROM generated_notes n JOIN calendar_event_snapshots s ON s.id = n.event_id
                WHERE NOT EXISTS (SELECT 1 FROM calendar_event_snapshots_new x WHERE x.id = n.event_id
                  AND (x.start_day = n.scope_day OR x.starts_at = n.range_start));
                DROP TABLE calendar_event_snapshots;
                ALTER TABLE calendar_event_snapshots_new RENAME TO calendar_event_snapshots;
                """)
            for (event, row) in [("INSERT", "new"), ("UPDATE", "new"), ("DELETE", "old")] {
                try db.execute(sql: """
                    CREATE TRIGGER sync_utterance_\(event.lowercased()) AFTER \(event) ON life_log_utterances
                    WHEN (SELECT enabled = 1 AND suppressed = 0 FROM sync_control WHERE id = 1)
                    BEGIN
                      INSERT INTO sync_outbox (entity, record_id, changed_at)
                      VALUES ('utterance', \(row).id, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                      ON CONFLICT (entity, record_id) DO UPDATE SET changed_at = excluded.changed_at;
                    END;
                    """)
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

private enum BackupError: LocalizedError {
    case cleanupFailed(backup: String, cleanup: String)

    var errorDescription: String? {
        switch self {
        case .cleanupFailed(let backup, let cleanup):
            String(lore: "DBバックアップに失敗し、一時ファイルも削除できませんでした。backup: \(backup) / cleanup: \(cleanup)")
        }
    }
}
