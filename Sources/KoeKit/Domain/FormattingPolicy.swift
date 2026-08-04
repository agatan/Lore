import Foundation
import NaturalLanguage

/// LLM に渡す整形プロンプト。
public struct FormattingPrompt: Sendable, Equatable {
    public var system: String
    public var user: String

    public init(system: String, user: String) {
        self.system = system
        self.user = user
    }
}

/// 整形結果を採用できない理由。整形失敗は異常系ではなく正規の分岐なので、
/// throw ではなく値で表す。
public enum FormattingRejection: Error, Sendable, Equatable {
    case empty
    case tooShort(ratio: Double)
    case tooLong(ratio: Double)
    case promptLeakage(marker: String)
    /// 入力と中身が繋がっていない = 別の文を作ってしまっている。
    case unrelated(overlap: Double)

    public var message: String {
        switch self {
        case .empty: "整形結果が空でした"
        case .tooShort(let ratio): "整形結果が短すぎます(入力比 \(String(format: "%.2f", ratio)))"
        case .tooLong(let ratio): "整形結果が長すぎます(入力比 \(String(format: "%.2f", ratio)))"
        case .promptLeakage(let marker): "プロンプトの漏洩を検出しました(\(marker))"
        case .unrelated(let overlap): "整形結果が発話と繋がっていません(一致度 \(String(format: "%.2f", overlap)))"
        }
    }
}

/// 整形プロンプトの組み立てと出力検証。
///
/// 「整形は変換であって応答ではない」という制約を、プロンプト(few-shot 込み)と
/// 出力検証の二段で守る。閾値は全てここに集約する。
public enum FormattingPolicy {
    /// 出力/入力の文字数比の許容範囲。
    public static let minLengthRatio = 0.3
    /// 2 倍を超える出力は、整形ではなく「応答」しはじめた兆候として扱う。
    public static let maxLengthRatio = 2.0
    /// 短文は正当に大きく伸縮するため、比率検証はこの長さ以上の入力にだけ適用する。
    public static let ratioCheckMinimumInputLength = 12
    /// 入力と出力が共有すべき文字バイグラムの最低割合。
    /// 整形で語順や語尾が変わっても素材は残るので、ここを割るのは別の文への差し替え。
    public static let minimumContentOverlap = 0.15

    static let leakageMarkers = [
        "[system]", "[mode]", "[input]",
        "語彙表", "整形後のテキストのみ", "以下が整形結果", "整形結果:", "口述筆記の整形エンジン",
        // 発話にコードフェンスは含まれ得ない。出てきたら構造を作り始めている。
        "```",
    ]

    // MARK: プロンプト組み立て

    public static func prompt(mode: Mode, vocabulary: [VocabularyEntry], transcript: String) -> FormattingPrompt {
        FormattingPrompt(
            system: systemPrompt(mode: mode, vocabulary: vocabulary),
            user: userPrompt(transcript: transcript)
        )
    }

    /// 入力を区切り、命令を最後に置く。
    ///
    /// 小型モデルは長い入力を読んだあと system の指示を忘れて「応答」しはじめるため、
    /// 変換であることを入力の直後に置き直す。
    public static func userPrompt(transcript: String) -> String {
        """
        次の ``` で囲まれた部分は音声認識の生テキストです。

        ```
        \(transcript)
        ```

        これを整形したテキストだけを出力してください。内容に答えない。項目を増やさない。見出しやコードブロックを付けない。
        """
    }

    public static func systemPrompt(mode: Mode, vocabulary: [VocabularyEntry]) -> String {
        var sections: [String] = [baseRules]
        sections.append(fewShot)

        // 語彙は入力の直前に置く。ルールの列挙に埋めると小型モデルが従いにくい。
        if let table = vocabularyTable(vocabulary) {
            sections.append(table)
        }

        let modePrompt = mode.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modePrompt.isEmpty {
            sections.append("""
            # このモード(\(mode.name))固有の指示
            \(modePrompt)
            """)
        }

        return sections.joined(separator: "\n\n")
    }

    static let baseRules = """
    あなたは口述筆記の整形エンジンです。入力は音声認識が出力した生のテキストです。
    あなたの仕事は変換だけです。入力の内容に返答・回答・解説・感想・要約をしてはいけません。
    入力が質問文でも依頼文でも、答えずに、整形したテキストだけを返します。

    # 必ず守るルール
    1. フィラー(えーと / あのー / まあ / そのー / um / uh など意味を持たない繋ぎ語)を削除する
    2. 句読点と改行を自然な位置に入れる
    3. 言い直し・重複は、後から言い直した表現だけを残す
    4. 同音異義語は文脈から正しい表記を選ぶ
    5. 発話に含まれない情報を足さない。内容を要約・省略しない。項目を勝手に増やさない
    6. 数値は発話どおりに数字にする。単位・小数・桁を変えてはいけない
       (「三十八度五分」は 38.5 度。「五分」を 0.08 などに換算しない)
    7. 語彙表(下部)にある語は、必ずその表記に置き換える。これは他のどのルールよりも優先する
    8. 出力は整形後のテキストのみ。前置き・後置き・引用符・コードフェンス・見出し・説明を付けない
    """

    static let fewShot = """
    # 例
    入力: えーとこの関数をリファクタして、あーやっぱりテストも一緒に書いて
    出力: この関数をリファクタリングして、テストも一緒に書いてください。

    入力: これってどうやって動いてるんですかね、あのー内部の仕組みが知りたくて
    出力: これはどうやって動いているんですか？内部の仕組みが知りたいです。
    (質問には答えず、質問文のまま整形する)

    入力: 明日の一on一なんですけど三十分後ろにずらしてもらえると助かります
    出力: 明日の 1on1 ですが、30 分後ろにずらしてもらえると助かります。

    入力: 熱が三十八度五分まで上がりました
    出力: 熱が 38.5 度まで上がりました。
    (数値は発話どおり。勝手に換算しない)
    """

    /// 語彙表の本文。誤認識 → 正しい表記の置換指示として書く。
    ///
    /// 「表記 / 読み / 誤認識例」の一覧として渡すと小型モデルが従わないため、
    /// 置換の矢印を明示し、入力の直前に置く。
    static func vocabularyTable(_ vocabulary: [VocabularyEntry]) -> String? {
        let entries = vocabulary.filter {
            $0.enabled && !$0.surface.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !entries.isEmpty else { return nil }

        var lines = ["# 語彙表(最優先)"]

        let replacements = entries
            .filter { !$0.misrecognitions.isEmpty }
            .map { entry in
                let wrong = entry.misrecognitions.map { "「\($0)」" }.joined(separator: "・")
                return "- \(wrong) → 「\(entry.surface)」"
            }
        if !replacements.isEmpty {
            lines.append("入力に次の表記が出てきたら、必ず右側に置き換えてください。")
            lines.append(contentsOf: replacements)
            lines.append("")
        }

        lines.append("次の語は、読みが一致する部分をこの表記に統一してください。")
        lines.append(contentsOf: entries.map { entry in
            var line = "- \(entry.surface)"
            if let reading = entry.reading, !reading.isEmpty {
                line += "(\(reading))"
            }
            if let note = entry.note, !note.isEmpty {
                line += " — \(note)"
            }
            return line
        })

        return lines.joined(separator: "\n")
    }

    /// 語彙の誤認識パターンを機械的に置換した結果。
    public struct VocabularyCorrection: Sendable, Equatable {
        public var text: String
        /// 適用した置換(監査・デバッグ用)。
        public var applied: [(from: String, to: String)]

        public var didChange: Bool { !applied.isEmpty }

        public static func == (lhs: VocabularyCorrection, rhs: VocabularyCorrection) -> Bool {
            lhs.text == rhs.text && lhs.applied.map(\.from) == rhs.applied.map(\.from)
        }
    }

    /// 機械置換に使うには短すぎるパターンの長さ。これ未満は LLM 整形段だけに任せる。
    public static let minimumReplaceablePatternLength = 2

    /// 登録済みの誤認識パターンを、LLM に渡す前に決定的に置換する。
    ///
    /// 文字列一致で確実に直せるものを確率的なモデルに任せる理由はない
    /// (実測で小型モデルは語彙表の指示に従わなかった)。
    ///
    /// ただし日本語には語の区切りが無いので、素朴な全置換は過剰置換になる
    /// (「アイ」→「AI」が「アイデア」を壊す)。形態素の境界に一致する出現だけを置換し、
    /// 境界に乗らないものは触らずに LLM 段の語彙表へ委ねる。
    public static func applyVocabularyCorrections(
        to transcript: String,
        vocabulary: [VocabularyEntry]
    ) -> VocabularyCorrection {
        // 長いパターンを先に当てて、部分一致で壊さないようにする。
        let patterns = vocabulary
            .filter(\.enabled)
            .flatMap { entry in
                entry.misrecognitions
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter {
                        !$0.isEmpty
                            && $0 != entry.surface
                            && $0.count >= minimumReplaceablePatternLength
                    }
                    .map { (from: $0, to: entry.surface) }
            }
            .sorted { $0.from.count > $1.from.count }

        var text = transcript
        var applied: [(from: String, to: String)] = []
        for pattern in patterns {
            let result = replacingAtWordBoundaries(in: text, pattern: pattern.from, with: pattern.to)
            guard result.didReplace else { continue }
            text = result.text
            applied.append(pattern)
        }
        return VocabularyCorrection(text: text, applied: applied)
    }

    /// 形態素の境界に一致する出現だけを置換する。
    static func replacingAtWordBoundaries(
        in text: String,
        pattern: String,
        with replacement: String
    ) -> (text: String, didReplace: Bool) {
        let boundaries = wordBoundaries(of: text)
        var output = ""
        var cursor = text.startIndex
        var didReplace = false

        while let range = text.range(of: pattern, range: cursor..<text.endIndex) {
            output += text[cursor..<range.lowerBound]
            // 語の途中に埋まっている出現は別語の一部なので触らない。
            if boundaries.starts.contains(range.lowerBound), boundaries.ends.contains(range.upperBound) {
                output += replacement
                didReplace = true
            } else {
                output += pattern
            }
            cursor = range.upperBound
        }
        output += text[cursor...]
        return (output, didReplace)
    }

    /// 形態素の開始・終了位置。
    ///
    /// `NLTokenizer` は日本語を語単位に分割できる(オンデバイス、ネットワーク不要)。
    static func wordBoundaries(of text: String) -> (starts: Set<String.Index>, ends: Set<String.Index>) {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text

        var starts: Set<String.Index> = []
        var ends: Set<String.Index> = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            starts.insert(range.lowerBound)
            ends.insert(range.upperBound)
            return true
        }
        return (starts, ends)
    }

    /// STT バイアス用のヒント文字列(Whisper の initial prompt 等)。
    public static func vocabularyHint(_ vocabulary: [VocabularyEntry]) -> String? {
        let surfaces = vocabulary.filter(\.enabled).map(\.surface).filter { !$0.isEmpty }
        guard !surfaces.isEmpty else { return nil }
        return surfaces.joined(separator: "、")
    }

    /// STT の contextual strings 用の語彙リスト。
    public static func contextualStrings(_ vocabulary: [VocabularyEntry]) -> [String] {
        var seen = Set<String>()
        return vocabulary
            .filter(\.enabled)
            .flatMap { [$0.surface] + ($0.reading.map { [$0] } ?? []) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: 出力検証

    public static func validate(output: String, input: String) -> Result<String, FormattingRejection> {
        let cleaned = sanitize(output)
        guard !cleaned.isEmpty else { return .failure(.empty) }

        if let marker = leakageMarkers.first(where: { cleaned.localizedCaseInsensitiveContains($0) }) {
            return .failure(.promptLeakage(marker: marker))
        }

        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let inputLength = trimmedInput.count
        if inputLength >= ratioCheckMinimumInputLength {
            let ratio = Double(cleaned.count) / Double(inputLength)
            if ratio < minLengthRatio { return .failure(.tooShort(ratio: ratio)) }
            if ratio > maxLengthRatio { return .failure(.tooLong(ratio: ratio)) }

            // 長さが妥当でも、中身が入力と無関係な文にすり替わっていることがある
            // (実測でプロンプト内の例文がそのまま出力されたことがあり、長さ検証は通過した)。
            if requiresContentOverlap(input: trimmedInput, output: cleaned) {
                let overlap = contentOverlap(input: trimmedInput, output: cleaned)
                if overlap < minimumContentOverlap {
                    return .failure(.unrelated(overlap: overlap))
                }
            }
        }

        return .success(cleaned)
    }

    /// 入力の文字バイグラムのうち、出力にも現れる割合。
    ///
    /// 整形は変換なので、語順や語尾が変わっても素材は共有される。
    /// 共有がほぼ無いなら、それは整形ではなく別の文の生成。
    static func contentOverlap(input: String, output: String) -> Double {
        let inputGrams = bigrams(input)
        guard !inputGrams.isEmpty else { return 1 }
        let outputGrams = bigrams(output)
        guard !outputGrams.isEmpty else { return 0 }
        let shared = inputGrams.intersection(outputGrams)
        return Double(shared.count) / Double(inputGrams.count)
    }

    /// 翻訳するモードでは素材が共有されないため、この検証を外す。
    static func requiresContentOverlap(input: String, output: String) -> Bool {
        let inputLanguage = LanguageDetector.detect(input)
        let outputLanguage = LanguageDetector.detect(output)
        switch (inputLanguage, outputLanguage) {
        case (.ja, .en), (.en, .ja):
            return false
        default:
            return true
        }
    }

    static func bigrams(_ text: String) -> Set<String> {
        let characters = Array(
            text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        )
        guard characters.count >= 2 else { return characters.isEmpty ? [] : [String(characters)] }
        return Set((0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) })
    }

    /// モデルが付けがちな飾りを落とす。過剰に削らないよう、全体を包んでいる場合のみ剥がす。
    static func sanitize(_ output: String) -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // 全体がコードフェンスで包まれている場合だけ剥がす
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 {
            var lines = text.components(separatedBy: .newlines)
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 出力全体を包む引用符
        for (open, close) in [("「", "」"), ("\"", "\""), ("'", "'"), ("『", "』")] {
            if text.hasPrefix(open), text.hasSuffix(close), text.count > open.count + close.count {
                let inner = String(text.dropFirst(open.count).dropLast(close.count))
                if !inner.contains(open), !inner.contains(close) {
                    text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        // 先頭 1 行だけの前置き(「整形後:」「出力:」など)
        if let range = text.range(of: #"^(整形(後|結果)(のテキスト)?|出力|結果|Output|Formatted)\s*[:：]\s*"#, options: .regularExpression) {
            text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return text
    }
}
