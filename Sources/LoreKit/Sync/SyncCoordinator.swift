import AppKit
import CryptoKit
import Foundation
import GRDB
import Observation

/// 同期の開始・参加・解除と、書き出し・取り込みの実行契機を持つ。
///
/// 書き出しはoutboxの変化から5秒debounceし、取り込みは起動時、app activation、120秒ごと、手動で行う。
@MainActor
@Observable
public final class SyncCoordinator {
    public private(set) var isEnabled = false
    public private(set) var folderPath: String?
    public private(set) var lastSyncedAt: Date?
    public private(set) var lastError: String?
    public private(set) var isSyncing = false

    @ObservationIgnored private var database: LoreDatabase?
    @ObservationIgnored private var onImported: @MainActor () async -> Void = {}
    @ObservationIgnored private var key: SymmetricKey?
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    static let exportDelay: Duration = .seconds(5)
    static let importInterval: Duration = .seconds(120)

    public init() {}

    public func configure(database: LoreDatabase, onImported: @MainActor @escaping () async -> Void) async {
        self.database = database
        self.onImported = onImported
        await reloadState()
        if isEnabled {
            startScheduling()
            await syncNow()
        }
    }

    // MARK: - 利用者の操作

    /// 1台目のMac。鍵を作ってfolderを初期化し、他のMacへ入力してもらう同期コードを返す。
    public func startNew(folder: URL) async throws -> String {
        let database = try requireDatabase()
        let key = SyncCode.generateKey()
        let engine = SyncEngine(database: database, folder: folder, key: key)
        try await Task.detached { try engine.prepareNewFolder() }.value
        let code = SyncCode.encode(key)
        try await activate(code: code, key: key, folder: folder, database: database)
        return code
    }

    /// 2台目以降。同期コードがfolderと一致することを確かめてから参加する。
    public func join(code: String, folder: URL) async throws {
        let database = try requireDatabase()
        let key = try SyncCode.decode(code)
        let engine = SyncEngine(database: database, folder: folder, key: key)
        try await Task.detached { try engine.verifyExistingFolder() }.value
        try await activate(code: SyncCode.encode(key), key: key, folder: folder, database: database)
    }

    public func revealCode() throws -> String {
        guard let code = try SecretStore.read(.syncKey) else { throw SyncCoordinatorError.missingKey }
        return code
    }

    /// このMacの鍵と同期状態を消す。folder内のfileには触れない。
    public func disconnect() async throws {
        let database = try requireDatabase()
        stopScheduling()
        try await database.sync.disable()
        try SecretStore.write(nil, for: .syncKey)
        key = nil
        await reloadState()
    }

    /// 「Loreを初期化」の後。DBとKeychainは呼び出し側が消している。
    public func didDeleteAllData() async {
        stopScheduling()
        key = nil
        await reloadState()
    }

    /// CLI/MCPなど別processの書き込みは、DBの変更監視では届かないため明示的に呼ぶ。
    public func localDataChanged() {
        guard isEnabled else { return }
        scheduleExport()
    }

    public func syncNow() async {
        guard isEnabled, !isSyncing, let database else { return }
        isSyncing = true
        defer { isSyncing = false }
        var failure: String?
        var applied = 0
        do {
            let engine = try await makeEngine(database: database)
            try await engine.export()
            let report = try await engine.importAll()
            applied = report.appliedChanges
            if !report.failures.isEmpty {
                failure = report.failures.joined(separator: "\n")
            }
        } catch {
            failure = error.localizedDescription
            LoreLog.persistence.error("同期に失敗: \(error.localizedDescription, privacy: .public)")
        }
        await record(syncedAt: failure == nil ? Date() : nil, error: failure, database: database)
        if applied > 0 { await onImported() }
    }

    // MARK: - 内部

    private func activate(code: String, key: SymmetricKey, folder: URL, database: LoreDatabase) async throws {
        let bookmark = try folder.bookmarkData()
        try SecretStore.write(code, for: .syncKey)
        do {
            try await database.sync.enable(deviceID: UUID().uuidString, folderBookmark: bookmark)
        } catch {
            try SecretStore.write(nil, for: .syncKey)
            throw error
        }
        self.key = key
        await reloadState()
        startScheduling()
        await syncNow()
    }

    private func makeEngine(database: LoreDatabase) async throws -> SyncEngine {
        let state = try await database.sync.control()
        guard let bookmark = state.folderBookmark else { throw SyncCoordinatorError.missingFolder }
        var isStale = false
        let folder = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
        if isStale { try await database.sync.updateFolderBookmark(try folder.bookmarkData()) }
        folderPath = folder.path(percentEncoded: false)
        return SyncEngine(database: database, folder: folder, key: try loadKey())
    }

    private func loadKey() throws -> SymmetricKey {
        if let key { return key }
        guard let code = try SecretStore.read(.syncKey) else { throw SyncCoordinatorError.missingKey }
        let key = try SyncCode.decode(code)
        self.key = key
        return key
    }

    private func scheduleExport() {
        exportTask?.cancel()
        exportTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.exportDelay) } catch { return }
            await self?.exportPending()
        }
    }

    private func exportPending() async {
        guard isEnabled, !isSyncing, let database else { return }
        do {
            try await makeEngine(database: database).export()
        } catch {
            LoreLog.persistence.error("同期の書き出しに失敗: \(error.localizedDescription, privacy: .public)")
            await record(syncedAt: nil, error: error.localizedDescription, database: database)
        }
    }

    private func startScheduling() {
        guard let database, observation == nil else { return }
        observation = DatabaseRegionObservation(tracking: Table("sync_outbox")).start(
            in: database.queue,
            onError: { error in
                LoreLog.persistence.error("同期の変更監視に失敗: \(error.localizedDescription, privacy: .public)")
            },
            onChange: { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleExport() }
            }
        )
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.importInterval) } catch { return }
                await self?.syncNow()
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.syncNow() }
        }
    }

    private func stopScheduling() {
        observation?.cancel()
        observation = nil
        timerTask?.cancel()
        timerTask = nil
        exportTask?.cancel()
        exportTask = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    private func record(syncedAt: Date?, error: String?, database: LoreDatabase) async {
        do {
            try await database.sync.recordResult(syncedAt: syncedAt, error: error)
        } catch {
            LoreLog.persistence.error("同期状態を保存できません: \(error.localizedDescription, privacy: .public)")
        }
        await reloadState()
        if let error { lastError = error }
    }

    private func reloadState() async {
        guard let database else { return }
        do {
            let state = try await database.sync.control()
            isEnabled = state.enabled
            lastSyncedAt = state.lastSyncedAt
            lastError = state.lastError
            if let bookmark = state.folderBookmark {
                var isStale = false
                folderPath = (try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale))?
                    .path(percentEncoded: false)
            } else {
                folderPath = nil
            }
        } catch {
            lastError = error.localizedDescription
            LoreLog.persistence.error("同期状態を読めません: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func requireDatabase() throws -> LoreDatabase {
        guard let database else { throw SyncCoordinatorError.databaseUnavailable }
        return database
    }
}

public enum SyncCoordinatorError: LocalizedError {
    case databaseUnavailable
    case missingKey
    case missingFolder

    public var errorDescription: String? {
        switch self {
        case .databaseUnavailable: "データベースを開けていないため同期できません"
        case .missingKey: "このMacに同期コードがありません。同期を解除して、もう一度参加してください"
        case .missingFolder: "同期フォルダが設定されていません"
        }
    }
}
