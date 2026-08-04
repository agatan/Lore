import Foundation

/// 履歴をローカル LLM で分析して辞書候補を提案する(FR-6.4)。
///
/// 割り切り: 候補の**発見**は確率的(LLM)でよい。ただし提示する**根拠は決定的**に作る
/// (出現回数と抜粋は実データから数え直す)。登録は必ず人間の承認を経る(設計 D-9)。
///
/// 履歴の量はユーザー次第で増え続ける一方、モデルのコンテキスト窓は有限なので、
/// **コーパスは必ずエンジンの入力予算に収まるバッチへ分割して**問い合わせる。
/// 1 回のプロンプトに全部詰めるとコンテキスト超過で分析が丸ごと失敗する(設計 C-36)。
public struct VocabularySuggestionJob: Sendable {
    public struct Result: Sendable, Equatable {
        /// 実際にモデルへ渡したセッション数。予算に収まらなかった分は次回に回る。
        public var inspectedSessions: Int
        public var proposed: Int
        public var created: Int
        /// 分割したバッチ数と、そのうち失敗した数。部分的な失敗を隠さないために持つ。
        public var batches: Int
        public var failedBatches: Int
        public var skippedReason: String?

        public init(
            inspectedSessions: Int,
            proposed: Int,
            created: Int,
            batches: Int = 0,
            failedBatches: Int = 0,
            skippedReason: String? = nil
        ) {
            self.inspectedSessions = inspectedSessions
            self.proposed = proposed
            self.created = created
            self.batches = batches
            self.failedBatches = failedBatches
            self.skippedReason = skippedReason
        }

        public static let notEnoughData = Result(
            inspectedSessions: 0, proposed: 0, created: 0, skippedReason: "分析できる履歴がまだありません"
        )

        /// 一部のバッチが失敗したまま完了したか。次回に再試行される。
        public var isPartial: Bool { failedBatches > 0 }
    }

    /// 分析対象にする最小セッション数。
    static let minimumSessions = 5
    /// 1 回の分析で DB から引く最大セッション数。
    static let maxSessions = 60
    /// 1 セッションあたりの抜粋長。
    ///
    /// 繰り返し使われる語を見つけるのが目的なので、少数の長い抜粋より
    /// 多数の短い抜粋のほうが効く。1 バッチに載るセッション数も稼げる。
    static let excerptLimit = 200
    /// 1 回の分析で投げる最大バッチ数。
    ///
    /// バックグラウンドで回るジョブなので、1 回の実行時間に上限を置く。
    /// 溢れた履歴は透かしが進まないので次回の実行が引き継ぐ。
    static let maxBatches = 8
    /// 1 バッチでモデルに挙げさせる候補数。
    static let maxCandidates = 8
    /// 1 回の実行で人間に見せる候補数の上限。承認待ちを溢れさせない。
    static let maxSuggestionsPerRun = 12
    /// 「登録済み」リストに割く文字数。予算を食い過ぎないよう頭を打つ。
    static let knownSurfacesBudget = 300
    /// 候補 JSON の想定出力長。整形と違い入力に比例しないので明示する。
    static let expectedOutputCharacters = 900
    /// バッチ 1 件あたりの見出しなどの固定オーバーヘッド(文字)。
    static let entryOverhead = 8
    /// 予算計算が破綻しても 1 セッションは載るようにする下限。
    static let minimumCorpusBudget = 400
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
        let knownHeader = Self.knownHeader(known)
        let budget = Self.corpusBudget(inputBudget: llm.inputCharacterBudget, knownHeader: knownHeader)
        let batches = Self.batches(
            Self.entries(from: sessions),
            budget: budget,
            maxBatches: Self.maxBatches
        )

        // 実際に渡した分だけを「分析した」と数える。溢れた分は透かしを進めないので次回に回る。
        let analyzedIDs = Set(batches.flatMap { $0 }.map(\.id))
        let analyzed = sessions.filter { analyzedIDs.contains($0.id) }
        guard analyzed.count >= Self.minimumSessions else {
            return .notEnoughData
        }

        var candidates: [String: Candidate] = [:]
        var failures: [any Error] = []

        for batch in batches {
            do {
                let output = try await llm.complete(
                    prompt: FormattingPrompt(
                        system: Self.systemPrompt,
                        user: Self.userPrompt(entries: batch, knownHeader: knownHeader),
                        expectedOutputCharacters: Self.expectedOutputCharacters
                    ),
                    timeout: timeout
                )
                for candidate in Self.parse(output) {
                    Self.merge(candidate, into: &candidates)
                }
            } catch {
                // 1 バッチの失敗で全体を捨てない。ただし黙って飲まず、透かしも進めない。
                failures.append(error)
                KoeLog.analysis.error(
                    "語彙分析のバッチが失敗: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        // 全滅は「分析できなかった」なので、理由を呼び出し側へ返す。
        if let firstFailure = failures.first, failures.count == batches.count {
            throw firstFailure
        }

        // 候補の裏取りは分析に使った全セッションを跨いで行う(バッチ境界は根拠に関係ない)。
        let backed: [VocabularySuggestion] = candidates.values.compactMap { candidate in
            guard let evidence = evidence(for: candidate, in: analyzed) else { return nil }
            return VocabularySuggestion(surface: candidate.surface, evidence: evidence)
        }
        // 根拠の強い順に見せる。同数は表記順にして、同じ履歴なら同じ提示になるようにする。
        let ranked: [VocabularySuggestion] = backed.sorted { left, right in
            left.evidence.count == right.evidence.count
                ? left.surface < right.surface
                : left.evidence.count > right.evidence.count
        }
        let suggestions = Array(ranked.prefix(Self.maxSuggestionsPerRun))

        let created = try await vocabulary.insertSuggestions(suggestions)
        // 失敗が残っているなら透かしを据え置き、次回に同じ範囲を再試行させる。
        if failures.isEmpty, let latest = analyzed.map(\.startedAt).max() {
            try await meta.setDate(latest, forKey: Self.watermarkKey)
        }

        return Result(
            inspectedSessions: analyzed.count,
            proposed: candidates.count,
            created: created,
            batches: batches.count,
            failedBatches: failures.count
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

    // MARK: コーパスの分割

    /// プロンプトに載せる 1 セッション分。
    ///
    /// `body` は長さの見積もりとレンダリングの**両方**で使う。
    /// 別々に組むと、詰め込みの計算とプロンプトの実体がずれて予算が意味を失う。
    struct Entry: Sendable, Equatable {
        var id: String
        var body: String

        var cost: Int { body.count + VocabularySuggestionJob.entryOverhead }
    }

    static func entries(from sessions: [SessionRecord]) -> [Entry] {
        sessions.map { session in
            var lines = ["raw: \(String(session.rawTranscript.prefix(excerptLimit)))"]
            if let formatted = session.formattedText.map({ String($0.prefix(excerptLimit)) }),
               formatted != session.rawTranscript {
                lines.append("formatted: \(formatted)")
            }
            return Entry(id: session.id, body: lines.joined(separator: "\n"))
        }
    }

    /// エンジンの入力予算から固定部分(指示・登録済み一覧)を引いた、本文に使える枠。
    static func corpusBudget(inputBudget: Int, knownHeader: String) -> Int {
        max(minimumCorpusBudget, inputBudget - systemPrompt.count - knownHeader.count)
    }

    /// 予算に収まるようセッションを順に詰める。1 件が予算を超える場合も、
    /// そのセッションだけで 1 バッチにする(捨てない)。
    static func batches(_ entries: [Entry], budget: Int, maxBatches: Int) -> [[Entry]] {
        var batches: [[Entry]] = []
        var current: [Entry] = []
        var used = 0

        for entry in entries {
            if !current.isEmpty, used + entry.cost > budget {
                batches.append(current)
                if batches.count == maxBatches { return batches }
                current = []
                used = 0
            }
            current.append(entry)
            used += entry.cost
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// 同じ語が複数バッチから挙がることがあるので、誤認識パターンを寄せて 1 件にする。
    static func merge(_ candidate: Candidate, into candidates: inout [String: Candidate]) {
        let key = candidate.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard var existing = candidates[key] else {
            candidates[key] = candidate
            return
        }
        existing.misrecognitions = Array(Set(existing.misrecognitions + candidate.misrecognitions)).sorted()
        if existing.reading?.isEmpty != false { existing.reading = candidate.reading }
        candidates[key] = existing
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

    /// 登録済み語の提示。予算を食い過ぎないよう文字数で頭を打つ。
    static func knownHeader(_ known: Set<String>) -> String {
        guard !known.isEmpty else { return "" }
        var surfaces: [String] = []
        var used = 0
        for surface in known.sorted() {
            used += surface.count + 1
            if used > knownSurfacesBudget { break }
            surfaces.append(surface)
        }
        guard !surfaces.isEmpty else { return "" }
        return "登録済み(挙げないでください): " + surfaces.joined(separator: "、") + "\n"
    }

    static func userPrompt(entries: [Entry], knownHeader: String) -> String {
        var lines: [String] = []
        if !knownHeader.isEmpty { lines.append(knownHeader) }
        for (index, entry) in entries.enumerated() {
            lines.append("## \(index + 1)")
            lines.append(entry.body)
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
