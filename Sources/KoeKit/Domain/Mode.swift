import Foundation

/// 整形の振る舞いを決める設定単位。
///
/// モード = 名前 + マッチャー(bundle ID) + 整形プロンプト + 任意のモデル指定。
/// アプリ固有の差異はすべてここに閉じ込め、パイプライン本体には分岐を作らない。
public struct Mode: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    /// マッチ対象の bundle ID パターン。`*` をワイルドカードとして使える。
    /// 空配列 = どのアプリにもマッチしないフォールバックモード。
    public var bundleIDs: [String]
    public var prompt: String
    /// nil = グローバル設定の LLM モデルに従う。
    public var llmModel: String?
    public var languagePreference: LanguagePreference
    public var sortOrder: Int
    public var isBuiltin: Bool
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        bundleIDs: [String] = [],
        prompt: String,
        llmModel: String? = nil,
        languagePreference: LanguagePreference = .auto,
        sortOrder: Int = 0,
        isBuiltin: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.bundleIDs = bundleIDs
        self.prompt = prompt
        self.llmModel = llmModel
        self.languagePreference = languagePreference
        self.sortOrder = sortOrder
        self.isBuiltin = isBuiltin
        self.updatedAt = updatedAt
    }

    /// マッチャーを持たない = 既定モード。
    public var isFallback: Bool { bundleIDs.isEmpty }
}

// MARK: - 解決

/// 前面アプリの bundle ID からモードを決める。
///
/// 優先順位: 手動固定 > 完全一致 > ワイルドカード一致(具体的なパターンが優先) > フォールバック。
public enum ModeResolver {
    public static func resolve(bundleID: String?, modes: [Mode], overrideID: Mode.ID? = nil) -> Mode? {
        guard !modes.isEmpty else { return nil }

        if let overrideID, let pinned = modes.first(where: { $0.id == overrideID }) {
            return pinned
        }

        if let bundleID {
            let candidates = modes.compactMap { mode -> (mode: Mode, score: Int)? in
                guard let score = mode.bundleIDs.compactMap({ matchScore(pattern: $0, bundleID: bundleID) }).max()
                else { return nil }
                return (mode, score)
            }
            if let best = candidates.max(by: { lhs, rhs in
                lhs.score == rhs.score ? lhs.mode.sortOrder > rhs.mode.sortOrder : lhs.score < rhs.score
            }) {
                return best.mode
            }
        }

        return fallback(in: modes)
    }

    public static func fallback(in modes: [Mode]) -> Mode? {
        modes.filter(\.isFallback).min { $0.sortOrder < $1.sortOrder }
            ?? modes.min { $0.sortOrder < $1.sortOrder }
    }

    /// マッチしたときの具体性スコア。完全一致を最優先し、次にワイルドカード以外の文字数で比べる。
    static func matchScore(pattern: String, bundleID: String) -> Int? {
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return nil }
        if pattern.caseInsensitiveCompare(bundleID) == .orderedSame {
            return Int.max
        }
        guard pattern.contains("*") else { return nil }
        guard wildcardMatches(pattern: pattern.lowercased(), text: bundleID.lowercased()) else { return nil }
        return pattern.replacingOccurrences(of: "*", with: "").count
    }

    /// `*` のみを解釈する軽量グロブ。正規表現は使わない(パターンは設定由来なので予測可能に保つ)。
    static func wildcardMatches(pattern: String, text: String) -> Bool {
        let segments = pattern.components(separatedBy: "*")
        var cursor = text.startIndex

        for (index, segment) in segments.enumerated() {
            if segment.isEmpty { continue }
            let isFirst = index == 0
            let isLast = index == segments.count - 1

            if isFirst {
                guard text[cursor...].hasPrefix(segment) else { return false }
                cursor = text.index(cursor, offsetBy: segment.count)
                continue
            }
            if isLast, !pattern.hasSuffix("*") {
                guard text[cursor...].hasSuffix(segment) else { return false }
                cursor = text.endIndex
                continue
            }
            guard let found = text[cursor...].range(of: segment) else { return false }
            cursor = found.upperBound
        }
        return true
    }
}
