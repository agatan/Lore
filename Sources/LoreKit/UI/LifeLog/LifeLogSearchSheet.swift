import SwiftUI

struct LifeLogSearchSheet: View {
    var env: AppEnvironment
    /// 開いた時点の検索語。Debugの画面撮影で結果の並びを確かめるために使う。
    var initialQuery = ""

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [LifeLogSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    /// ↑↓で動かし、Returnで開く結果。Spotlightと同じく、入力欄から手を離さずに選べる。
    @State private var selectedIndex = 0
    @FocusState private var focusesSearch: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("発話、音声入力、メモを検索", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: LoreTheme.TextSize.reading))
                    .focused($focusesSearch)
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                    .onSubmit { if results.indices.contains(selectedIndex) { select(results[selectedIndex]) } }
                    .accessibilityIdentifier("life-log.search-input")
                if isSearching { ProgressView().controlSize(.small) }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
                Button("完了") { dismiss() }.buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Divider()

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: LoreTheme.TextSize.caption)).foregroundStyle(LoreTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                Spacer()
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyState("日本語の部分一致で横断検索します", symbol: "text.magnifyingglass")
            } else if !isSearching && results.isEmpty {
                emptyState("見つかりませんでした", symbol: "magnifyingglass")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                resultRow(result, isSelected: index == selectedIndex)
                                    .id(result.id)
                                    .onHover { if $0 { selectedIndex = index } }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: selectedIndex) { _, index in
                        guard results.indices.contains(index) else { return }
                        proxy.scrollTo(results[index].id)
                    }
                }
                HStack(spacing: 14) {
                    Text("\(results.count)件")
                    Spacer()
                    Label("移動", systemImage: "arrow.up.arrow.down")
                    Label("開く", systemImage: "return")
                }
                .font(.system(size: LoreTheme.TextSize.caption))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .overlay(alignment: .top) { Divider() }
            }
        }
        .frame(width: 620, height: 520)
        .task {
            if query.isEmpty { query = initialQuery }
            focusesSearch = true
        }
        .task(id: query) { await runSearch() }
    }

    private func runSearch() async {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            results = []
            errorMessage = nil
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let database = env.database else { return }
            isSearching = true
            errorMessage = nil
            results = try await database.lifeLog.search(value)
            selectedIndex = 0
            isSearching = false
        } catch is CancellationError {
            return
        } catch {
            isSearching = false
            errorMessage = error.localizedDescription
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(results.count - 1, max(0, selectedIndex + delta))
    }

    /// 一件の結果。印と色はtimelineと同じにし、語の一致した所だけを太く色付けする。
    private func resultRow(_ result: LifeLogSearchResult, isSelected: Bool) -> some View {
        Button { select(result) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol(for: result.kind))
                    .font(.system(size: LoreTheme.TextSize.micro, weight: .semibold))
                    .foregroundStyle(tint(for: result.kind))
                    .frame(width: 24, height: 24)
                    .background(tint(for: result.kind).opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(LocalizedStringKey(result.kind.displayName))
                            .font(.system(size: LoreTheme.TextSize.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(result.occurredAt.loreFormatted(.dateTime.month().day().weekday(.abbreviated).hour().minute()))
                            .font(LoreTheme.timeFont)
                            .foregroundStyle(.tertiary)
                    }
                    Text(highlighted(result.text))
                        .font(.system(size: LoreTheme.TextSize.body))
                        .lineSpacing(3)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "return")
                    .font(.system(size: LoreTheme.TextSize.micro, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? LoreTheme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("life-log.search-result-\(result.id)")
    }

    private func highlighted(_ text: String) -> AttributedString {
        var value = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return value }
        var searchStart = value.startIndex
        while searchStart < value.endIndex,
              let range = value[searchStart...].range(of: needle, options: [.caseInsensitive, .widthInsensitive]) {
            value[range].foregroundColor = LoreTheme.accent
            value[range].font = .system(size: LoreTheme.TextSize.body, weight: .semibold)
            searchStart = range.upperBound
        }
        return value
    }

    private func select(_ result: LifeLogSearchResult) {
        Task {
            await env.lifeLog.jumpToSearchResult(result)
            dismiss()
        }
    }

    private func emptyState(_ text: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: LoreTheme.TextSize.metric, weight: .light))
            Text(text).font(.system(size: LoreTheme.TextSize.callout, weight: .medium))
        }
        .foregroundStyle(.secondary.opacity(0.45))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func symbol(for kind: LifeLogSearchResult.Kind) -> String {
        switch kind {
        case .utterance: "waveform"
        case .dictation: "keyboard"
        case .memo: "pencil"
        }
    }

    private func tint(for kind: LifeLogSearchResult.Kind) -> Color {
        switch kind {
        case .utterance: .secondary
        case .dictation: LoreTheme.accent
        case .memo: LoreTheme.accent
        }
    }
}
