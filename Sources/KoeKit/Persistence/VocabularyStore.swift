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

    public func suggestions(status: VocabularySuggestion.Status?) async throws -> [VocabularySuggestion] {
        try await queue.read { db in
            let rows: [Row]
            if let status {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM vocab_suggestions WHERE status = ? ORDER BY created_at DESC",
                    arguments: [status.rawValue]
                )
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM vocab_suggestions ORDER BY created_at DESC")
            }
            return try rows.map(Self.decodeSuggestion)
        }
    }

    public func insertSuggestions(_ suggestions: [VocabularySuggestion]) async throws -> Int {
        try await queue.write { db in
            var known = Set(try String.fetchAll(db, sql: "SELECT surface FROM vocabulary"))
            known.formUnion(try String.fetchAll(db, sql: "SELECT surface FROM vocab_suggestions"))
            var inserted = 0
            for suggestion in suggestions {
                let surface = suggestion.surface.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !surface.isEmpty, !known.contains(surface) else { continue }
                var suggestion = suggestion
                suggestion.surface = surface
                try db.execute(
                    sql: """
                        INSERT INTO vocab_suggestions (id, surface, evidence, status, created_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        suggestion.id,
                        suggestion.surface,
                        try PersistenceCoding.encode(suggestion.evidence),
                        suggestion.status.rawValue,
                        PersistenceCoding.encode(date: suggestion.createdAt),
                    ]
                )
                known.insert(surface)
                inserted += 1
            }
            return inserted
        }
    }

    public func accept(suggestionID: String) async throws -> VocabularyEntry? {
        try await queue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM vocab_suggestions WHERE id = ?",
                arguments: [suggestionID]
            ) else { return nil }
            let suggestion = try Self.decodeSuggestion(row)
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM vocabulary WHERE surface = ? ORDER BY created_at ASC LIMIT 1",
                arguments: [suggestion.surface]
            ).map(Self.decodeEntry)
            let entry = existing ?? suggestion.promoted()
            if existing == nil {
                try Self.upsert(entry, db: db)
            }
            try db.execute(
                sql: "UPDATE vocab_suggestions SET status = ? WHERE id = ?",
                arguments: [VocabularySuggestion.Status.accepted.rawValue, suggestionID]
            )
            return entry
        }
    }

    public func reject(suggestionID: String) async throws {
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE vocab_suggestions SET status = ? WHERE id = ?",
                arguments: [VocabularySuggestion.Status.rejected.rawValue, suggestionID]
            )
        }
    }

    public func knownSurfaces() async throws -> Set<String> {
        try await queue.read { db in
            var surfaces = Set(try String.fetchAll(db, sql: "SELECT surface FROM vocabulary"))
            surfaces.formUnion(try String.fetchAll(
                db,
                sql: "SELECT surface FROM vocab_suggestions WHERE status = ?",
                arguments: [VocabularySuggestion.Status.rejected.rawValue]
            ))
            return surfaces
        }
    }

    private static func upsert(_ entry: VocabularyEntry, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO vocabulary (id, surface, reading, misrecognitions, note, source, enabled, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  surface = excluded.surface,
                  reading = excluded.reading,
                  misrecognitions = excluded.misrecognitions,
                  note = excluded.note,
                  source = excluded.source,
                  enabled = excluded.enabled,
                  created_at = excluded.created_at
                """,
            arguments: [
                entry.id,
                entry.surface,
                entry.reading,
                try PersistenceCoding.encode(entry.misrecognitions),
                entry.note,
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
            note: row["note"],
            source: source,
            enabled: row["enabled"],
            createdAt: try PersistenceCoding.decodeDate(row["created_at"])
        )
    }

    private static func decodeSuggestion(_ row: Row) throws -> VocabularySuggestion {
        let statusValue: String = row["status"]
        guard let status = VocabularySuggestion.Status(rawValue: statusValue) else {
            throw PersistenceError.invalidStoredValue(column: "status", value: statusValue)
        }
        return VocabularySuggestion(
            id: row["id"],
            surface: row["surface"],
            evidence: try PersistenceCoding.decode(VocabularySuggestion.Evidence.self, from: row["evidence"]),
            status: status,
            createdAt: try PersistenceCoding.decodeDate(row["created_at"])
        )
    }
}
