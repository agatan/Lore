import Foundation
import GRDB

public struct MetaStore: Sendable {
    let queue: DatabaseQueue

    init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func string(forKey key: String) async throws -> String? {
        try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
        }
    }

    public func setString(_ value: String?, forKey key: String) async throws {
        try await queue.write { db in
            if let value {
                try db.execute(
                    sql: """
                        INSERT INTO meta (key, value) VALUES (?, ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value
                        """,
                    arguments: [key, value]
                )
            } else {
                try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key])
            }
        }
    }

    public func date(forKey key: String) async throws -> Date? {
        guard let value = try await string(forKey: key) else { return nil }
        return try PersistenceCoding.decodeDate(value)
    }

    public func setDate(_ value: Date?, forKey key: String) async throws {
        try await setString(value.map(PersistenceCoding.encode(date:)), forKey: key)
    }
}
