import SwiftUI

struct LifeLogSearchSheet: View {
    var env: AppEnvironment

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [LifeLogSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @FocusState private var focusesSearch: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("発話、メモ、TODO、要約を検索", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focusesSearch)
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
                    .font(.system(size: 11.5)).foregroundStyle(KoeTheme.recording)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                Spacer()
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyState("日本語の部分一致で横断検索します", symbol: "text.magnifyingglass")
            } else if !isSearching && results.isEmpty {
                emptyState("見つかりませんでした", symbol: "magnifyingglass")
            } else {
                List(results) { result in
                    Button { select(result) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: symbol(for: result.kind))
                                .foregroundStyle(tint(for: result.kind)).frame(width: 18)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 7) {
                                    Text(result.kind.displayName)
                                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                        .foregroundStyle(tint(for: result.kind))
                                    Text(result.day)
                                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                    if let status = result.todoStatus {
                                        Text(status == .open ? "未実施" : status == .draft ? "Draft" : "完了")
                                            .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                                    }
                                }
                                Text(result.text)
                                    .font(.system(size: 12.5)).foregroundStyle(.primary)
                                    .lineLimit(3).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.quaternary)
                        }
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("life-log.search-result-\(result.id)")
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 620, height: 520)
        .task { focusesSearch = true }
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
            isSearching = false
        } catch is CancellationError {
            return
        } catch {
            isSearching = false
            errorMessage = error.localizedDescription
        }
    }

    private func select(_ result: LifeLogSearchResult) {
        Task {
            await env.lifeLog.jumpToSearchResult(result)
            dismiss()
        }
    }

    private func emptyState(_ text: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.secondary.opacity(0.45))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func symbol(for kind: LifeLogSearchResult.Kind) -> String {
        switch kind {
        case .utterance: "waveform"
        case .dictation: "keyboard.badge.ellipsis"
        case .memo: "text.bubble"
        case .todo: "checkmark.circle"
        case .summary: "sparkles"
        }
    }

    private func tint(for kind: LifeLogSearchResult.Kind) -> Color {
        switch kind {
        case .utterance: KoeTheme.accent
        case .dictation: KoeTheme.accent
        case .memo: KoeTheme.accentSecondary
        case .todo: KoeTheme.success
        case .summary: KoeTheme.warning
        }
    }
}
