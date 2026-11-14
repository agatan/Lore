import Foundation
import GRDB

/// 共通ルールの読み書き。
///
/// モードのプロンプトと同じ規則で扱う(C-22): 同梱内容の写しを一緒に保存しておき、
/// 現在値が写しと一致していれば「未編集」と判定して新しい同梱内容へ追従する。
/// 編集済みなら触らない。こうしないと、同梱ルールを改善しても既存の DB に届かない。
public struct SharedRulesStore: Sendable {
    let queue: DatabaseQueue

    init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// 起動時に呼ぶ。未保存なら同梱内容を入れ、未編集なら同梱内容へ寄せる。
    public func seedOrMigrate() async throws {
        try await queue.write { db in
            let current = try Self.value(forKey: BuiltinSharedRules.key, db: db)
            let shipped = try Self.value(forKey: BuiltinSharedRules.shippedKey, db: db)

            if current == nil {
                try Self.set(BuiltinSharedRules.text, forKey: BuiltinSharedRules.key, db: db)
            } else if let shipped, shipped == current, shipped != BuiltinSharedRules.text {
                // 未編集なので新しい同梱内容へ追従する。
                try Self.set(BuiltinSharedRules.text, forKey: BuiltinSharedRules.key, db: db)
            } else if shipped == nil, current != BuiltinSharedRules.text {
                // 写しを持たない世代の DB。一度だけ同梱内容に合わせる。
                try Self.set(BuiltinSharedRules.text, forKey: BuiltinSharedRules.key, db: db)
            }
            try Self.set(BuiltinSharedRules.text, forKey: BuiltinSharedRules.shippedKey, db: db)
        }
    }

    public func current() async throws -> String {
        try await queue.read { db in
            try Self.value(forKey: BuiltinSharedRules.key, db: db) ?? BuiltinSharedRules.text
        }
    }

    public func save(_ text: String) async throws {
        try await queue.write { db in
            try Self.set(text, forKey: BuiltinSharedRules.key, db: db)
        }
    }

    /// 同梱内容に戻す。
    public func reset() async throws -> String {
        try await save(BuiltinSharedRules.text)
        return BuiltinSharedRules.text
    }

    /// 同梱内容から変更されているか。UI に「標準の内容に戻す」を出すかの判断に使う。
    public func isEdited() async throws -> Bool {
        try await current() != BuiltinSharedRules.text
    }

    private static func value(forKey key: String, db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
    }

    private static func set(_ value: String, forKey key: String, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO meta (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            arguments: [key, value]
        )
    }
}
