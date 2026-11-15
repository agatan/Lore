import Foundation
import Testing
@testable import LoreKit

@MainActor
@Suite("カラーテーマ設定")
struct ColorThemeSettingsTests {
    @Test("選んだ配色は再起動後も残る")
    func choicePersists() throws {
        let defaults = try #require(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        AppSettings(defaults: defaults).colorTheme = .dark

        #expect(AppSettings(defaults: defaults).colorTheme == .dark)
    }

    @Test("項目のない既存設定はシステム設定で補完する")
    func missingFieldUsesSystem() throws {
        let defaults = try #require(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AppSettings.Storage())
        ) as? [String: Any])
        object.removeValue(forKey: "colorTheme")
        object["soundsEnabled"] = false
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: AppSettings.defaultsKey)

        let settings = AppSettings(defaults: defaults)
        #expect(settings.colorTheme == .system)
        #expect(!settings.soundsEnabled)
    }

    @Test("未知の配色値でも他の設定を保持する")
    func unknownValuePreservesSettings() throws {
        let defaults = try #require(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AppSettings.Storage())
        ) as? [String: Any])
        object["colorTheme"] = "sepia"
        object["soundsEnabled"] = false
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: AppSettings.defaultsKey)

        let settings = AppSettings(defaults: defaults)
        #expect(settings.colorTheme == .system)
        #expect(!settings.soundsEnabled)
    }
}
