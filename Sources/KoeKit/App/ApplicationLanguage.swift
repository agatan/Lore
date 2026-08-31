import Foundation

/// Koe の表示だけに適用する言語。音声認識や保存済みデータの言語とは独立している。
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
