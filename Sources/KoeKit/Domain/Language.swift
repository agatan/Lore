import Foundation

/// STT が判定した発話言語。
public enum RecognizedLanguage: String, Codable, Sendable, CaseIterable {
    case ja
    case en
    case mixed
    case unknown

    public var displayName: String {
        switch self {
        case .ja: "日本語"
        case .en: "英語"
        case .mixed: "日英混在"
        case .unknown: "不明"
        }
    }
}

/// モード・セッション単位の言語方針。`auto` はエンジンの判定に委ねる。
public enum LanguagePreference: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto
    case ja
    case en

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: "自動判定"
        case .ja: "日本語に固定"
        case .en: "英語に固定"
        }
    }

    /// 固定指定のときだけロケールを返す。`auto` は呼び出し側の既定に従う。
    public var fixedLocale: Locale? {
        switch self {
        case .auto: nil
        case .ja: Locale(identifier: "ja-JP")
        case .en: Locale(identifier: "en-US")
        }
    }
}
