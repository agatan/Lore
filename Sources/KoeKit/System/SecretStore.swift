import Foundation
import Security
import Synchronization

/// API キーの置き場所。Keychain の generic password 1 件を読み書きするだけ。
///
/// 設定 JSON(UserDefaults)にも履歴 DB にも書かない。平文で残る場所を増やさないため、
/// 秘密の出入口はここ 1 つに閉じる。値そのものはログにも UI にも出さない(NFR-2)。
public enum SecretStore {
    public enum Key: String, Hashable, Sendable {
        case groqApiKey = "groq.apiKey"
    }

    static let service = "dev.agatan.Koe"

    /// 読み出した値のプロセス内キャッシュ。
    ///
    /// キーチェーンは**照会のたびに OS が許可を訊きうる**。整形のたび・設定を触るたびに
    /// 生で `SecItemCopyMatching` を叩くと、ダイアログが何度も出て利用者を不安にさせる
    /// (実際にそうなった、C-71)。プロセスの寿命の間は 1 回読めば十分で、
    /// 書き込み(`write`)は必ずここを通るのでキャッシュはずれない。
    private static let cache = Mutex<[Key: String?]>([:])

    public static func read(_ key: Key) throws -> String? {
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let value = try readFromKeychain(key)
        cache.withLock { $0[key] = value }
        return value
    }

    private static func readFromKeychain(_ key: Key) throws -> String? {
        var query = baseQuery(key)
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

    /// `nil` を渡すと削除する。
    public static func write(_ value: String?, for key: Key) throws {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { cache.withLock { $0[key] = (trimmed?.isEmpty == false) ? trimmed : nil } }
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

    private static func baseQuery(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
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
