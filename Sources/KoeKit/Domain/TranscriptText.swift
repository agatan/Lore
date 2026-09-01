import Foundation

/// STT providerの制御用tokenを利用者dataへ混ぜないための共通境界。
public enum TranscriptText {
    public static func sanitized(_ input: String) -> String {
        var value = input
        while let start = value.range(of: "<|"),
              let end = value.range(of: "|>", range: start.upperBound..<value.endIndex) {
            value.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
