import AppKit
import SwiftUI

/// アプリ本体。Dock アイコンを持たないメニューバー常駐アプリ(FR-8.1)。
public struct LoreApp: App {
    @NSApplicationDelegateAdaptor(LoreApplicationDelegate.self) private var applicationDelegate
    @State private var env = AppEnvironment()

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(env: env)
                .environment(\.locale, env.settings.applicationLanguage.resolvedLocale())
        } label: {
            MenuBarLabel(coordinator: env.coordinator, lifeLog: env.lifeLog, settings: env.settings)
        }
        .menuBarExtraStyle(.window)
        .commands { LoreCommands(env: env) }
    }
}

private struct LoreCommands: Commands {
    var env: AppEnvironment

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("設定…") {
                env.onShowSettings?(.common)
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

public enum LoreWindow {
    public static let main = "lore.main"
    public static let settings = "lore.settings"
    public static let lifeLogMini = "lore.life-log-mini"
}

/// `NSApp.terminate`、Cmd+Q、システム終了を同じ非同期の保存境界へ集約する。
final class LoreApplicationDelegate: NSObject, NSApplicationDelegate {
    static let terminationDeadline: Duration = .seconds(20)
    private var terminationInProgress = false
    private var terminationReplySent = false
    private var windowPresenter: LoreWindowPresenter?
    private var hudController: HudController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // MenuBarExtraやwindowの生成順にruntime serviceの開始を依存させない。
        // Hotkey monitorはapp processの起動と同時に必ずbootする。
        Task { @MainActor in
            guard let environment = AppEnvironment.current else {
                LoreLog.ui.error("起動時にAppEnvironmentを取得できませんでした")
                return
            }
            let presenter = LoreWindowPresenter(env: environment)
            windowPresenter = presenter
            environment.onShowMainWindow = { [weak presenter] in presenter?.showMain() }
            environment.onToggleLifeLogMiniWindow = { [weak presenter] in presenter?.toggleLifeLogMini() }
            environment.onShowSettings = { [weak presenter] section in presenter?.showSettings(section) }

            let hud = HudController(coordinator: environment.coordinator, settings: environment.settings)
            hud.start()
            hudController = hud

            if let section = AppEnvironment.uiTestSettingsSection {
                presenter.showSettings(section)
            } else {
                environment.mainSection = .lifeLog
                presenter.showMain()
            }
            await environment.boot()
#if DEBUG
            if let directory = DebugSnapshotter.outputDirectory {
                await DebugSnapshotter.run(env: environment, presenter: presenter, into: directory)
            }
            if let directory = DebugRecorder.outputDirectory {
                await DebugRecorder.run(env: environment, presenter: presenter, into: directory)
            }
#endif
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        guard let environment = AppEnvironment.current, environment.hasPendingTerminationWork else {
            LoreLog.ui.info("保留中の処理がないためLoreを直ちに終了します")
            return .terminateNow
        }

        terminationInProgress = true
        LoreLog.ui.info("保留中の処理を確定してからLoreを終了します")
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
        LoreLog.ui.info("\(reason, privacy: .public)")
        sender.reply(toApplicationShouldTerminate: true)
    }
}
