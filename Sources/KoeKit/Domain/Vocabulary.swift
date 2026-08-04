import Foundation

/// カスタム語彙の 1 エントリ。
///
/// **語彙はモデルへのヒントであって、置換規則ではない**(設計 D-6 / C-43)。
/// 使い道は 2 つだけ: STT のバイアス(contextualStrings / initial prompt)と、
/// LLM 整形段に渡す語彙表。Koe 自身が文字列を書き換えることはしない。
public struct VocabularyEntry: Identifiable, Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable {
        case manual
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

/// 履歴分析から生まれた辞書候補。承認されるまで辞書には入らない(設計 D-9)。
public struct VocabularySuggestion: Identifiable, Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable {
        case pending
        case accepted
        case rejected
    }

    /// 候補の検出根拠の種類。
    public enum Kind: String, Codable, Sendable {
        /// 未登録の固有名詞・専門用語が頻出している
        case frequentTerm
        /// raw → formatted で繰り返し矯正されている(誤認識の疑い)
        case repeatedCorrection
        /// 同一概念に複数の表記が混在している
        case inconsistentSpelling

        public var displayName: String {
            switch self {
            case .frequentTerm: "頻出用語"
            case .repeatedCorrection: "誤認識の矯正"
            case .inconsistentSpelling: "表記ゆれ"
            }
        }
    }

    /// 根拠。履歴を消しても提案の説明が壊れないよう、抜粋は独立コピーで持つ。
    public struct Evidence: Codable, Sendable, Hashable {
        public struct Example: Codable, Sendable, Hashable {
            public var sessionID: String?
            public var excerpt: String

            public init(sessionID: String?, excerpt: String) {
                self.sessionID = sessionID
                self.excerpt = excerpt
            }
        }

        public var kind: Kind
        public var count: Int
        public var examples: [Example]
        /// 誤認識候補として観測された表記。
        public var misrecognitions: [String]
        public var reading: String?

        public init(
            kind: Kind,
            count: Int,
            examples: [Example] = [],
            misrecognitions: [String] = [],
            reading: String? = nil
        ) {
            self.kind = kind
            self.count = count
            self.examples = examples
            self.misrecognitions = misrecognitions
            self.reading = reading
        }
    }

    public var id: String
    public var surface: String
    public var evidence: Evidence
    public var status: Status
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        surface: String,
        evidence: Evidence,
        status: Status = .pending,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.surface = surface
        self.evidence = evidence
        self.status = status
        self.createdAt = createdAt
    }

    /// 承認時に辞書エントリへ昇格する。
    public func promoted() -> VocabularyEntry {
        VocabularyEntry(
            surface: surface,
            reading: evidence.reading,
            misrecognitions: evidence.misrecognitions,
            source: .suggested
        )
    }
}
