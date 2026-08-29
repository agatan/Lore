import SwiftUI

struct LifeLogMiniWindow: View {
    var env: AppEnvironment
    @State private var memoDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("ライフログ", systemImage: "waveform")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                Toggle(isOn: Binding(
                    get: { env.lifeLog.isCapturing },
                    set: { enabled in
                        env.setLifeLogCaptureEnabled(enabled)
                    }
                )) {
                    Image(systemName: env.lifeLog.isCapturing ? "record.circle.fill" : "record.circle")
                }
                .toggleStyle(.button)
                .tint(env.lifeLog.isCapturing ? KoeTheme.recording : KoeTheme.accent)
                .help(env.lifeLog.isCapturing ? "記録を止める" : "記録を始める")
            }
            .padding(12)

            Divider().opacity(0.4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            switch item.kind {
                            case .utterance(let utterance): utteranceRow(utterance)
                            case .memo(let memo): memoRow(memo)
                            }
                        }
                        if env.lifeLog.isCapturing || env.lifeLog.isTranscribing {
                            HStack(alignment: .top, spacing: 10) {
                                LiveWaveform()
                                    .frame(width: 52)
                                Text(env.lifeLog.captureStatusText)
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(KoeTheme.accent)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .id("live")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                }
                .onChange(of: items.count) { old, new in
                    guard new > old else { return }
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .overlay {
                    if items.isEmpty && !env.lifeLog.isCapturing && !env.lifeLog.isTranscribing {
                        VStack(spacing: 10) {
                            Image(systemName: env.lifeLog.isCapturing ? "waveform" : "waveform.slash")
                                .font(.system(size: 28, weight: .light))
                            Text(env.lifeLog.isCapturing ? "発話を待っています" : "記録は停止中です")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(.secondary.opacity(0.5))
                    }
                }
            }

            Divider().opacity(0.35)
            HStack(alignment: .bottom, spacing: 8) {
                TextField("メモを追加…", text: $memoDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15))
                    .onSubmit { sendMemo() }
                Button(action: sendMemo) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .disabled(memoDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("メモを追加")
            }
            .padding(10)
        }
        .frame(minWidth: 340, minHeight: 360)
        .background {
            LinearGradient(
                colors: [KoeTheme.accent.opacity(0.055), KoeTheme.accentSecondary.opacity(0.025), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
        .task {
            env.applyLifeLogMiniWindowLevel()
            await env.lifeLog.followCurrentDay()
        }
        .onChange(of: env.settings.lifeLogMiniWindowAlwaysOnTop) { _, _ in
            env.applyLifeLogMiniWindowLevel()
        }
    }

    private enum ItemKind { case utterance(LifeLogUtterance), memo(LifeLogMemo) }
    private struct Item: Identifiable {
        var id: String
        var date: Date
        var kind: ItemKind
    }
    private var items: [Item] {
        (env.lifeLog.day.utterances.map { Item(id: "u-\($0.id)", date: $0.startedAt, kind: .utterance($0)) }
         + env.lifeLog.day.memos.map { Item(id: "m-\($0.id)", date: $0.createdAt, kind: .memo($0)) })
            .sorted { $0.date < $1.date }
    }

    private func utteranceRow(_ utterance: LifeLogUtterance) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(utterance.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 45, alignment: .leading)
            Text(utterance.text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .id("u-\(utterance.id)")
    }

    private func memoRow(_ memo: LifeLogMemo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(memo.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 45, alignment: .leading)
            Image(systemName: "note.text")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(KoeTheme.accent)
                .frame(width: 14)
            Text(memo.text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .id("m-\(memo.id)")
    }

    private func sendMemo() {
        let value = memoDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        memoDraft = ""
        Task { await env.lifeLog.addMemo(value) }
    }
}
