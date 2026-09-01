import Foundation

/// Koe の表示言語。Life Logが明示的に「表示言語に合わせる」を選んだ場合だけSTT hintにも使う。
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

enum KoeLocalization {
    static func string(
        _ key: String,
        language: ApplicationLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        let english = bundle(identifier: "en").localizedString(forKey: key, value: key, table: nil)
        return bundle(identifier: language.resolvedIdentifier(preferredLanguages: preferredLanguages))
            .localizedString(forKey: key, value: english, table: nil)
    }

    private static func bundle(identifier: String) -> Bundle {
        guard let path = Bundle.module.path(forResource: identifier.lowercased(), ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .module
        }
        return bundle
    }
}
