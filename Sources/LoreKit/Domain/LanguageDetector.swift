import Foundation

/// 文字種から発話言語を推定する。
///
/// SpeechAnalyzer は言語を報告しないため、判定は文字構成から行う(設計 §4.3)。
/// whisper.cpp のように自前で判定できるエンジンは、その結果をそのまま使う。
public enum LanguageDetector {
    /// 日英混在と見なす少数側の比率のしきい値。
    static let mixedThreshold = 0.15

    public static func detect(_ text: String, preference: LanguagePreference = .auto) -> RecognizedLanguage {
        if preference == .zhHans { return .zhHans }
        var japanese = 0
        var latin = 0

        for scalar in text.unicodeScalars {
            if isJapanese(scalar) {
                japanese += 1
            } else if CharacterSet.letters.contains(scalar), scalar.isASCII {
                latin += 1
            }
        }

        let total = japanese + latin
        guard total > 0 else {
            // 文字が無い(数字や記号だけ)ときは方針をそのまま返す。
            switch preference {
            case .ja: return .ja
            case .en: return .en
            case .zhHans: return .zhHans
            case .auto: return .unknown
            }
        }

        let minorityRatio = Double(min(japanese, latin)) / Double(total)
        if minorityRatio >= mixedThreshold { return .mixed }
        return japanese >= latin ? .ja : .en
    }

    static func isJapanese(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // ひらがな・カタカナ
             0x3400...0x4DBF,   // CJK 拡張A
             0x4E00...0x9FFF,   // CJK 統合漢字
             0xF900...0xFAFF,   // CJK 互換漢字
             0xFF66...0xFF9D:   // 半角カタカナ
            true
        default:
            false
        }
    }
}
