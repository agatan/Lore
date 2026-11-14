import AppKit
import SwiftUI

/// 履歴の一覧と詳細(FR-7.2)。
///
/// 「なぜこの出力になったか」を後から説明できることが目的なので、
/// 生テキストと整形結果を並べ、適用したプロンプト全文まで辿れるようにする。
struct HistoryBrowserView: View {
    var env: AppEnvironment
    @State private var query = ""
    @State private var selectedID: SessionRecord.ID?

    /// 一覧の幅。ドラッグで変えられる。
    @State private var listWidth: CGFloat = 340

    var body: some View {
        // HSplitView は子の縦幅を伸ばしてくれず、コンテンツの高さのまま中央に浮いてしまった。
        // AppKit の暗黙のサイズ決定に頼らず、明示的に分割する。
        HStack(spacing: 0) {
            list
                .frame(width: listWidth)
            ResizableDivider(width: $listWidth, minimum: 260, maximum: 520)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $query, prompt: "話した内容を検索")
        .onChange(of: query) { _, newValue in
            Task { await env.reloadHistory(query: newValue) }
        }
        .task {
            await env.reloadHistory()
            if selectedID == nil { selectedID = env.history.first?.id }
        }
        .accessibilityIdentifier("history.root")
    }

    private var list: some View {
        List(selection: $selectedID) {
            ForEach(env.history) { record in
                HistoryRow(record: record)
                    .tag(record.id)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }
        }
        // Mailの一覧列と同じく、選択は角丸のhighlightで示し、行の枠は描かない。
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .overlay {
            if env.history.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "履歴がありません" : "見つかりません",
                    systemImage: query.isEmpty ? "waveform" : "magnifyingglass",
                    description: Text(query.isEmpty ? "ホットキーで話すと、ここに残ります。" : "別の語で試してください。")
                )
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let record = selected {
            HistoryDetailView(record: record) {
                Task {
                    await env.deleteHistory(id: record.id)
                    selectedID = nil
                }
            }
        } else {
            ContentUnavailableView(
                "履歴を選択",
                systemImage: "clock.arrow.circlepath",
                description: Text("話した内容と、そのとき使われたモード・指示文を確認できます。")
            )
        }
    }

    private var selected: SessionRecord? {
        env.history.first { $0.id == selectedID }
    }
}

private struct HistoryRow: View {
    var record: SessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(record.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(LoreTheme.timeFont)
                    .foregroundStyle(.secondary)
                Text(subtitle)
                    .font(LoreTheme.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                // 正常に挿入できた履歴は印を付けず、注意が要るものだけを目立たせる。
                if record.status != .completed {
                    StatusBadge(status: record.status)
                }
            }
            Text(record.resultText)
                .font(.system(size: 12.5))
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        [record.appName, record.modeSnapshot.modeName].compactMap { $0 }.joined(separator: " · ")
    }

    static func durationText(_ ms: Int) -> String {
        ms >= 1_000 ? String(format: "%.1f 秒", Double(ms) / 1_000) : "\(ms) ミリ秒"
    }
}

/// 履歴1件の詳細。読みやすい幅の列を中央に置き、挿入した文章を本文として一番大きく見せる。
/// 聞き取った文字と内訳は、なぜその文章になったかを確かめる補助として下に続ける。
private struct HistoryDetailView: View {
    var record: SessionRecord
    var onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("挿入した文章", copying: record.formattedText)
                    if let text = record.formattedText, !text.isEmpty {
                        HStack(alignment: .top, spacing: 14) {
                            Capsule()
                                .fill(LoreTheme.accent)
                                .frame(width: 3)
                            Text(text)
                                .font(.system(size: 17))
                                .lineSpacing(6)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("仕上げをせず、聞き取った文字をそのまま挿入しました")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("聞き取った文字", copying: record.rawTranscript)
                    Text(record.rawTranscript.isEmpty ? "—" : record.rawTranscript)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if let error = record.error {
                    NoticeBanner(title: "このとき起きたこと", message: error, actionTitle: nil, action: nil)
                }

                LatencyBreakdown(record: record)
                promptSnapshot

                Button("この履歴を削除", role: .destructive, action: onDelete)
                    .buttonStyle(.borderless)
                    .foregroundStyle(LoreTheme.recording)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 40)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.startedAt.formatted(.dateTime.year().month(.wide).day().weekday(.wide)))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(record.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(LoreTheme.titleFont)
                        .accessibilityAddTraits(.isHeader)
                    StatusBadge(status: record.status)
                }
            }
            HStack(spacing: 5) {
                if let appName = record.appName {
                    Pill(text: appName, systemImage: "app", tint: .secondary)
                }
                Pill(text: record.modeSnapshot.modeName, systemImage: "slider.horizontal.3", tint: LoreTheme.accent)
                Pill(text: record.modeSnapshot.trigger.displayName, systemImage: "hand.tap", tint: .secondary, localized: true)
                Pill(text: record.sttEngine.displayName, systemImage: "waveform", tint: .secondary)
                if let llm = record.llmEngine {
                    Pill(text: llm.displayName, systemImage: "wand.and.sparkles", tint: .secondary, localized: llm == .none)
                }
            }
        }
    }

    private func sectionTitle(_ title: String, copying text: String?) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
                .font(LoreTheme.sectionFont)
                .foregroundStyle(.secondary)
            Spacer()
            if let text, !text.isEmpty {
                Button {
                    TextInserter.copyToClipboard(text)
                } label: {
                    Label("コピー", systemImage: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var promptSnapshot: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("このときモデルに渡した指示文の全文です。あとから設定を変えても、この記録は当時の内容のまま残ります。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(record.modeSnapshot.systemPrompt.isEmpty ? "—" : record.modeSnapshot.systemPrompt)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.top, 8)
        } label: {
            Text("このとき使われた指示文(語彙 \(record.modeSnapshot.vocabularyCount) 語)")
                .font(LoreTheme.sectionFont)
                .foregroundStyle(.secondary)
        }
    }
}

/// 話し終わってから挿入までを、聞き取り・仕上げ・挿入の帯に分けて見せる。
/// 計測のない区間は帯に含めず、合計だけが分かる場合は一本の帯にする。
private struct LatencyBreakdown: View {
    var record: SessionRecord

    private struct Part: Identifiable {
        var label: String
        var ms: Int
        var tint: Color
        var id: String { label }
    }

    private var parts: [Part] {
        guard let total = record.insertLatencyMs, total > 0 else { return [] }
        let stt = record.sttLatencyMs ?? 0
        let llm = record.llmLatencyMs ?? 0
        let rest = max(0, total - stt - llm)
        return [
            Part(label: "聞き取り", ms: stt, tint: LoreTheme.accent),
            Part(label: "仕上げ", ms: llm, tint: LoreTheme.accentSecondary),
            Part(label: "挿入", ms: rest, tint: LoreTheme.success),
        ].filter { $0.ms > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("かかった時間")
                .font(LoreTheme.sectionFont)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: record.insertLatencyMs.map(Self.seconds) ?? "—")
                    .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                Text("話し終わってから挿入まで")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if let audio = record.audioDurationMs {
                    Text("話した長さ \(Self.seconds(audio))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if !parts.isEmpty {
                GeometryReader { proxy in
                    let total = CGFloat(parts.reduce(0) { $0 + $1.ms })
                    let spacing: CGFloat = 2
                    let usable = proxy.size.width - spacing * CGFloat(parts.count - 1)
                    HStack(spacing: spacing) {
                        ForEach(parts) { part in
                            Rectangle()
                                .fill(part.tint)
                                .frame(width: max(4, usable * CGFloat(part.ms) / total))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 8)
                .accessibilityHidden(true)
                HStack(spacing: 18) {
                    ForEach(parts) { part in
                        HStack(spacing: 6) {
                            Circle().fill(part.tint).frame(width: 7, height: 7)
                            Text(LocalizedStringKey(part.label))
                                .foregroundStyle(.secondary)
                            Text(verbatim: Self.seconds(part.ms))
                                .monospacedDigit()
                        }
                        .font(.system(size: 12))
                    }
                }
            }
        }
    }

    static func seconds(_ ms: Int) -> String {
        ms >= 1_000 ? String(format: "%.2f 秒", Double(ms) / 1_000) : "\(ms) ms"
    }
}

#if DEBUG
@MainActor
private func previewEnvironment() -> AppEnvironment {
    let env = AppEnvironment()
    let snapshot = ModeSnapshot(
        modeName: "Chat",
        modePrompt: "カジュアルに",
        systemPrompt: "あなたは口述筆記の整形エンジンです。…",
        vocabularyCount: 3,
        trigger: .pushToTalk
    )
    env.applyPreviewHistory([
        SessionRecord(
            id: "1",
            startedAt: Date(),
            status: .completed,
            appName: "Slack",
            modeSnapshot: snapshot,
            sttEngine: .speechAnalyzer,
            llmEngine: .foundationModels,
            language: .ja,
            rawTranscript: "えーと明日の一on一なんですけど三十分後ろにずらしてもらえると助かります",
            formattedText: "明日の 1on1 ですが、30 分後ろにずらしてもらえると助かります。",
            insertLatencyMs: 1_240
        ),
        SessionRecord(
            id: "2",
            startedAt: Date().addingTimeInterval(-600),
            status: .fallback,
            appName: "AIアシスタント",
            modeSnapshot: snapshot,
            sttEngine: .speechAnalyzer,
            llmEngine: EngineIdentifier.none,
            language: .mixed,
            rawTranscript: "この関数をリファクタしてテストも書いて",
            error: "処理がタイムアウトしました",
            insertLatencyMs: 6_310
        ),
    ])
    return env
}

#Preview("履歴") {
    HistoryBrowserView(env: previewEnvironment())
        .frame(width: 900, height: 560)
}
#endif
