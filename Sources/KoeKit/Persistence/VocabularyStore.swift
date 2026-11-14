import Foundation
import GRDB

public struct VocabularyStore: Sendable {
    let queue: DatabaseQueue

    init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func all() async throws -> [VocabularyEntry] {
        try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM vocabulary ORDER BY created_at DESC").map(Self.decodeEntry)
        }
    }

    public func enabledEntries() async throws -> [VocabularyEntry] {
        try await queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM vocabulary WHERE enabled = 1 ORDER BY created_at DESC"
            ).map(Self.decodeEntry)
        }
    }

    public func save(_ entry: VocabularyEntry) async throws {
        try await queue.write { db in
            try Self.upsert(entry, db: db)
        }
    }

    public func delete(id: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM vocabulary WHERE id = ?", arguments: [id])
        }
    }

    private static func upsert(_ entry: VocabularyEntry, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO vocabulary (id, surface, reading, misrecognitions, source, enabled, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  surface = excluded.surface,
                  reading = excluded.reading,
                  misrecognitions = excluded.misrecognitions,
                  source = excluded.source,
                  enabled = excluded.enabled,
                  created_at = excluded.created_at
                """,
            arguments: [
                entry.id,
                entry.surface,
                entry.reading,
                try PersistenceCoding.encode(entry.misrecognitions),
                entry.source.rawValue,
                entry.enabled,
                PersistenceCoding.encode(date: entry.createdAt),
            ]
        )
    }

    private static func decodeEntry(_ row: Row) throws -> VocabularyEntry {
        let sourceValue: String = row["source"]
        guard let source = VocabularyEntry.Source(rawValue: sourceValue) else {
            throw PersistenceError.invalidStoredValue(column: "source", value: sourceValue)
        }
        return VocabularyEntry(
            id: row["id"],
            surface: row["surface"],
            reading: row["reading"],
            misrecognitions: try PersistenceCoding.decode([String].self, from: row["misrecognitions"]),
            source: source,
            enabled: row["enabled"],
            createdAt: try PersistenceCoding.decodeDate(row["created_at"])
        )
    }
}
