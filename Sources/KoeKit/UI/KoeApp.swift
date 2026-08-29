import AppKit
import SwiftUI

/// アプリ本体。Dock アイコンを持たないメニューバー常駐アプリ(FR-8.1)。
public struct KoeApp: App {
    @NSApplicationDelegateAdaptor(KoeApplicationDelegate.self) private var applicationDelegate
    @State private var env = AppEnvironment()

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(env: env)
                .tint(env.settings.accentPalette.color)
                .accentColor(env.settings.accentPalette.color)
        } label: {
            // ラベルは常駐中ずっと生きているので、ここで初期化を回す。
            MenuBarRoot(env: env)
        }
        .menuBarExtraStyle(.window)

        Window("Koe", id: KoeWindow.main) {
            MainWindowView(env: env)
                .koeWindow()
                .tint(env.settings.accentPalette.color)
                .accentColor(env.settings.accentPalette.color)
        }
        .defaultSize(width: 1_480, height: 820)
        .commands {
            KoeCommands(env: env)
        }

        Window("Koe 設定", id: KoeWindow.settings) {
            SettingsWindowView(env: env)
                .koeWindow()
                .tint(env.settings.accentPalette.color)
                .accentColor(env.settings.accentPalette.color)
        }
        .defaultSize(width: 980, height: 720)

        Window("ライフログ ミニ", id: KoeWindow.lifeLogMini) {
            LifeLogMiniWindow(env: env)
                .koeWindow()
                .tint(env.settings.accentPalette.color)
                .accentColor(env.settings.accentPalette.color)
        }
        .defaultSize(width: 460, height: 620)

        Window("すべてのTODO", id: KoeWindow.lifeLogTodos) {
            LifeLogTodoManagerWindow(env: env)
                .koeWindow()
                .tint(env.settings.accentPalette.color)
                .accentColor(env.settings.accentPalette.color)
        }
        .defaultSize(width: 680, height: 520)
    }
}

private struct KoeCommands: Commands {
    var env: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("設定…") {
                env.settingsSection = .common
                openWindow(id: KoeWindow.settings)
                NSApp.activate()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .windowArrangement) {
            Button("ライフログ ミニウィンドウ") {
                env.onToggleLifeLogMiniWindow?()
            }
        }
    }
}

public enum KoeWindow {
    public static let main = "koe.main"
    public static let settings = "koe.settings"
    public static let lifeLogMini = "koe.life-log-mini"
    public static let lifeLogTodos = "koe.life-log-todos"
}

/// メニューバーのアイコン + 起動処理。
private struct MenuBarRoot: View {
    var env: AppEnvironment

    @Environment(\.openWindow) private var openWindow
    @State private var hud: HudController?

    var body: some View {
        MenuBarLabel(coordinator: env.coordinator, lifeLog: env.lifeLog, settings: env.settings)
            .task { await bootstrap() }
    }

    @MainActor
    private func bootstrap() async {
        guard hud == nil else { return }
        let controller = HudController(coordinator: env.coordinator, settings: env.settings)
        controller.start()
        hud = controller

        env.onToggleLifeLogMiniWindow = {
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == KoeWindow.lifeLogMini }), window.isVisible {
                window.close()
            } else {
                openWindow(id: KoeWindow.lifeLogMini)
                NSApp.activate()
                DispatchQueue.main.async { env.applyLifeLogMiniWindowLevel() }
            }
        }
        env.onShowMainWindow = {
            openWindow(id: KoeWindow.main)
            NSApp.activate()
        }

        await env.boot()

        // 起動直後はKoeのメイン画面を開く。
        if env.settings.openHistoryAtLaunch || AppEnvironment.usesScreenshotDemoData {
            env.mainSection = .lifeLog
            openWindow(id: KoeWindow.main)
        }
    }
}

/// `NSApp.terminate`、Cmd+Q、システム終了を同じ非同期の保存境界へ集約する。
final class KoeApplicationDelegate: NSObject, NSApplicationDelegate {
    static let terminationDeadline: Duration = .seconds(20)
    private var terminationInProgress = false
    private var terminationReplySent = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        guard let environment = AppEnvironment.current, environment.hasPendingTerminationWork else {
            KoeLog.ui.info("保留中の処理がないためKoeを直ちに終了します")
            return .terminateNow
        }

        terminationInProgress = true
        KoeLog.ui.info("保留中の処理を確定してからKoeを終了します")
        Task { @MainActor in
            await environment.prepareForTermination()
            finishTermination(sender, reason: "保存処理が完了しました")
        }
        Task { @MainActor in
            do { try await Task.sleep(for: Self.terminationDeadline) } catch { return }
            finishTermination(sender, reason: "終了期限に到達しました。保存済みデータは次回起動時に回収します")
        }
        return .terminateLater
    }

    @MainActor
    private func finishTermination(_ sender: NSApplication, reason: String) {
        guard !terminationReplySent else { return }
        terminationReplySent = true
        KoeLog.ui.info("\(reason, privacy: .public)")
        sender.reply(toApplicationShouldTerminate: true)
    }
}
