import Foundation
import GRDB

public struct ModeStore: Sendable {
    let queue: DatabaseQueue
    private static let deletedBuiltinIDsKey = "deleted_builtin_mode_ids"

    init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func all() async throws -> [Mode] {
        try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM modes ORDER BY sort_order ASC").map(Self.decode)
        }
    }

    public func mode(id: String) async throws -> Mode? {
        try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM modes WHERE id = ?", arguments: [id]).map(Self.decode)
        }
    }

    public func save(_ mode: Mode) async throws {
        var updatedMode = mode
        updatedMode.updatedAt = Date()
        let modeToSave = updatedMode
        try await queue.write { db in
            try Self.upsert(modeToSave, db: db)
        }
    }

    public func delete(id: String) async throws {
        try await queue.write { db in
            let builtin = try Bool.fetchOne(
                db,
                sql: "SELECT is_builtin FROM modes WHERE id = ?",
                arguments: [id]
            ) ?? false
            if builtin {
                var deleted = try Self.deletedBuiltinIDs(db: db)
                deleted.insert(id)
                try Self.setDeletedBuiltinIDs(deleted, db: db)
            }
            try db.execute(sql: "DELETE FROM modes WHERE id = ?", arguments: [id])
        }
    }

    /// ビルトインモードを投入する。冪等。
    ///
    /// 同梱プロンプトを更新したときは、**ユーザーが編集していないモードだけ**追従させる。
    /// 判定には投入時に記録した「同梱プロンプトの写し」を使い、DB の内容がそれと一致していれば
    /// 未編集とみなす。写しが無い古い DB は一度だけ同梱内容に揃える(以降は編集が守られる)。
    public func seedBuiltinsIfNeeded() async throws {
        try await queue.write { db in
            let deleted = try Self.deletedBuiltinIDs(db: db)
            let hasShippedRecords = try Self.hasShippedRecords(db: db)

            for mode in BuiltinModes.all where !deleted.contains(mode.id) {
                let storedPrompt = try String.fetchOne(
                    db,
                    sql: "SELECT prompt FROM modes WHERE id = ?",
                    arguments: [mode.id]
                )

                if storedPrompt == nil {
                    try Self.upsert(mode, db: db)
                } else if let shipped = try Self.shippedPrompt(id: mode.id, db: db) {
                    if shipped == storedPrompt, shipped != mode.prompt {
                        try Self.updatePrompt(mode, db: db)
                    }
                } else if !hasShippedRecords, storedPrompt != mode.prompt {
                    // 写しを持たない世代の DB。一度だけ同梱内容に合わせる。
                    try Self.updatePrompt(mode, db: db)
                }

                try Self.recordShippedPrompt(mode, db: db)
            }
        }
    }

    public func resetToBuiltin(id: String) async throws -> Mode? {
        guard var builtin = BuiltinModes.all.first(where: { $0.id == id }) else { return nil }
        builtin.updatedAt = Date()
        let mode = builtin
        try await queue.write { db in
            var deleted = try Self.deletedBuiltinIDs(db: db)
            deleted.remove(id)
            try Self.setDeletedBuiltinIDs(deleted, db: db)
            try Self.upsert(mode, db: db)
        }
        return mode
    }

    private static func upsert(_ mode: Mode, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO modes (
                  id, name, bundle_ids, prompt, llm_model, language_pref, sort_order, is_builtin, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name,
                  bundle_ids = excluded.bundle_ids,
                  prompt = excluded.prompt,
                  llm_model = excluded.llm_model,
                  language_pref = excluded.language_pref,
                  sort_order = excluded.sort_order,
                  is_builtin = excluded.is_builtin,
                  updated_at = excluded.updated_at
                """,
            arguments: [
                mode.id,
                mode.name,
                try PersistenceCoding.encode(mode.bundleIDs),
                mode.prompt,
                mode.llmModel,
                mode.languagePreference.rawValue,
                mode.sortOrder,
                mode.isBuiltin,
                PersistenceCoding.encode(date: mode.updatedAt),
            ]
        )
    }

    private static func decode(_ row: Row) throws -> Mode {
        let preferenceValue: String = row["language_pref"]
        guard let preference = LanguagePreference(rawValue: preferenceValue) else {
            throw PersistenceError.invalidStoredValue(column: "language_pref", value: preferenceValue)
        }
        return Mode(
            id: row["id"],
            name: row["name"],
            bundleIDs: try PersistenceCoding.decode([String].self, from: row["bundle_ids"]),
            prompt: row["prompt"],
            llmModel: row["llm_model"],
            languagePreference: preference,
            sortOrder: row["sort_order"],
            isBuiltin: row["is_builtin"],
            updatedAt: try PersistenceCoding.decodeDate(row["updated_at"])
        )
    }

    // MARK: 同梱プロンプトの追跡

    private static let shippedPromptPrefix = "builtin_shipped_prompt."

    private static func shippedPrompt(id: String, db: Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT value FROM meta WHERE key = ?",
            arguments: [shippedPromptPrefix + id]
        )
    }

    private static func recordShippedPrompt(_ mode: Mode, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO meta (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            arguments: [shippedPromptPrefix + mode.id, mode.prompt]
        )
    }

    private static func hasShippedRecords(db: Database) throws -> Bool {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM meta WHERE key LIKE ?",
            arguments: [shippedPromptPrefix + "%"]
        ) ?? 0
        return count > 0
    }

    private static func updatePrompt(_ mode: Mode, db: Database) throws {
        try db.execute(
            sql: "UPDATE modes SET prompt = ?, updated_at = ? WHERE id = ?",
            arguments: [mode.prompt, PersistenceCoding.encode(date: Date()), mode.id]
        )
    }

    private static func deletedBuiltinIDs(db: Database) throws -> Set<String> {
        guard let value = try String.fetchOne(
            db,
            sql: "SELECT value FROM meta WHERE key = ?",
            arguments: [deletedBuiltinIDsKey]
        ) else { return [] }
        return Set(try PersistenceCoding.decode([String].self, from: value))
    }

    private static func setDeletedBuiltinIDs(_ ids: Set<String>, db: Database) throws {
        let value = try PersistenceCoding.encode(ids.sorted())
        try db.execute(
            sql: """
                INSERT INTO meta (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            arguments: [deletedBuiltinIDsKey, value]
        )
    }
}
