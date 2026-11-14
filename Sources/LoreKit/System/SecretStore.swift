import Foundation
import Security
import Synchronization

/// API キーの置き場所。Keychain の generic password 1 件を読み書きするだけ。
///
/// 設定 JSON(UserDefaults)にも履歴 DB にも書かない。平文で残る場所を増やさないため、
/// 秘密の出入口はここ 1 つに閉じる。値そのものはログにも UI にも出さない(NFR-2)。
public enum SecretStore {
    public enum Key: String, Hashable, Sendable, CaseIterable {
        case groqApiKey = "groq.apiKey"
        case openAIApiKey = "openai.apiKey"
        case anthropicApiKey = "anthropic.apiKey"
        case geminiApiKey = "gemini.apiKey"
        /// Mac間同期の鍵。同期コードの文字列で持ち、iCloud Keychainへは同期しない。
        case syncKey = "sync.key"
        // ライフログ要約の廃止前に保存した可能性があるキー。読み出さず、全削除でだけ消す。
        case lifeLogGroqApiKey = "lifeLog.groq.apiKey"
        case lifeLogOpenAIApiKey = "lifeLog.openai.apiKey"
        case lifeLogAnthropicApiKey = "lifeLog.anthropic.apiKey"
        case lifeLogGeminiApiKey = "lifeLog.gemini.apiKey"
    }

    static let service = "dev.agatan.Lore"

    /// 読み出した値のプロセス内キャッシュ。
    ///
    /// キーチェーンは**照会のたびに OS が許可を訊きうる**。整形のたび・設定を触るたびに
    /// 生で `SecItemCopyMatching` を叩くと、ダイアログが何度も出て利用者を不安にさせる
    /// (実際にそうなった、C-71)。プロセスの寿命の間は 1 回読めば十分で、
    /// 書き込み(`write`)は必ずここを通るのでキャッシュはずれない。
    private enum CachedSecret: Sendable {
        case value(String)
        case missing
    }

    private static let cache = Mutex<[Key: CachedSecret]>([:])

    public static func read(_ key: Key) throws -> String? {
        try cache.withLock { cachedValues in
            if let cached = cachedValues[key] {
                switch cached {
                case .value(let value): return value
                case .missing: return nil
                }
            }
            do {
                let value = try readFromKeychain(key)
                cachedValues[key] = value.map(CachedSecret.value) ?? .missing
                return value
            } catch let error as SecretStoreError {
                // 照会中もlockを保持する。並行する派生処理が認証ダイアログを
                // 複数予約するのを防ぎ、最初の許可・拒否結果を全処理で共有する。
                if error.status == errSecUserCanceled || error.status == errSecAuthFailed || error.status == errSecInteractionNotAllowed {
                    cachedValues[key] = .missing
                }
                throw error
            }
        }
    }

    private static func readFromKeychain(_ key: Key) throws -> String? {
        try readItem(service: service, account: key.rawValue)
    }

    /// `nil` を渡すと削除する。
    public static func write(_ value: String?, for key: Key) throws {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            cache.withLock {
                $0[key] = if let trimmed, !trimmed.isEmpty { .value(trimmed) } else { .missing }
            }
        }
        guard let trimmed, !trimmed.isEmpty else {
            let status = SecItemDelete(baseQuery(key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError(status: status, operation: "削除")
            }
            return
        }

        let data = Data(trimmed.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = baseQuery(key)
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecretStoreError(status: addStatus, operation: "保存")
            }
        default:
            throw SecretStoreError(status: status, operation: "保存")
        }
    }

    /// 旧名Koeのserviceに残るsecretを、このserviceへ移す。起動直後、secretを読む前に一度だけ呼ぶ。
    @discardableResult
    public static func migrateLegacyKoeService() throws -> [String] {
        try LegacyKoeMigration.migrateSecrets(
            accounts: Key.allCases.map(\.rawValue),
            to: service,
            backend: .init(
                read: { service, account in
                    if service == Self.service, let key = Key(rawValue: account) { return try read(key) }
                    return try readItem(service: service, account: account)
                },
                write: { _, account, value in
                    guard let key = Key(rawValue: account) else { return }
                    try write(value, for: key)
                },
                delete: { service, account in
                    let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
                    guard status == errSecSuccess || status == errSecItemNotFound else {
                        throw SecretStoreError(status: status, operation: "削除")
                    }
                }
            )
        )
    }

    private static func readItem(service: String, account: String) throws -> String? {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw SecretStoreError(status: errSecDecode, operation: "読み出し")
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError(status: status, operation: "読み出し")
        }
    }

    public static func deleteAll() throws {
        for key in Key.allCases {
            try write(nil, for: key)
        }
    }

    private static func baseQuery(_ key: Key) -> [String: Any] {
        query(service: service, account: key.rawValue)
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public struct SecretStoreError: LocalizedError, Sendable {
    public let status: OSStatus
    public let operation: String

    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "キーチェーンの\(operation)に失敗しました(\(detail))"
    }
}
