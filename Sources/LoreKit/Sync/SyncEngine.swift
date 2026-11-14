import CryptoKit
import Foundation

/// 利用者が選んだfolderの`Lore Sync/`を介した書き出しと取り込み。
///
/// Loreはnetworkへ接続しない。iCloud DriveやDropboxなどfolderの提供元が暗号化fileを運ぶ。
/// 各Macは`devices/<device-id>/<10桁seq>.loresync`へ追記するだけで、他のMacのfileは書き換えない。
public struct SyncEngine: Sendable {
    public static let directoryName = "Lore Sync"
    static let fileExtension = "loresync"
    static let batchLimit = 1_000

    public struct ImportReport: Sendable, Equatable {
        public var appliedChanges = 0
        public var failures: [String] = []
        public var waitingForDownload = 0
    }

    let database: LoreDatabase
    let root: URL
    let key: SymmetricKey

    public init(database: LoreDatabase, folder: URL, key: SymmetricKey) {
        self.database = database
        self.root = folder.appending(path: Self.directoryName, directoryHint: .isDirectory)
        self.key = key
    }

    var devicesDirectory: URL { root.appending(path: "devices", directoryHint: .isDirectory) }
    var keycheckURL: URL { root.appending(path: "keycheck.\(Self.fileExtension)") }

    // MARK: - 参加

    /// 最初のMac。folderが別の同期コードで使われていれば上書きしない。
    public func prepareNewFolder() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: keycheckURL.path) || fileManager.fileExists(atPath: placeholder(for: keycheckURL).path) {
            throw SyncEngineError.folderAlreadyUsed
        }
        try fileManager.createDirectory(at: devicesDirectory, withIntermediateDirectories: true)
        let sealed = try SyncFileFormat.seal(SyncFileFormat.keycheckPlaintext, header: SyncFileFormat.keycheckHeader, key: key)
        try sealed.write(to: keycheckURL, options: .atomic)
    }

    /// 2台目以降。同期コードが1台目と同じことを確認fileで検証する。
    public func verifyExistingFolder() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: keycheckURL.path) else {
            if fileManager.fileExists(atPath: placeholder(for: keycheckURL).path) {
                try fileManager.startDownloadingUbiquitousItem(at: keycheckURL)
                throw SyncEngineError.notDownloadedYet
            }
            throw SyncEngineError.folderNotInitialized
        }
        let data = try Data(contentsOf: keycheckURL)
        let header: SyncFileFormat.Header
        let plaintext: Data
        do {
            (header, plaintext) = try SyncFileFormat.open(data, key: key)
        } catch SyncFileError.authenticationFailed {
            throw SyncEngineError.wrongCode
        }
        guard header == SyncFileFormat.keycheckHeader, plaintext == SyncFileFormat.keycheckPlaintext else {
            throw SyncEngineError.wrongCode
        }
        try fileManager.createDirectory(at: devicesDirectory, withIntermediateDirectories: true)
    }

    // MARK: - 書き出し

    /// 書き出し待ちをすべてfileにする。戻り値は書き出した項目数。
    @discardableResult
    public func export() async throws -> Int {
        var total = 0
        while true {
            let written = try await exportOnce()
            total += written
            if written < Self.batchLimit { return total }
        }
    }

    private func exportOnce() async throws -> Int {
        let store = database.sync
        let control = try await store.control()
        guard control.enabled, let deviceID = control.deviceID else { throw SyncStoreError.notEnabled }
        let pending = try await store.pendingBatch(limit: Self.batchLimit)
        guard !pending.entries.isEmpty else { return 0 }

        let directory = devicesDirectory.appending(path: deviceID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // DB更新前にcrashしても、既に書いた番号は再利用しない。
        let seq = max(control.nextSeq, (try highestSeq(in: directory)) + 1)
        let payload = try SyncFileFormat.encode(pending.batch)
        let sealed = try SyncFileFormat.seal(payload, header: .init(device: deviceID, seq: seq), key: key)
        try sealed.write(to: directory.appending(path: Self.fileName(seq)), options: .atomic)
        try await store.markExported(pending, deviceID: deviceID, seq: seq)
        return pending.entries.count
    }

    // MARK: - 取り込み

    /// 他のMacの未取り込みfileを番号順に適用する。読めないfileで止め、後続は次回まで待つ。
    public func importAll() async throws -> ImportReport {
        let store = database.sync
        let control = try await store.control()
        guard control.enabled, let ownDeviceID = control.deviceID else { throw SyncStoreError.notEnabled }
        var report = ImportReport()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: devicesDirectory.path) else {
            throw SyncEngineError.folderUnavailable(devicesDirectory.path(percentEncoded: false))
        }
        let devices = try fileManager.contentsOfDirectory(
            at: devicesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .map(\.lastPathComponent)
        .filter { $0 != ownDeviceID && UUID(uuidString: $0) != nil }
        .sorted()

        for deviceID in devices {
            let directory = devicesDirectory.appending(path: deviceID, directoryHint: .isDirectory)
            var seq = try await store.cursor(for: deviceID) + 1
            while true {
                let url = directory.appending(path: Self.fileName(seq))
                guard fileManager.fileExists(atPath: url.path) else {
                    if fileManager.fileExists(atPath: placeholder(for: url).path) {
                        // iCloud Driveで手元に無いfile。downloadを頼み、届いた後の同期で取り込む。
                        try fileManager.startDownloadingUbiquitousItem(at: url)
                        report.waitingForDownload += 1
                    }
                    break
                }
                do {
                    let (header, payload) = try SyncFileFormat.open(try Data(contentsOf: url), key: key)
                    guard header.device == deviceID, header.seq == seq else { throw SyncFileError.headerMismatch }
                    let batch = try SyncFileFormat.decode(payload)
                    report.appliedChanges += try await store.apply(batch, from: deviceID, seq: seq)
                    seq += 1
                } catch {
                    let message = "\(deviceID.prefix(8))の\(seq)番: \(error.localizedDescription)"
                    LoreLog.persistence.error("同期fileを取り込めません: \(message, privacy: .public)")
                    report.failures.append(message)
                    break
                }
            }
        }
        return report
    }

    // MARK: - file名

    static func fileName(_ seq: Int) -> String { String(format: "%010d.%@", seq, fileExtension) }

    private func highestSeq(in directory: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .compactMap { name -> Int? in
                // `.0000000001.loresync.icloud`のようなplaceholderも番号を使用済みとして数える。
                let trimmed = name.hasPrefix(".") && name.hasSuffix(".icloud")
                    ? String(name.dropFirst().dropLast(".icloud".count))
                    : name
                guard trimmed.hasSuffix(".\(Self.fileExtension)") else { return nil }
                return Int(trimmed.dropLast(Self.fileExtension.count + 1))
            }
            .max() ?? 0
    }

    private func placeholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
    }
}

public enum SyncEngineError: LocalizedError, Equatable {
    case folderAlreadyUsed
    case folderNotInitialized
    case wrongCode
    case notDownloadedYet
    case folderUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .folderAlreadyUsed:
            "このフォルダは別の同期で使われています。「同期コードで参加」から、そのコードを入力してください"
        case .folderNotInitialized:
            "このフォルダに同期データがありません。1台目のMacで選んだフォルダを指定してください"
        case .wrongCode:
            "同期コードがこのフォルダと一致しません"
        case .notDownloadedYet:
            "フォルダの同期データがまだこのMacに届いていません。しばらく待ってからやり直してください"
        case .folderUnavailable(let path):
            "同期フォルダを開けません: \(path)"
        }
    }
}
