import AppKit
import SwiftUI

/// `LSUIElement`でもSwiftUI sceneの生成に依存せず、各windowを一つだけ所有する。
@MainActor
final class KoeWindowPresenter {
    private let env: AppEnvironment
    private var controllers: [String: NSWindowController] = [:]

    init(env: AppEnvironment) {
        self.env = env
    }

    func showMain() {
        show(
            id: KoeWindow.main,
            title: "Koe",
            size: NSSize(width: 1_480, height: 820),
            root: AnyView(
                MainWindowView(env: env)
                    .environment(\.locale, env.settings.applicationLanguage.resolvedLocale())
                    .koeWindow()
                    .tint(KoeTheme.accent)
                    .accentColor(KoeTheme.accent)
            )
        )
    }

    func showSettings(_ section: SettingsSection) {
        env.settingsSection = section
        show(
            id: KoeWindow.settings,
            title: "Koe 設定",
            size: NSSize(width: 980, height: 720),
            root: AnyView(
                SettingsWindowView(env: env)
                    .environment(\.locale, env.settings.applicationLanguage.resolvedLocale())
                    .koeWindow()
                    .tint(KoeTheme.accent)
                    .accentColor(KoeTheme.accent)
            )
        )
    }

    func toggleLifeLogMini() {
        if let window = controllers[KoeWindow.lifeLogMini]?.window, window.isVisible {
            window.close()
            return
        }
        show(
            id: KoeWindow.lifeLogMini,
            title: "ライフログ ミニ",
            size: NSSize(width: 460, height: 620),
            hiddenTitleBar: true,
            root: AnyView(
                LifeLogMiniWindow(env: env)
                    .environment(\.locale, env.settings.applicationLanguage.resolvedLocale())
                    .koeWindow()
                    .tint(KoeTheme.accent)
                    .accentColor(KoeTheme.accent)
            )
        )
        env.applyLifeLogMiniWindowLevel()
    }

    func showLifeLogTodos() {
        show(
            id: KoeWindow.lifeLogTodos,
            title: "すべてのTODO",
            size: NSSize(width: 680, height: 520),
            root: AnyView(
                LifeLogTodoManagerWindow(env: env)
                    .environment(\.locale, env.settings.applicationLanguage.resolvedLocale())
                    .koeWindow()
                    .tint(KoeTheme.accent)
                    .accentColor(KoeTheme.accent)
            )
        )
    }

    private func show(
        id: String,
        title: String,
        size: NSSize,
        hiddenTitleBar: Bool = false,
        root: AnyView
    ) {
        // LSUIElementのまま生成したAppKit windowは表示状態でもAX treeへ公開されない。
        // Window生成より先に通常appへ切り替え、操作可能なwindowとして登録する。
        NSApp.setActivationPolicy(.regular)
        if let controller = controllers[id], let window = controller.window {
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let controller = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.title = title
        window.isReleasedWhenClosed = false
        if hiddenTitleBar {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        }
        window.center()

        let windowController = NSWindowController(window: window)
        controllers[id] = windowController
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        KoeLog.ui.info("windowを表示しました: \(id, privacy: .public), visible=\(window.isVisible, privacy: .public)")
    }
}
