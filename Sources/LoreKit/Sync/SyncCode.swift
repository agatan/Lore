import CryptoKit
import Foundation

/// 同期鍵を人が書き写せる形にする。鍵32 byteとSHA-256先頭2 byteをbase32にし、4文字ずつ区切る。
public enum SyncCode {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    private static let checksumLength = 2

    public static func generateKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    public static func encode(_ key: SymmetricKey) -> String {
        let bytes = key.withUnsafeBytes { Data($0) }
        let payload = bytes + Data(SHA256.hash(data: bytes).prefix(checksumLength))
        let text = base32(payload)
        return stride(from: 0, to: text.count, by: 4).map { offset in
            let start = text.index(text.startIndex, offsetBy: offset)
            let end = text.index(start, offsetBy: min(4, text.count - offset))
            return String(text[start..<end])
        }.joined(separator: "-")
    }

    /// 大文字小文字、空白、ハイフンの違いは許す。打ち間違いはchecksumで検出する。
    public static func decode(_ code: String) throws -> SymmetricKey {
        let normalized = code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard let payload = fromBase32(normalized), payload.count == 32 + checksumLength else {
            throw SyncCodeError.malformed
        }
        let bytes = payload.prefix(32)
        guard Data(SHA256.hash(data: bytes).prefix(checksumLength)) == payload.suffix(checksumLength) else {
            throw SyncCodeError.checksumMismatch
        }
        return SymmetricKey(data: bytes)
    }

    private static func base32(_ data: Data) -> String {
        var output = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                output.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { output.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return output
    }

    private static func fromBase32(_ text: String) -> Data? {
        var output = Data()
        var buffer = 0
        var bits = 0
        for character in text {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = ((buffer << 5) | value) & 0xFFFF
            bits += 5
            if bits >= 8 {
                output.append(UInt8((buffer >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return output
    }
}

public enum SyncCodeError: LocalizedError, Equatable {
    case malformed
    case checksumMismatch

    public var errorDescription: String? {
        switch self {
        case .malformed: "同期コードの形式が正しくありません"
        case .checksumMismatch: "同期コードに書き写し間違いがあります"
        }
    }
}
