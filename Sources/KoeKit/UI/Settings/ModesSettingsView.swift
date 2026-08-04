import AppKit
import SwiftUI

/// モードの編集(FR-4.4)。アプリごとの差異はここだけで表現する。
struct ModesSettingsView: View {
    var env: AppEnvironment
    @State private var selectedID: Mode.ID?
    @State private var draft: Mode?
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("録音を始めたときに使っていたアプリで、モードが自動で選ばれます。どれにも当てはまらないときは Default になります。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 14) {
                modeList
                editor
            }
        }
        .task { selectIfNeeded() }
        .onChange(of: env.modes.count) { _, _ in selectIfNeeded() }
    }

    private var modeList: some View {
        VStack(spacing: 6) {
            List(selection: $selectedID) {
                ForEach(env.modes) { mode in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mode.name)
                                .font(.system(size: 12, weight: .medium))
                            Text(mode.isFallback ? "フォールバック" : "\(mode.bundleIDs.count) アプリ")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if mode.isBuiltin {
                            Pill(text: "標準", tint: .secondary)
                        }
                    }
                    .tag(mode.id)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 190, height: 320)
            .onChange(of: selectedID) { _, _ in loadDraft() }

            HStack(spacing: 6) {
                Button {
                    Task { await addMode() }
                } label: {
                    Image(systemName: "plus")
                }
                .help("モードを追加")

                Button {
                    Task {
                        guard let mode = currentMode, let copy = await env.duplicateMode(mode) else { return }
                        selectedID = copy.id
                    }
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .disabled(currentMode == nil)
                .help("複製")

                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(currentMode == nil)
                .help("削除")

                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(width: 190)
        }
        .confirmationDialog(
            "「\(currentMode?.name ?? "")」を削除しますか？",
            isPresented: $showDeleteConfirm
        ) {
            Button("削除", role: .destructive) {
                Task {
                    guard let id = selectedID else { return }
                    await env.deleteMode(id: id)
                    selectedID = env.modes.first?.id
                }
            }
        } message: {
            Text("標準モードを削除しても、次回起動時に復活することはありません。")
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let draft {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsCard(title: "基本") {
                        LabeledContent("名前") {
                            TextField("", text: bind(\.name))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                        }
                        Picker("言語", selection: bind(\.languagePreference)) {
                            ForEach(LanguagePreference.allCases) { preference in
                                Text(preference.displayName).tag(preference)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    SettingsCard(
                        title: "このモードを使うアプリ",
                        footnote: "空にすると、どのアプリにも当てはまらない「既定のモード」になります。`com.jetbrains.*` のように * で複数まとめて指定できます。"
                    ) {
                        bundleIDEditor(draft)
                    }

                    SettingsCard(
                        title: "仕上げの指示",
                        footnote: "どのモードでも共通の処理(「えーと」の削除・句読点・言い直しの整理・語彙の統一)は自動で行われます。ここにはこのモードだけの指示を書きます。"
                    ) {
                        TextEditor(text: bind(\.prompt))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 190)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(.background.opacity(0.6))
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(.separator, lineWidth: 0.5)
                            }
                    }

                    HStack {
                        if draft.isBuiltin {
                            Button("標準の内容に戻す") {
                                Task {
                                    await env.resetMode(id: draft.id)
                                    loadDraft()
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        Spacer()
                        Text(hasChanges ? "未保存の変更があります" : "保存済み")
                            .font(.system(size: 10.5))
                            .foregroundStyle(hasChanges ? KoeTheme.warning : Color.secondary.opacity(0.7))
                        Button("保存") {
                            Task { await save() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasChanges)
                        .keyboardShortcut("s", modifiers: .command)
                    }
                }
            }
        } else {
            VStack {
                Spacer()
                Text("モードを選択してください")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func bundleIDEditor(_ mode: Mode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if mode.bundleIDs.isEmpty {
                Text("未設定(既定のモードとして使われます)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(Array(mode.bundleIDs.enumerated()), id: \.offset) { index, bundleID in
                        HStack(spacing: 4) {
                            Text(bundleID)
                                .font(.system(size: 10.5, design: .monospaced))
                            Button {
                                draft?.bundleIDs.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background {
                            Capsule().fill(KoeTheme.accent.opacity(0.12))
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                if let bundleID = env.coordinator.frontmostBundleID,
                   !mode.bundleIDs.contains(bundleID) {
                    Button {
                        draft?.bundleIDs.append(bundleID)
                    } label: {
                        Label(
                            "\(env.coordinator.frontmostAppName ?? bundleID) を追加",
                            systemImage: "arrow.down.app"
                        )
                        .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button {
                    chooseApplication()
                } label: {
                    Label("アプリを選択…", systemImage: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: 操作

    private var currentMode: Mode? {
        env.modes.first { $0.id == selectedID }
    }

    private var hasChanges: Bool {
        guard let draft, let current = currentMode else { return false }
        return draft.name != current.name
            || draft.prompt != current.prompt
            || draft.bundleIDs != current.bundleIDs
            || draft.languagePreference != current.languagePreference
    }

    private func bind<Value>(_ keyPath: WritableKeyPath<Mode, Value>) -> Binding<Value> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? BuiltinModes.defaultMode[keyPath: keyPath] },
            set: { draft?[keyPath: keyPath] = $0 }
        )
    }

    private func selectIfNeeded() {
        if selectedID == nil || !env.modes.contains(where: { $0.id == selectedID }) {
            selectedID = env.modes.first?.id
        }
        loadDraft()
    }

    private func loadDraft() {
        draft = currentMode
    }

    private func save() async {
        guard let draft else { return }
        await env.save(mode: draft)
        loadDraft()
    }

    private func addMode() async {
        let mode = Mode(
            name: "新しいモード",
            bundleIDs: [],
            prompt: "ここにこのモード固有の整形指示を書きます。",
            sortOrder: (env.modes.map(\.sortOrder).max() ?? 0) + 10
        )
        await env.save(mode: mode)
        selectedID = mode.id
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "追加"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            if draft?.bundleIDs.contains(bundleID) == false {
                draft?.bundleIDs.append(bundleID)
            }
        }
    }
}

/// bundle ID のチップを折り返して並べる軽量レイアウト。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 400
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
