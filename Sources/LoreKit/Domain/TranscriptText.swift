import Foundation

/// STT providerの制御用tokenを利用者dataへ混ぜないための共通境界。
public enum TranscriptText {
    private static let whisperBoilerplate = "ご視聴ありがとうございました"
    private static let sentenceBoundaries = CharacterSet(charactersIn: "。！？!?")

    public static func sanitized(_ input: String) -> String {
        var value = input
        while let start = value.range(of: "<|"),
              let end = value.range(of: "|>", range: start.upperBound..<value.endIndex) {
            value.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// whisper.cppが無音・環境音から生成する既知の定型文だけを除く。
    /// 引用や語句として使われた場合は残し、独立した文の後続発話は保持する。
    public static func whisperSanitized(_ input: String) -> String {
        var value = sanitized(input)
        let removableAfter = CharacterSet.whitespacesAndNewlines.union(sentenceBoundaries)
        var searchStart = value.startIndex

        while searchStart < value.endIndex,
              let range = value.range(of: whisperBoilerplate, range: searchStart..<value.endIndex) {
            let preceding = value[..<range.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let startsSentence = preceding.isEmpty
                || preceding.unicodeScalars.last.map(sentenceBoundaries.contains) == true

            let following = value[range.upperBound...]
                .drop(while: { $0.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains) })
            let endsSentence = following.isEmpty
                || following.first?.unicodeScalars.allSatisfy(sentenceBoundaries.contains) == true

            guard startsSentence, endsSentence else {
                searchStart = range.upperBound
                continue
            }

            var removalEnd = range.upperBound
            while removalEnd < value.endIndex,
                  value[removalEnd].unicodeScalars.allSatisfy(removableAfter.contains) {
                removalEnd = value.index(after: removalEnd)
            }
            value.removeSubrange(range.lowerBound..<removalEnd)
            searchStart = range.lowerBound
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
