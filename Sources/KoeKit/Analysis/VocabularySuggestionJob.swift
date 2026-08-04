import Foundation

/// 履歴をローカル LLM で分析して辞書候補を提案する(FR-6.4)。
///
/// 割り切り: 候補の**発見**は確率的(LLM)でよい。ただし提示する**根拠は決定的**に作る
/// (出現回数と抜粋は実データから数え直す)。登録は必ず人間の承認を経る(設計 D-9)。
public struct VocabularySuggestionJob: Sendable {
    public struct Result: Sendable, Equatable {
        public var inspectedSessions: Int
        public var proposed: Int
        public var created: Int
        public var skippedReason: String?

        public static let notEnoughData = Result(
            inspectedSessions: 0, proposed: 0, created: 0, skippedReason: "分析できる履歴がまだありません"
        )
    }

    /// 分析対象にする最小セッション数。
    static let minimumSessions = 5
    /// 1 回の分析でモデルに渡す最大セッション数。
    static let maxSessions = 60
    /// 1 セッションあたりの抜粋長。
    static let excerptLimit = 400
    static let maxCandidates = 8
    static let watermarkKey = "vocab_analysis_watermark"

    private let history: HistoryStore
    private let vocabulary: VocabularyStore
    private let meta: MetaStore
    private let llm: any LlmEngine
    private let timeout: Duration

    public init(
        history: HistoryStore,
        vocabulary: VocabularyStore,
        meta: MetaStore,
        llm: any LlmEngine,
        timeout: Duration = .seconds(90)
    ) {
        self.history = history
        self.vocabulary = vocabulary
        self.meta = meta
        self.llm = llm
        self.timeout = timeout
    }

    public func run(force: Bool = false) async throws -> Result {
        let since = force ? nil : try await meta.date(forKey: Self.watermarkKey)
        let sessions = try await history.sessions(since: since, limit: Self.maxSessions)
            .filter { !$0.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard sessions.count >= Self.minimumSessions else {
            return .notEnoughData
        }

        let known = try await vocabulary.knownSurfaces()
        let corpus = sessions.map { session in
            (
                id: session.id,
                raw: String(session.rawTranscript.prefix(Self.excerptLimit)),
                formatted: session.formattedText.map { String($0.prefix(Self.excerptLimit)) }
            )
        }

        let output = try await llm.complete(
            prompt: FormattingPrompt(system: Self.systemPrompt, user: Self.userPrompt(corpus: corpus, known: known)),
            timeout: timeout
        )

        let candidates = Self.parse(output)
        let suggestions = candidates.compactMap { candidate in
            evidence(for: candidate, in: sessions).map { evidence in
                VocabularySuggestion(surface: candidate.surface, evidence: evidence)
            }
        }

        let created = try await vocabulary.insertSuggestions(suggestions)
        if let latest = sessions.map(\.startedAt).max() {
            try await meta.setDate(latest, forKey: Self.watermarkKey)
        }

        return Result(
            inspectedSessions: sessions.count,
            proposed: candidates.count,
            created: created,
            skippedReason: nil
        )
    }

    /// LLM が挙げた語について、実データから出現回数と抜粋を数え直す。
    /// 1 回も出てこない語(幻覚)はここで落ちる。
    private func evidence(for candidate: Candidate, in sessions: [SessionRecord]) -> VocabularySuggestion.Evidence? {
        let surface = candidate.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard surface.count >= 2, surface.count <= 40 else { return nil }

        var count = 0
        var examples: [VocabularySuggestion.Evidence.Example] = []

        for session in sessions {
            let haystacks = [session.rawTranscript, session.formattedText].compactMap { $0 }
            var matchedInSession = false
            for text in haystacks {
                let occurrences = text.components(separatedBy: surface).count - 1
                if occurrences > 0 {
                    count += occurrences
                    matchedInSession = true
                }
            }
            if matchedInSession, examples.count < 3,
               let excerpt = Self.excerpt(around: surface, in: session.formattedText ?? session.rawTranscript) {
                examples.append(.init(sessionID: session.id, excerpt: excerpt))
            }
        }

        // 誤認識パターンは raw 側にだけ現れるものを候補として残す。
        let misrecognitions = candidate.misrecognitions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != surface }
            .filter { pattern in sessions.contains { $0.rawTranscript.contains(pattern) } }

        guard count > 0 || !misrecognitions.isEmpty else { return nil }

        return VocabularySuggestion.Evidence(
            kind: candidate.kind,
            count: max(count, misrecognitions.isEmpty ? 1 : misrecognitions.count),
            examples: examples,
            misrecognitions: Array(Set(misrecognitions)).sorted(),
            reading: candidate.reading?.isEmpty == false ? candidate.reading : nil
        )
    }

    static func excerpt(around surface: String, in text: String, radius: Int = 24) -> String? {
        guard let range = text.range(of: surface) else { return text.isEmpty ? nil : String(text.prefix(60)) }
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var excerpt = String(text[start..<end])
        if start != text.startIndex { excerpt = "…" + excerpt }
        if end != text.endIndex { excerpt += "…" }
        return excerpt
    }

    // MARK: プロンプトと解析

    struct Candidate: Sendable {
        var surface: String
        var kind: VocabularySuggestion.Kind
        var reading: String?
        var misrecognitions: [String]
    }

    static let systemPrompt = """
    あなたは音声入力の履歴を分析して、ユーザー辞書に登録すべき語の候補を挙げるアシスタントです。
    与えられるのは「生の文字起こし(raw)」と「整形後(formatted)」のペアです。

    次の 3 種類の候補を探してください。
    - frequent_term: 繰り返し出てくる固有名詞・製品名・専門用語
    - repeated_correction: raw から formatted で繰り返し直されている表記(誤認識の疑い)
    - inconsistent_spelling: 同じ概念に複数の表記が混ざっているもの

    次のものは挙げないでください。
    - 一般的な日常語・普通名詞・挨拶・定型句
    - 1 文字の語、数字だけの語
    - すでに登録済みとして提示された語

    出力は JSON 配列のみ。説明文・コードフェンス・前置きを付けないこと。
    各要素の形式:
    {"surface":"正しい表記","kind":"frequent_term|repeated_correction|inconsistent_spelling","reading":"よみ(不明なら空文字)","misrecognitions":["誤認識された表記"]}
    最大 \(maxCandidates) 件。該当が無ければ [] を返してください。
    """

    static func userPrompt(corpus: [(id: String, raw: String, formatted: String?)], known: Set<String>) -> String {
        var lines: [String] = []
        if !known.isEmpty {
            lines.append("登録済み(挙げないでください): " + known.sorted().prefix(200).joined(separator: "、"))
            lines.append("")
        }
        for (index, entry) in corpus.enumerated() {
            lines.append("## \(index + 1)")
            lines.append("raw: \(entry.raw)")
            if let formatted = entry.formatted, formatted != entry.raw {
                lines.append("formatted: \(formatted)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func parse(_ output: String) -> [Candidate] {
        guard let json = extractJSONArray(from: output) else { return [] }
        struct Raw: Decodable {
            var surface: String
            var kind: String?
            var reading: String?
            var misrecognitions: [String]?
        }
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([Raw].self, from: data)
        else { return [] }

        return decoded.prefix(maxCandidates).map { raw in
            Candidate(
                surface: raw.surface,
                kind: kind(from: raw.kind),
                reading: raw.reading,
                misrecognitions: raw.misrecognitions ?? []
            )
        }
    }

    static func kind(from raw: String?) -> VocabularySuggestion.Kind {
        switch raw {
        case "repeated_correction": .repeatedCorrection
        case "inconsistent_spelling": .inconsistentSpelling
        default: .frequentTerm
        }
    }

    /// モデルが前置きやコードフェンスを付けても拾えるようにする。
    static func extractJSONArray(from text: String) -> String? {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else {
            return nil
        }
        return String(text[start...end])
    }
}
