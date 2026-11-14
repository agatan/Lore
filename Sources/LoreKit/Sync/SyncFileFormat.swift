import CryptoKit
import Foundation

/// 同期fileの形式。
///
/// `LORESYNC` magic、format version 1 byte、header JSON長(UInt32 big endian)、header JSON、
/// AES-GCM combined box(nonce 12 byte + 暗号文 + tag 16 byte)。Magicからheader JSONまでを
/// associated dataとして認証するので、別のMacや別の番号のfileへのすり替えも検出できる。
public enum SyncFileFormat {
    public struct Header: Codable, Sendable, Equatable {
        public var device: String
        public var seq: Int
    }

    static let magic = Data("LORESYNC".utf8)
    static let version: UInt8 = 1
    static let keycheckPlaintext = Data("lore-sync-keycheck-v1".utf8)
    static let keycheckHeader = Header(device: "keycheck", seq: 0)

    public static func seal(_ plaintext: Data, header: Header, key: SymmetricKey) throws -> Data {
        let headerJSON = try JSONEncoder().encode(header)
        var prefix = magic
        prefix.append(version)
        var length = UInt32(headerJSON.count).bigEndian
        prefix.append(Data(bytes: &length, count: 4))
        prefix.append(headerJSON)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: prefix)
        guard let combined = box.combined else { throw SyncFileError.sealFailed }
        return prefix + combined
    }

    public static func open(_ data: Data, key: SymmetricKey) throws -> (Header, Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= magic.count + 1 + 4, Data(bytes.prefix(magic.count)) == magic else {
            throw SyncFileError.notSyncFile
        }
        let fileVersion = bytes[magic.count]
        guard fileVersion == version else { throw SyncFileError.unsupportedVersion(fileVersion) }
        let lengthOffset = magic.count + 1
        let length = bytes[lengthOffset..<lengthOffset + 4].reduce(0) { ($0 << 8) | Int($1) }
        let headerEnd = lengthOffset + 4 + length
        // nonce 12 byte + tag 16 byteより短いものは途中までしか届いていない。
        guard length > 0, bytes.count >= headerEnd + 28 else { throw SyncFileError.truncated }
        let prefix = Data(bytes[0..<headerEnd])
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: Data(bytes[(lengthOffset + 4)..<headerEnd]))
        } catch {
            throw SyncFileError.truncated
        }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(bytes[headerEnd...]))
            return (header, try AES.GCM.open(box, using: key, authenticating: prefix))
        } catch {
            throw SyncFileError.authenticationFailed
        }
    }

    public static func encode(_ batch: SyncBatch) throws -> Data {
        let json = try JSONEncoder().encode(batch)
        return try (json as NSData).compressed(using: .lzfse) as Data
    }

    public static func decode(_ data: Data) throws -> SyncBatch {
        let json: Data
        do {
            json = try (data as NSData).decompressed(using: .lzfse) as Data
        } catch {
            throw SyncFileError.corruptPayload
        }
        do {
            return try JSONDecoder().decode(SyncBatch.self, from: json)
        } catch {
            throw SyncFileError.corruptPayload
        }
    }
}

public enum SyncFileError: LocalizedError, Equatable {
    case notSyncFile
    case unsupportedVersion(UInt8)
    case truncated
    case authenticationFailed
    case corruptPayload
    case sealFailed
    case headerMismatch

    public var errorDescription: String? {
        switch self {
        case .notSyncFile: String(lore: "Loreの同期fileではありません")
        case .unsupportedVersion(let version): String(lore: "新しい形式(\(Int(version)))の同期fileです。Loreを更新してください")
        case .truncated: String(lore: "同期fileが途中までしか届いていません")
        case .authenticationFailed: String(lore: "同期fileを復号できません。同期コードが違うか、fileが途中までしか届いていないか、改ざんされています")
        case .corruptPayload: String(lore: "同期fileの中身を読み取れません")
        case .sealFailed: String(lore: "同期fileを暗号化できませんでした")
        case .headerMismatch: String(lore: "同期fileの名前と中身が一致しません")
        }
    }
}
