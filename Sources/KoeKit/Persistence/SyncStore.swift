import Foundation
import GRDB

/// Mac間で同期するtable。列の並びは書き出しと適用で共有し、先頭は必ず`id`にする。
public enum SyncEntity: String, CaseIterable, Codable, Sendable {
    case utterance
    case memo
    case session
    case vocabulary

    var table: String {
        switch self {
        case .utterance: "life_log_utterances"
        case .memo: "life_log_memos"
        case .session: "sessions"
        case .vocabulary: "vocabulary"
        }
    }

    /// 発話の`audio_chunk_id`と`calendar_event_id`は送らない。audioも予定の控えも各Macにしか無いため。
    var columns: [String] {
        switch self {
        case .utterance:
            ["id", "started_at", "ended_at", "text"]
        case .memo:
            ["id", "created_at", "text"]
        case .session:
            [
                "id", "started_at", "ended_at", "status", "app_bundle_id", "app_name", "mode_id", "mode_snapshot",
                "stt_engine", "stt_model", "llm_engine", "llm_model", "language", "raw_transcript", "formatted_text",
                "error", "audio_duration_ms", "stt_latency_ms", "llm_latency_ms", "insert_latency_ms",
            ]
        case .vocabulary:
            ["id", "surface", "reading", "misrecognitions", "source", "enabled", "created_at"]
        }
    }
}

/// 同期fileへ書くSQLite値。BLOB列は同期対象に無い。
public enum SyncValue: Codable, Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .real(value) }
        else { self = .text(try container.decode(String.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .integer(let value): try container.encode(value)
        case .real(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        }
    }

    init(_ value: DatabaseValue) throws {
        switch value.storage {
        case .null: self = .null
        case .int64(let value): self = .integer(value)
        case .double(let value): self = .real(value)
        case .string(let value): self = .text(value)
        case .blob: throw SyncStoreError.unsupportedValue
        }
    }

    var databaseValue: DatabaseValue {
        switch self {
        case .null: .null
        case .integer(let value): value.databaseValue
        case .real(let value): value.databaseValue
        case .text(let value): value.databaseValue
        }
    }
}

/// 一項目の変更。`fields`が無いものは削除(tombstone)。
public struct SyncRecord: Codable, Sendable, Equatable {
    /// 未知の種類を含むfileでも既知の項目は取り込めるよう、文字列のまま持つ。
    public var entity: String
    public var id: String
    public var changedAt: String
    public var fields: [String: SyncValue]?

    public var isDeletion: Bool { fields == nil }
}

public struct SyncBatch: Codable, Sendable, Equatable {
    public var records: [SyncRecord]
}

public struct SyncControlState: Sendable, Equatable {
    public var enabled: Bool
    public var deviceID: String?
    public var folderBookmark: Data?
    public var nextSeq: Int
    public var lastSyncedAt: Date?
    public var lastError: String?
}

/// 書き出し待ちの1行。書き出し後に同じ`changedAt`のままなら消す。
public struct SyncOutboxEntry: Sendable, Equatable {
    public var entity: SyncEntity
    public var recordID: String
    public var changedAt: String
}

public struct SyncPendingBatch: Sendable {
    public var batch: SyncBatch
    public var entries: [SyncOutboxEntry]
}

public enum SyncStoreError: LocalizedError, Sendable, Equatable {
    case unsupportedValue
    case missingField(entity: String, column: String)
    case notEnabled

    public var errorDescription: String? {
        switch self {
        case .unsupportedValue: "同期できない形式の値があります"
        case .missingField(let entity, let column): "同期データの\(entity)に\(column)がありません"
        case .notEnabled: "同期が有効になっていません"
        }
    }
}

/// 同期の状態、書き出し待ち、版、取り込み位置を一つのDBに置く。
/// 変更の記録は`v10-sync`のtriggerが行い、ここでは読み出しと適用だけを扱う。
public struct SyncStore: Sendable {
    let queue: DatabaseQueue
    init(queue: DatabaseQueue) { self.queue = queue }

    public func control() async throws -> SyncControlState {
        try await queue.read { db in try Self.control(db) }
    }

    /// 同期を始める。既にある対象dataは全件を書き出し待ちにする。
    public func enable(deviceID: String, folderBookmark: Data) async throws {
        try await queue.write { db in
            try Self.reset(db)
            try db.execute(sql: """
                UPDATE sync_control SET enabled = 1, device_id = ?, folder_bookmark = ?, next_seq = 1 WHERE id = 1
                """, arguments: [deviceID, folderBookmark])
            for entity in SyncEntity.allCases {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO sync_outbox (entity, record_id, changed_at)
                    SELECT ?, id, strftime('%Y-%m-%dT%H:%M:%fZ', 'now') FROM \(entity.table)
                    """, arguments: [entity.rawValue])
            }
        }
    }

    public func updateFolderBookmark(_ bookmark: Data) async throws {
        try await queue.write { db in
            try db.execute(sql: "UPDATE sync_control SET folder_bookmark = ? WHERE id = 1", arguments: [bookmark])
        }
    }

    /// 同期を解除し、このMacの同期状態をすべて消す。folder内のfileには触れない。
    public func disable() async throws {
        try await queue.write { db in try Self.reset(db) }
    }

    public func recordResult(syncedAt: Date?, error: String?) async throws {
        try await queue.write { db in
            if let syncedAt {
                try db.execute(sql: "UPDATE sync_control SET last_synced_at = ?, last_error = ? WHERE id = 1",
                               arguments: [PersistenceCoding.encode(date: syncedAt), error])
            } else {
                try db.execute(sql: "UPDATE sync_control SET last_error = ? WHERE id = 1", arguments: [error])
            }
        }
    }

    public func pendingCount() async throws -> Int {
        try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_outbox") ?? 0 }
    }

    /// 書き出し待ちを現在の行の値、または削除として読む。
    public func pendingBatch(limit: Int) async throws -> SyncPendingBatch {
        try await queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT entity, record_id, changed_at FROM sync_outbox ORDER BY changed_at LIMIT ?",
                arguments: [limit]
            )
            var records: [SyncRecord] = []
            var entries: [SyncOutboxEntry] = []
            for row in rows {
                let raw: String = row["entity"]
                guard let entity = SyncEntity(rawValue: raw) else { continue }
                let id: String = row["record_id"]
                let changedAt: String = row["changed_at"]
                entries.append(SyncOutboxEntry(entity: entity, recordID: id, changedAt: changedAt))
                let columns = entity.columns.joined(separator: ", ")
                let current = try Row.fetchOne(db, sql: "SELECT \(columns) FROM \(entity.table) WHERE id = ?", arguments: [id])
                let fields = try current.map { row in
                    try Dictionary(uniqueKeysWithValues: entity.columns.map { ($0, try SyncValue(row[$0] as DatabaseValue)) })
                }
                records.append(SyncRecord(entity: raw, id: id, changedAt: changedAt, fields: fields))
            }
            return SyncPendingBatch(batch: SyncBatch(records: records), entries: entries)
        }
    }

    /// file書き込み後に呼ぶ。書き出し中にさらに変わった行は次回へ残す。
    public func markExported(_ pending: SyncPendingBatch, deviceID: String, seq: Int) async throws {
        try await queue.write { db in
            for (entry, record) in zip(pending.entries, pending.batch.records) {
                try db.execute(sql: "DELETE FROM sync_outbox WHERE entity = ? AND record_id = ? AND changed_at = ?",
                               arguments: [entry.entity.rawValue, entry.recordID, entry.changedAt])
                try Self.saveVersion(db, entity: entry.entity.rawValue, id: entry.recordID, changedAt: entry.changedAt,
                                     deviceID: deviceID, deleted: record.isDeletion)
            }
            try db.execute(sql: "UPDATE sync_control SET next_seq = max(next_seq, ?) WHERE id = 1", arguments: [seq + 1])
        }
    }

    public func cursor(for deviceID: String) async throws -> Int {
        try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT last_seq FROM sync_cursors WHERE device_id = ?", arguments: [deviceID]) ?? 0
        }
    }

    /// 他のMacのbatchを一つ適用し、同じtransactionで取り込み位置を進める。
    /// 戻り値は実際に変わった項目数。
    @discardableResult
    public func apply(_ batch: SyncBatch, from deviceID: String, seq: Int) async throws -> Int {
        try await queue.write { db in
            let control = try Self.control(db)
            guard control.enabled, let ownDeviceID = control.deviceID else { throw SyncStoreError.notEnabled }
            var applied = 0
            try Self.withoutRecordingChanges(db) {
                for record in batch.records {
                    guard let entity = SyncEntity(rawValue: record.entity) else {
                        KoeLog.persistence.info("未対応の同期項目を読み飛ばしました: \(record.entity, privacy: .public)")
                        continue
                    }
                    if try Self.apply(record, entity: entity, from: deviceID, ownDeviceID: ownDeviceID, db: db) {
                        applied += 1
                    }
                }
            }
            try db.execute(sql: """
                INSERT INTO sync_cursors (device_id, last_seq) VALUES (?, ?)
                ON CONFLICT (device_id) DO UPDATE SET last_seq = excluded.last_seq
                """, arguments: [deviceID, seq])
            return applied
        }
    }

    // MARK: - transaction内の共通処理

    /// 保持期間による削除、一括削除、他のMacからの適用など、同期先へ伝えない変更を囲む。
    static func withoutRecordingChanges<T>(_ db: Database, _ body: () throws -> T) throws -> T {
        try db.execute(sql: "UPDATE sync_control SET suppressed = 1 WHERE id = 1")
        let value = try body()
        try db.execute(sql: "UPDATE sync_control SET suppressed = 0 WHERE id = 1")
        return value
    }

    static func reset(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE sync_control SET enabled = 0, suppressed = 0, device_id = NULL, folder_bookmark = NULL,
              next_seq = 1, last_synced_at = NULL, last_error = NULL WHERE id = 1
            """)
        try db.execute(sql: "DELETE FROM sync_outbox")
        try db.execute(sql: "DELETE FROM sync_versions")
        try db.execute(sql: "DELETE FROM sync_cursors")
    }

    private static func control(_ db: Database) throws -> SyncControlState {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_control WHERE id = 1") else {
            return SyncControlState(enabled: false, nextSeq: 1)
        }
        return SyncControlState(
            enabled: row["enabled"],
            deviceID: row["device_id"],
            folderBookmark: row["folder_bookmark"],
            nextSeq: row["next_seq"],
            lastSyncedAt: try (row["last_synced_at"] as String?).map(PersistenceCoding.decodeDate),
            lastError: row["last_error"]
        )
    }

    /// 後勝ち: `(changed_at, device_id)`が既知の版より新しいときだけ適用する。
    private static func apply(
        _ record: SyncRecord,
        entity: SyncEntity,
        from deviceID: String,
        ownDeviceID: String,
        db: Database
    ) throws -> Bool {
        let incoming = Version(changedAt: record.changedAt, deviceID: deviceID)
        if let known = try Row.fetchOne(db, sql: """
            SELECT changed_at, device_id FROM sync_versions WHERE entity = ? AND record_id = ?
            """, arguments: [entity.rawValue, record.id]),
           incoming <= Version(changedAt: known["changed_at"], deviceID: known["device_id"]) {
            return false
        }
        if let pending = try String.fetchOne(db, sql: """
            SELECT changed_at FROM sync_outbox WHERE entity = ? AND record_id = ?
            """, arguments: [entity.rawValue, record.id]),
           incoming <= Version(changedAt: pending, deviceID: ownDeviceID) {
            return false
        }

        if let fields = record.fields {
            var values: [DatabaseValue] = []
            for column in entity.columns {
                guard let value = fields[column] else {
                    throw SyncStoreError.missingField(entity: entity.rawValue, column: column)
                }
                values.append(value.databaseValue)
            }
            guard values.first == record.id.databaseValue else {
                throw SyncStoreError.missingField(entity: entity.rawValue, column: "id")
            }
            let columns = entity.columns.joined(separator: ", ")
            let placeholders = Array(repeating: "?", count: values.count).joined(separator: ", ")
            let updates = entity.columns.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
            try db.execute(
                sql: "INSERT INTO \(entity.table) (\(columns)) VALUES (\(placeholders)) ON CONFLICT (id) DO UPDATE SET \(updates)",
                arguments: StatementArguments(values)
            )
        } else {
            try db.execute(sql: "DELETE FROM \(entity.table) WHERE id = ?", arguments: [record.id])
        }
        try db.execute(sql: "DELETE FROM sync_outbox WHERE entity = ? AND record_id = ?",
                       arguments: [entity.rawValue, record.id])
        try saveVersion(db, entity: entity.rawValue, id: record.id, changedAt: record.changedAt,
                        deviceID: deviceID, deleted: record.isDeletion)
        return true
    }

    private static func saveVersion(
        _ db: Database, entity: String, id: String, changedAt: String, deviceID: String, deleted: Bool
    ) throws {
        try db.execute(sql: """
            INSERT INTO sync_versions (entity, record_id, changed_at, device_id, deleted) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (entity, record_id) DO UPDATE SET changed_at = excluded.changed_at,
              device_id = excluded.device_id, deleted = excluded.deleted
            """, arguments: [entity, id, changedAt, deviceID, deleted])
    }

    private struct Version: Comparable {
        var changedAt: String
        var deviceID: String
        static func < (lhs: Version, rhs: Version) -> Bool {
            (lhs.changedAt, lhs.deviceID) < (rhs.changedAt, rhs.deviceID)
        }
    }
}
