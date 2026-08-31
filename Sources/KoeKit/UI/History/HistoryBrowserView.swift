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
        .task { await env.reloadHistory() }
        .accessibilityIdentifier("history.root")
    }

    private var list: some View {
        List(selection: $selectedID) {
            ForEach(env.history) { record in
                HistoryRow(record: record)
                    .tag(record.id)
                    .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
            }
        }
        // .inset はペインの中では枠付きカードとして描かれてしまうため plain にする。
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.background.opacity(0.35))
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(record.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let appName = record.appName {
                    Text(appName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                StatusBadge(status: record.status)
            }
            Text(record.resultText)
                .font(.system(size: 12))
                .lineLimit(2)
                .foregroundStyle(.primary.opacity(0.9))
            HStack(spacing: 5) {
                Pill(text: record.modeSnapshot.modeName, systemImage: "slider.horizontal.3", tint: KoeTheme.accent)
                if let insert = record.insertLatencyMs {
                    Pill(text: Self.durationText(insert), systemImage: "timer", tint: .secondary)
                }
                if let language = record.language, language != .unknown {
                    Pill(text: language.displayName, tint: .secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    static func durationText(_ ms: Int) -> String {
        ms >= 1_000 ? String(format: "%.1f 秒", Double(ms) / 1_000) : "\(ms) ミリ秒"
    }
}

private struct HistoryDetailView: View {
    var record: SessionRecord
    var onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                textCard(
                    title: "挿入した文章",
                    text: record.formattedText,
                    placeholder: "仕上げをせず、聞き取った文字をそのまま挿入しました",
                    emphasized: true
                )
                textCard(title: "聞き取った文字", text: record.rawTranscript, placeholder: nil, emphasized: false)

                if let error = record.error {
                    NoticeBanner(title: "このとき起きたこと", message: error, actionTitle: nil, action: nil)
                }

                metrics
                promptSnapshot

                HStack {
                    Spacer()
                    Button("この履歴を削除", role: .destructive, action: onDelete)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(22)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(record.startedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.system(size: 15, weight: .semibold))
                StatusBadge(status: record.status)
            }
            HStack(spacing: 5) {
                if let appName = record.appName {
                    Pill(text: appName, systemImage: "app", tint: .secondary)
                }
                Pill(text: record.modeSnapshot.modeName, systemImage: "slider.horizontal.3", tint: KoeTheme.accent)
                Pill(text: record.modeSnapshot.trigger.displayName, systemImage: "hand.tap", tint: .secondary)
                Pill(text: record.sttEngine.displayName, systemImage: "waveform", tint: .secondary)
                if let llm = record.llmEngine {
                    Pill(text: llm.displayName, systemImage: "wand.and.sparkles", tint: .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func textCard(title: String, text: String?, placeholder: String?, emphasized: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let text, !text.isEmpty {
                    Button {
                        TextInserter.copyToClipboard(text)
                    } label: {
                        Label("コピー", systemImage: "doc.on.doc")
                            .font(.system(size: 10.5))
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let text, !text.isEmpty {
                Text(text)
                    .font(.system(size: emphasized ? 13 : 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background {
                        RoundedRectangle(cornerRadius: KoeTheme.cardCornerRadius, style: .continuous)
                            .fill(emphasized ? KoeTheme.accent.opacity(0.08) : Color.secondary.opacity(0.07))
                    }
            } else if let placeholder {
                Text(placeholder)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var metrics: some View {
        SettingsCard(title: "かかった時間") {
            HStack(spacing: 22) {
                metric("話した長さ", ms: record.audioDurationMs)
                metric("聞き取り", ms: record.sttLatencyMs)
                metric("仕上げ", ms: record.llmLatencyMs)
                metric("話し終わってから挿入まで", ms: record.insertLatencyMs, highlight: true)
            }
        }
    }

    private func metric(_ label: String, ms: Int?, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(ms.map { $0 >= 1_000 ? String(format: "%.2f 秒", Double($0) / 1_000) : "\($0) ms" } ?? "—")
                .font(.system(size: highlight ? 15 : 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(highlight ? KoeTheme.accent : .primary)
        }
    }

    private var promptSnapshot: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Text("このときモデルに渡した指示文の全文です。あとから設定を変えても、この記録は当時の内容のまま残ります。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Text(record.modeSnapshot.systemPrompt)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.secondary.opacity(0.07))
                        }
                }
                .padding(.top, 6)
            } label: {
                Text("このとき使われた指示文(語彙 \(record.modeSnapshot.vocabularyCount) 語)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
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
