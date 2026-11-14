import Foundation

/// カスタム語彙の 1 エントリ。
///
/// **語彙はモデルへのヒントであって、置換規則ではない**(設計 D-6 / C-43)。
/// 使い道は 2 つだけ: STT のバイアス(contextualStrings / initial prompt)と、
/// LLM 整形段に渡す語彙表。Lore 自身が文字列を書き換えることはしない。
public struct VocabularyEntry: Identifiable, Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable {
        case manual
        /// 廃止した履歴からの語彙候補で登録した語。既存のdataとして読むだけで、新しくは作らない。
        case suggested
    }

    public var id: String
    /// 正しい表記。
    public var surface: String
    public var reading: String?
    /// よくある誤認識パターン。整形プロンプトに「この表記が出たら surface に直す」として渡す。
    public var misrecognitions: [String]
    public var source: Source
    public var enabled: Bool
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        surface: String,
        reading: String? = nil,
        misrecognitions: [String] = [],
        source: Source = .manual,
        enabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.surface = surface
        self.reading = reading
        self.misrecognitions = misrecognitions
        self.source = source
        self.enabled = enabled
        self.createdAt = createdAt
    }
}
