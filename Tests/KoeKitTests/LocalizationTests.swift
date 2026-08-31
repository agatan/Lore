import Foundation
import Testing

@testable import KoeKit

@Suite("表示言語")
struct LocalizationTests {
    @Test("明示選択は対応localeへ解決する", arguments: [
        (ApplicationLanguage.english, "en"),
        (.japanese, "ja"),
        (.simplifiedChinese, "zh-Hans"),
    ])
    func explicitSelection(language: ApplicationLanguage, expected: String) {
        #expect(language.resolvedIdentifier(preferredLanguages: ["fr-FR"]) == expected)
    }

    @Test("システム設定は最初の対応言語を使う")
    func systemPreferenceOrder() {
        #expect(ApplicationLanguage.system.resolvedIdentifier(
            preferredLanguages: ["fr-FR", "zh-Hans-CN", "ja-JP"]
        ) == "zh-Hans")
    }

    @Test("未対応言語と繁体字中国語は英語へfallbackする", arguments: [
        ["fr-FR"],
        ["zh-Hant-TW"],
        [],
    ])
    func englishFallback(preferredLanguages: [String]) {
        #expect(ApplicationLanguage.system.resolvedIdentifier(preferredLanguages: preferredLanguages) == "en")
    }

    @Test("代表文言を三言語から取得できる")
    func localizedResources() {
        #expect(KoeLocalization.string("表示言語", language: .english) == "Display Language")
        #expect(KoeLocalization.string("表示言語", language: .japanese) == "表示言語")
        #expect(KoeLocalization.string("表示言語", language: .simplifiedChinese) == "显示语言")
    }

    @Test("欠けた翻訳は英語へfallbackする")
    func missingTranslationFallsBackToEnglish() {
        #expect(KoeLocalization.string("missing-key", language: .simplifiedChinese) == "missing-key")
    }

    @MainActor
    @Test("既存設定はシステム設定で補完する")
    func missingSettingUsesSystem() throws {
        let defaults = try #require(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defaults.set(try JSONEncoder().encode(AppSettings.Storage()), forKey: AppSettings.defaultsKey)

        #expect(AppSettings(defaults: defaults).applicationLanguage == .system)
    }

    @MainActor
    @Test("未知の言語値でも他の設定を保持する")
    func unknownLanguagePreservesSettings() throws {
        let defaults = try #require(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AppSettings.Storage())
        ) as? [String: Any])
        object["applicationLanguage"] = "fr"
        object["soundsEnabled"] = false
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: AppSettings.defaultsKey)

        let settings = AppSettings(defaults: defaults)
        #expect(settings.applicationLanguage == .system)
        #expect(!settings.soundsEnabled)
    }
}
