import Foundation
import NaturalLanguage

/// LLMへ要求する出力の形。呼び出し側が意味contractを宣言し、provider adapterが
/// 対応する最も強い制約へ変換する。
public enum FormattingOutput: Sendable, Equatable {
    case text
    case json(StructuredOutputContract)
}

public struct StructuredOutputContract: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        public enum Value: Sendable, Equatable {
            case string
            case stringArray
        }

        public var name: String
        public var value: Value

        public init(_ name: String, _ value: Value) {
            self.name = name
            self.value = value
        }
    }

    public var name: String
    public var fields: [Field]

    public init(name: String, fields: [Field]) {
        self.name = name
        self.fields = fields
    }
}

/// LLM に渡すプロンプト。
public struct FormattingPrompt: Sendable, Equatable {
    public var system: String
    public var user: String
    /// 期待する出力の上限(文字数)。`nil` = 入力と同程度(整形)。
    ///
    /// 出力の規模を知っているのは呼び出し側だけなので、ここで明示する。
    /// エンジンはこれをトークン予算に翻訳する。整形は入力と同じ長さが返るが、
    /// 履歴分析は数十文字の JSON しか返らない。同じ見積もりを当てると、
    /// 分析側で応答用に確保した枠が入力を押し出して**コンテキスト超過で失敗する**。
    public var expectedOutputCharacters: Int?
    public var output: FormattingOutput

    public init(
        system: String,
        user: String,
        expectedOutputCharacters: Int? = nil,
        output: FormattingOutput = .text
    ) {
        self.system = system
        self.user = user
        self.expectedOutputCharacters = expectedOutputCharacters
        self.output = output
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

    public static func prompt(
        sharedRules: String = BuiltinSharedRules.text,
        mode: Mode,
        vocabulary: [VocabularyEntry],
        transcript: String
    ) -> FormattingPrompt {
        FormattingPrompt(
            system: systemPrompt(sharedRules: sharedRules, mode: mode, vocabulary: vocabulary),
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

    /// 共通ルール → 語彙表 → モード固有の指示 の順で組む。
    ///
    /// 共通ルールは編集できるので引数で受け取る(既定は同梱内容)。
    public static func systemPrompt(
        sharedRules: String = BuiltinSharedRules.text,
        mode: Mode,
        vocabulary: [VocabularyEntry]
    ) -> String {
        var sections: [String] = []
        let shared = sharedRules.trimmingCharacters(in: .whitespacesAndNewlines)
        if !shared.isEmpty { sections.append(shared) }

        // モードの指示はそのまま連ねる。見出しを被せても情報は増えず、
        // 「固有の指示」という枠だけが増えて読み手(モデル)の負荷になる。
        let modePrompt = mode.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modePrompt.isEmpty {
            sections.append(modePrompt)
        }

        // 語彙表は最後、入力のいちばん近くに置く。
        if let table = vocabularyTable(vocabulary) {
            sections.append(table)
        }

        return sections.joined(separator: "\n\n")
    }


    /// 語彙表の本文。
    ///
    /// **置換命令として書かない。** 同じ読みで表記が分かれる語は文脈で決まるので、
    /// 「必ず置き換える」は誤りになる(「維持」は正しい語でもある)。
    /// 渡すのは「この人が使う表記」と「聞き取りで化けやすい形」で、選ぶのはモデルの仕事。
    ///
    /// 判断の基準は見出しに 1 回だけ書く。語ごとに文章で説明すると、
    /// 同じ文が語数ぶん繰り返されて入力を無駄に食う。記法は `←` に寄せる。
    static func vocabularyTable(_ vocabulary: [VocabularyEntry]) -> String? {
        let entries = vocabulary.filter {
            $0.enabled && !$0.surface.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !entries.isEmpty else { return nil }

        var lines = ["# 語彙表"]
        lines.append("この人がよく使う表記。文脈に合うときだけこの表記を選ぶ。機械的に置き換えない。")
        if entries.contains(where: { !$0.misrecognitions.isEmpty }) {
            lines.append("← の右は誤認識されやすい形。")
        }
        lines.append("")

        lines.append(contentsOf: entries.map { entry in
            var line = "- \(entry.surface)"
            if let reading = entry.reading, !reading.isEmpty {
                line += "(\(reading))"
            }
            if !entry.misrecognitions.isEmpty {
                line += " ← " + entry.misrecognitions.map { "「\($0)」" }.joined()
            }
            return line
        })

        return lines.joined(separator: "\n")
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
