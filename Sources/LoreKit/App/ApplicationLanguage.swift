import Foundation
import Synchronization

/// Lore の表示言語。Life Logが明示的に「表示言語に合わせる」を選んだ場合だけSTT hintにも使う。
public enum ApplicationLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: "システム設定"
        case .english: "English"
        case .japanese: "日本語"
        case .simplifiedChinese: "简体中文"
        }
    }

    public func resolvedIdentifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .english, .japanese, .simplifiedChinese:
            rawValue
        case .system:
            preferredLanguages.lazy.compactMap(Self.supportedIdentifier(for:)).first ?? "en"
        }
    }

    public func resolvedLocale(preferredLanguages: [String] = Locale.preferredLanguages) -> Locale {
        Locale(identifier: resolvedIdentifier(preferredLanguages: preferredLanguages))
    }

    private static func supportedIdentifier(for identifier: String) -> String? {
        let language = Locale.Language(identifier: identifier)
        switch language.languageCode?.identifier {
        case "en": return "en"
        case "ja": return "ja"
        case "zh" where language.script?.identifier == "Hans": return "zh-Hans"
        default: return nil
        }
    }
}

public enum LifeLogTranscriptionLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case applicationLanguage
    case auto
    case japanese
    case english
    case simplifiedChinese

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .applicationLanguage: "表示言語に合わせる"
        case .auto: "自動判定"
        case .japanese: "日本語"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    public func preference(applicationLanguage: ApplicationLanguage) -> LanguagePreference {
        switch self {
        case .auto: .auto
        case .japanese: .ja
        case .english: .en
        case .simplifiedChinese: .zhHans
        case .applicationLanguage:
            switch applicationLanguage.resolvedIdentifier() {
            case "ja": .ja
            case "zh-Hans": .zhHans
            default: .en
            }
        }
    }
}

/// SwiftUIの外で組み立てる利用者向け文言(エラー、状態表示)の翻訳。
///
/// Viewは注入された`Locale`で翻訳されるが、coordinatorやengineが作る文字列には届かない。
/// `AppEnvironment`が設定の表示言語をここへ写し、`String(lore:)`はそれに従って引く。
enum LoreLocalization {
    private static let selectedLanguage = Mutex(ApplicationLanguage.system)

    static var language: ApplicationLanguage {
        get { selectedLanguage.withLock { $0 } }
        set { selectedLanguage.withLock { $0 = newValue } }
    }

    static func string(
        _ value: String.LocalizationValue,
        language: ApplicationLanguage = language,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        // 欠けたkeyはbundleの開発言語(英語)へfallbackする。
        var resource = LocalizedStringResource(value, bundle: .atURL(Bundle.module.bundleURL))
        resource.locale = language.resolvedLocale(preferredLanguages: preferredLanguages)
        return String(localized: resource)
    }
}

extension LoreLocalization {
    /// 日付や曜日の表記に使うlocale。表示言語だけを替え、地域の暦（週の始まりなど）はmacOSに従う。
    static var locale: Locale {
        language.resolvedLocale(preferredLanguages: Locale.preferredLanguages)
    }

    /// 表示言語の名前で曜日や月を書き、週の始まりはmacOSの地域設定のままにした暦。
    static var calendar: Calendar {
        var calendar = Calendar.current
        let firstWeekday = calendar.firstWeekday
        calendar.locale = locale
        calendar.firstWeekday = firstWeekday
        return calendar
    }
}

extension Date {
    /// 日付と時刻を、macOSの言語ではなくLoreの表示言語で書く。
    func loreFormatted(_ style: Date.FormatStyle) -> String {
        formatted(style.locale(LoreLocalization.locale))
    }

    func loreFormatted(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time).locale(LoreLocalization.locale))
    }
}

extension String {
    /// LoreKitの文字列表から、設定の表示言語で引く。
    init(lore value: String.LocalizationValue) {
        self = LoreLocalization.string(value)
    }
}
