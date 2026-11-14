import AppKit
import SwiftUI

/// `LSUIElement`でもSwiftUI sceneの生成に依存せず、各windowを一つだけ所有する。
@MainActor
final class LoreWindowPresenter {
    private let env: AppEnvironment
    private var controllers: [String: NSWindowController] = [:]

    init(env: AppEnvironment) {
        self.env = env
    }

    func showMain() {
        show(
            id: LoreWindow.main,
            title: "Lore",
            size: NSSize(width: 1_680, height: 960),
            chrome: .sidebar,
            root: AnyView(LoreWindowRoot(env: env, content: MainWindowView(env: env)))
        )
    }

    func showSettings(_ section: SettingsSection) {
        env.settingsSection = section
        show(
            id: LoreWindow.settings,
            title: String(lore: "Lore 設定"),
            size: NSSize(width: 980, height: 720),
            chrome: .sidebar,
            root: AnyView(LoreWindowRoot(env: env, content: SettingsWindowView(env: env)))
        )
    }

    func toggleLifeLogMini() {
        if let window = controllers[LoreWindow.lifeLogMini]?.window, window.isVisible {
            window.close()
            return
        }
        show(
            id: LoreWindow.lifeLogMini,
            title: String(lore: "ライフログ ミニ"),
            size: NSSize(width: 460, height: 620),
            chrome: .panel,
            root: AnyView(LoreWindowRoot(env: env, content: LifeLogMiniWindow(env: env)))
        )
        env.applyLifeLogMiniWindowLevel()
    }

    /// Windowの枠の作り。
    enum Chrome {
        case standard
        /// 全高sidebarとunified toolbarを持つsplit view window。
        case sidebar
        /// Title barを持たず、content全体を半透明素材で描く小窓。
        case panel
    }

    private func show(
        id: String,
        title: String,
        size: NSSize,
        chrome: Chrome = .standard,
        root: AnyView
    ) {
        // LSUIElementのまま生成したAppKit windowは表示状態でもAX treeへ公開されない。
        // Window生成より先に通常appへ切り替え、操作可能なwindowとして登録する。
        NSApp.setActivationPolicy(.regular)
        if let controller = controllers[id], let window = controller.window {
            controller.showWindow(nil)
            activate(window)
            return
        }

        let controller = NSHostingController(rootView: root)
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if chrome != .standard { styleMask.insert(.fullSizeContentView) }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        // SwiftUIの`navigationTitle`が後から上書きできるよう、contentより先に既定のtitleを置く。
        window.title = title
        window.contentViewController = controller
        // NSHostingControllerを設定するとSwiftUIのfitting sizeへ縮むため、
        // window種別ごとの初期content sizeは設定後に確定する。
        window.setContentSize(size)
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.isReleasedWhenClosed = false
        switch chrome {
        case .standard:
            break
        case .sidebar:
            // Sidebarをtraffic lightまで伸ばし、toolbarをcontentの上に浮かべる(macOS 26の標準構成)。
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
            window.titlebarAppearsTransparent = true
        case .panel:
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
        }
        window.center()

        let windowController = NSWindowController(window: window)
        controllers[id] = windowController
        windowController.showWindow(nil)
        activate(window)
        LoreLog.ui.info("windowを表示しました: \(id, privacy: .public), visible=\(window.isVisible, privacy: .public)")
    }

    private func activate(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        // accessory -> regularの切替は同期APIでもwindow serverへの反映に時間がかかる。
        // 切替直後のactivate要求が落ちることがあるため、activeになるまで短時間だけ再要求する。
        requestActivation(of: window, attemptsRemaining: 10)
    }

    private func requestActivation(of window: NSWindow, attemptsRemaining: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak window] in
            guard let window, window.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            guard !NSApp.isActive, attemptsRemaining > 1 else { return }
            self.requestActivation(of: window, attemptsRemaining: attemptsRemaining - 1)
        }
    }
}

/// 各windowの共通の外側。表示言語を毎回`env`から読むため、設定で言語を変えると
/// 開いているwindowもその場で切り替わる（生成時のlocaleを固定しない）。
private struct LoreWindowRoot<Content: View>: View {
    var env: AppEnvironment
    var content: Content

    var body: some View {
        content
            .environment(\.locale, env.settings.applicationLanguage.resolvedLocale())
            .loreWindow()
            // Sidebarの選択やswitchはsystemの青ではなくLoreの灰色にする。
            .tint(LoreTheme.control)
            .accentColor(LoreTheme.control)
    }
}
