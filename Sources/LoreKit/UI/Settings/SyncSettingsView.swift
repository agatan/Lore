import AppKit
import SwiftUI

/// 共通の「同期」section。暗号化した変更fileを利用者のfolderへ置いてMac間で共有する。
struct SyncSettingsView: View {
    var env: AppEnvironment
    private var sync: SyncCoordinator { env.sync }

    @State private var shownCode: String?
    @State private var isJoining = false
    @State private var joinCode = ""
    @State private var actionError: String?
    @State private var isWorking = false
    @State private var confirmation: Confirmation?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            if sync.isEnabled {
                enabledCard
            } else {
                setupCard
            }
            SettingsCard(
                title: "同期する内容",
                footnote: "このMacで暗号化してから、選んだフォルダの「Lore Sync」に置きます。Lore自身は通信せず、iCloud DriveやDropboxなどの提供元も中身を読めません。"
            ) {
                SettingsRow(title: "同期するもの", caption: "発話、メモ、音声入力の履歴、語彙") { EmptyView() }
                SettingsRow(title: "同期しないもの", caption: "録音した音声、APIキー、設定、取り込んだ予定") { EmptyView() }
                SettingsRow(title: "削除したとき", caption: "1件ずつ削除したものは、他のMacからも消えます。保持期間による削除と全削除はこのMacだけです") { EmptyView() }
            }
        }
        .sheet(isPresented: Binding(get: { shownCode != nil }, set: { if !$0 { shownCode = nil } })) {
            if let shownCode { codeSheet(shownCode) }
        }
        .sheet(isPresented: $isJoining) { joinSheet }
        .confirmationDialog(LocalizedStringKey(confirmation?.title ?? ""), isPresented: Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil } }
        )) {
            if let confirmation {
                Button(LocalizedStringKey(confirmation.actionTitle), role: confirmation == .disconnect ? .destructive : nil) {
                    self.confirmation = nil
                    perform(confirmation)
                }
            }
            Button("キャンセル", role: .cancel) { confirmation = nil }
        } message: {
            Text(LocalizedStringKey(confirmation?.message ?? ""))
        }
    }

    // MARK: - 無効時

    private var setupCard: some View {
        SettingsCard(title: "Mac間の同期") {
            SettingsRow(title: "新しく同期を始める", caption: "1台目のMacで、他のMacからも見えるフォルダを選びます") {
                Button("フォルダを選ぶ…") { startNew() }
                    .disabled(isWorking)
                    .accessibilityIdentifier("sync.start-new")
            }
            SettingsRow(title: "同期コードで参加", caption: "2台目以降のMacで、1台目に表示された同期コードを入力します") {
                Button("参加…") {
                    joinCode = ""
                    actionError = nil
                    isJoining = true
                }
                .disabled(isWorking)
                .accessibilityIdentifier("sync.join")
            }
            if let actionError { errorLabel(actionError) }
        }
    }

    // MARK: - 有効時

    private var enabledCard: some View {
        SettingsCard(title: "Mac間の同期") {
            SettingsRow(title: "状態", caption: statusCaption) {
                HStack(spacing: 8) {
                    if sync.isSyncing { ProgressView().controlSize(.small) }
                    Button("今すぐ同期") { Task { await sync.syncNow() } }
                        .disabled(sync.isSyncing)
                        .accessibilityIdentifier("sync.now")
                }
            }
            .accessibilityIdentifier("sync.status")
            if let path = sync.folderPath {
                SettingsRow(title: "同期フォルダ", caption: path) {
                    Button("表示") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: path).appending(path: SyncEngine.directoryName),
                        ])
                    }
                }
            }
            if let error = sync.lastError { errorLabel(error) }
            SettingsRow(title: "同期コード", caption: "別のMacを追加するときに入力します") {
                Button("表示…") { confirmation = .reveal }
                    .accessibilityIdentifier("sync.reveal-code")
            }
            SettingsRow(title: "同期を解除", caption: "このMacの同期コードと同期状態を消します。データとフォルダ内のファイルは残ります") {
                Button("解除…", role: .destructive) { confirmation = .disconnect }
                    .accessibilityIdentifier("sync.disconnect")
            }
            if let actionError { errorLabel(actionError) }
        }
    }

    private var statusCaption: String {
        if sync.isSyncing { return "同期中…" }
        guard let date = sync.lastSyncedAt else { return "まだ同期していません" }
        return String(lore: "最終同期 \(date.loreFormatted(date: .abbreviated, time: .shortened))")
    }

    // MARK: - sheet

    private func codeSheet(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("同期コード").font(.system(size: LoreTheme.TextSize.headline, weight: .semibold))
            Text("他のMacの「同期コードで参加」で入力します。コードを知っている人は同期データを読めるため、他人には渡さないでください。すべてのMacを失うと再表示できないので、パスワード管理アプリなどに保管してください。")
                .font(LoreTheme.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(code)
                .font(.system(size: LoreTheme.TextSize.reading, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelSurface(cornerRadius: LoreTheme.smallCornerRadius)
                .accessibilityIdentifier("sync.code")
            HStack {
                Button("コピー") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
                Spacer()
                Button("閉じる") { shownCode = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private var joinSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("同期コードで参加").font(.system(size: LoreTheme.TextSize.headline, weight: .semibold))
            Text("1台目のMacに表示された同期コードを入力し、1台目と同じフォルダを選んでください。このMacにあるデータも同期されます。")
                .font(LoreTheme.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("XXXX-XXXX-…", text: $joinCode)
                .font(.system(size: LoreTheme.TextSize.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("sync.code-field")
            if let actionError { errorLabel(actionError) }
            HStack {
                Button("キャンセル") { isJoining = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("フォルダを選んで参加…") { join() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(joinCode.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                    .accessibilityIdentifier("sync.join-confirm")
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    // MARK: - 操作

    private func startNew() {
        guard let folder = chooseFolder() else { return }
        actionError = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                shownCode = try await sync.startNew(folder: folder)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func join() {
        guard let folder = chooseFolder() else { return }
        actionError = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await sync.join(code: joinCode, folder: folder)
                isJoining = false
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func perform(_ confirmation: Confirmation) {
        actionError = nil
        switch confirmation {
        case .reveal:
            do { shownCode = try sync.revealCode() } catch { actionError = error.localizedDescription }
        case .disconnect:
            Task {
                do { try await sync.disconnect() } catch { actionError = error.localizedDescription }
            }
        }
    }

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(lore: "このフォルダを使う")
        panel.message = String(lore: "iCloud Drive、Dropbox、Syncthingなど、他のMacからも見えるフォルダを選んでください")
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: LoreTheme.TextSize.caption))
            .foregroundStyle(LoreTheme.danger)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("sync.error")
    }

    private enum Confirmation: Equatable {
        case reveal
        case disconnect

        var title: String {
            switch self {
            case .reveal: "同期コードを表示しますか？"
            case .disconnect: "このMacの同期を解除しますか？"
            }
        }

        var actionTitle: String {
            switch self {
            case .reveal: "表示"
            case .disconnect: "同期を解除"
            }
        }

        var message: String {
            switch self {
            case .reveal: "同期コードを知っている人は同期データを読めます。周りに人がいないことを確かめてください。"
            case .disconnect: "このMacの同期コードと同期状態を消し、以後の変更を送受信しません。このMacのデータとフォルダ内のファイルは残ります。"
            }
        }
    }
}
