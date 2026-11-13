import Foundation

/// whisper.cppへ渡す音声と語彙promptの境界判断。
///
/// Whisperは無音や語彙promptだけの入力から、それらしい文やpromptの写しを作ることがある。
/// 認識engineはここで決めた範囲だけを渡し、promptの写しだけのsegmentを捨てる。
public enum WhisperInputPolicy {
    /// 有声判定の窓。16 kHzで30 ms。
    static let frameDuration: TimeInterval = 0.03
    /// 検出した有声区間の前後に残す余白。子音の立ち上がりと語尾を削らない。
    public static let edgeMargin: TimeInterval = 0.5
    /// 語彙promptのtoken上限。whisper.cppはtext context 448の半分を超えたpromptの先頭を捨てるため、
    /// 余裕を持って収め、先頭の語(利用者が並べた順)を優先する。
    public static let maximumPromptTokens = 200
    static let promptSeparator: Character = "、"

    /// 前後の無音を除いた認識範囲。有声frameが無い場合は判定を誤った可能性があるため全体を返す。
    public static func speechSpan(
        of samples: [Float],
        sampleRate: Double,
        minimumLevel: Float = AdaptiveSpeechSegmenter.minimumSpeechLevel
    ) -> Range<Int> {
        let frameLength = max(1, Int(sampleRate * frameDuration))
        var first: Int?
        var last: Int?
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + frameLength)
            var sum: Float = 0
            for index in start..<end { sum += samples[index] * samples[index] }
            if (sum / Float(end - start)).squareRoot() >= minimumLevel {
                if first == nil { first = start }
                last = end
            }
            start = end
        }
        guard let first, let last else { return 0..<samples.count }
        let margin = Int(sampleRate * edgeMargin)
        return max(0, first - margin)..<min(samples.count, last + margin)
    }

    /// 並び順を保ったまま、token上限に収まる語だけを残したprompt。
    public static func fittedPrompt(_ prompt: String?, fits: (String) -> Bool) -> String? {
        var accepted: [Substring] = []
        for term in terms(of: prompt) {
            let candidate = (accepted + [term]).joined(separator: String(promptSeparator))
            guard fits(candidate) else { break }
            accepted.append(term)
        }
        return accepted.isEmpty ? nil : accepted.joined(separator: String(promptSeparator))
    }

    /// 2語以上の語彙promptを、発話ではなくそのまま読み上げただけのsegmentか。
    /// 1語だけなら、その語を口述した結果と区別できないため残す。
    public static func isPromptEcho(_ text: String, prompt: String?) -> Bool {
        let terms = terms(of: prompt)
        guard terms.count >= 2 else { return false }
        let spoken = normalized(text)
        return !spoken.isEmpty && spoken == normalized(terms.joined())
    }

    private static func terms(of prompt: String?) -> [Substring] {
        (prompt ?? "")
            .split(separator: promptSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines)[...] }
            .filter { !$0.isEmpty }
    }

    private static func normalized(_ text: String) -> String {
        let ignored = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter { !ignored.contains($0) }))
    }
}
