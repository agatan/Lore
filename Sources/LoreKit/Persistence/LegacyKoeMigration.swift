import Foundation

/// 旧名「Koe」で保存したデータを、改名後の「Lore」の置き場所へ一度だけ移す。
///
/// 改名でbundle ID、Application Supportのfolder、DB file名、Keychainのservice、
/// UserDefaultsのdomainがすべて変わった。何もしなければ利用者の記録・設定・API keyが
/// 見えなくなるため、DBを開く前と設定を読む前にここを通す。
/// 旧名はこのfileだけに閉じ込め、ほかのcodeは新しい名前だけを知る。
public enum LegacyKoeMigration {
    public static let bundleIdentifier = "dev.agatan.Koe"
    public static let directoryName = "Koe"
    public static let databaseFileName = "koe.sqlite"
    public static let settingsKey = "koe.settings.v1"
    /// 移した後に設定へ残す印。旧domainを二度読まない。
    static let defaultsMigratedKey = "lore.migratedFromKoe"

    public enum DirectoryOutcome: Equatable, Sendable {
        /// 旧folderがない。新規利用か、すでに移し終えている。
        case notNeeded
        /// 旧folderを新しい場所へ移した。
        case moved
        /// 新旧どちらのfolderもある。混ぜずに新しい方を使い、旧folderはそのまま残す。
        case leftLegacyInPlace(URL)
    }

    /// `<Application Support>/Koe`を`<Application Support>/Lore`へ移し、DB fileを`lore.sqlite`へ改名する。
    ///
    /// 同じvolume内のrenameなので、途中で落ちても旧folderか新folderのどちらかに全体が残る。
    /// 移動に失敗したら例外をそのまま返し、呼び出し側はDBを開かない（空のDBを新しく作ると
    /// 次回「両方ある」状態になり、旧データへ戻れなくなるため）。
    public static func migrateApplicationSupport(
        in applicationSupport: URL,
        newDirectoryName: String = LoreDatabase.directoryName,
        fileManager: FileManager = .default
    ) throws -> DirectoryOutcome {
        let legacy = applicationSupport.appending(path: directoryName, directoryHint: .isDirectory)
        let current = applicationSupport.appending(path: newDirectoryName, directoryHint: .isDirectory)
        let legacyExists = fileManager.fileExists(atPath: legacy.path)
        let currentExists = fileManager.fileExists(atPath: current.path)

        if legacyExists && currentExists {
            // 移動の後、DBの改名前に止まった場合もここへ来ないよう、改名だけは新folderで続ける。
            try renameDatabaseFiles(in: current, fileManager: fileManager)
            return .leftLegacyInPlace(legacy)
        }
        if legacyExists {
            try fileManager.moveItem(at: legacy, to: current)
            try renameDatabaseFiles(in: current, fileManager: fileManager)
            return .moved
        }
        if currentExists {
            try renameDatabaseFiles(in: current, fileManager: fileManager)
        }
        return .notNeeded
    }

    /// `koe.sqlite`と`-wal`/`-shm`/`-journal`を`lore.sqlite`側へ改名する。
    /// 新しい名前のDBがすでにあれば上書きせず、旧fileを残す。
    static func renameDatabaseFiles(in directory: URL, fileManager: FileManager = .default) throws {
        let legacyDatabase = directory.appending(path: databaseFileName)
        let currentDatabase = directory.appending(path: LoreDatabase.databaseFileName)
        guard fileManager.fileExists(atPath: legacyDatabase.path),
              !fileManager.fileExists(atPath: currentDatabase.path) else { return }
        // 本体を最後に移す。途中で止まっても、次回は本体が旧名のまま残っているので続きから移せる。
        for suffix in ["-wal", "-shm", "-journal", ""] {
            let source = directory.appending(path: databaseFileName + suffix)
            let destination = directory.appending(path: LoreDatabase.databaseFileName + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    /// 旧domainの設定を新しいdomainへ一度だけ写す。設定JSONの鍵名も新しい名前へ変える。
    ///
    /// 新しいdomainにすでに設定があれば写さない（改名後に変えた設定を古い値で戻さない）。
    /// - Returns: 写した場合true。
    @discardableResult
    public static func migrateDefaults(legacyDomain: [String: Any]?, into defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: defaultsMigratedKey) else { return false }
        defer { defaults.set(true, forKey: defaultsMigratedKey) }
        guard let legacyDomain, !legacyDomain.isEmpty,
              defaults.object(forKey: AppSettings.defaultsKey) == nil else { return false }
        for (key, value) in legacyDomain {
            let target = key == settingsKey ? AppSettings.defaultsKey : key
            defaults.set(value, forKey: target)
        }
        return true
    }

    /// 旧domainを、そのdomainの持ち主でないprocessから読む。
    public static func legacyDefaultsDomain() -> [String: Any]? {
        UserDefaults.standard.persistentDomain(forName: bundleIdentifier)
    }

    /// Keychainの読み書きを差し替えられるようにした、secret移行の手順。
    public struct SecretBackend {
        public var read: (_ service: String, _ account: String) throws -> String?
        public var write: (_ service: String, _ account: String, _ value: String) throws -> Void
        public var delete: (_ service: String, _ account: String) throws -> Void

        public init(
            read: @escaping (String, String) throws -> String?,
            write: @escaping (String, String, String) throws -> Void,
            delete: @escaping (String, String) throws -> Void
        ) {
            self.read = read
            self.write = write
            self.delete = delete
        }
    }

    /// 旧serviceのsecretを新しいserviceへ写し、写せたものだけ旧itemを消す。
    ///
    /// 新しいserviceに値があれば上書きせず、旧itemだけを消す。1件の失敗で残りを止めず、
    /// 失敗したaccountは旧itemを残したまま例外として返す。
    /// - Returns: 新しいserviceへ写したaccount。
    @discardableResult
    public static func migrateSecrets(
        accounts: [String],
        to service: String,
        backend: SecretBackend
    ) throws -> [String] {
        var migrated: [String] = []
        var failures: [(String, any Error)] = []
        for account in accounts {
            do {
                guard let value = try backend.read(bundleIdentifier, account) else { continue }
                if try backend.read(service, account) == nil {
                    try backend.write(service, account, value)
                    migrated.append(account)
                }
                try backend.delete(bundleIdentifier, account)
            } catch {
                failures.append((account, error))
            }
        }
        if !failures.isEmpty {
            throw SecretMigrationError(failures: failures.map { ($0.0, $0.1.localizedDescription) })
        }
        return migrated
    }
}

public struct SecretMigrationError: LocalizedError, Sendable {
    public let failures: [(account: String, reason: String)]

    public var errorDescription: String? {
        let details = failures.map { "\($0.account): \($0.reason)" }.joined(separator: "、")
        return String(lore: "以前のKoeのAPIキーを移せませんでした（\(details)）。設定で入力し直してください。")
    }
}
