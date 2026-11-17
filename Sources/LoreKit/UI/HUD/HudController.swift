import AppKit
import Observation
import SwiftUI

/// HUD の表示・非表示と位置決め。
///
/// フォーカスを奪わないことが要件(FR-8.2)なので、非アクティブ化パネルを使い、
/// キー入力は受け取らない。Esc は既存のイベントタップ側で拾う。
///
/// パネルは最も大きく伸びた形が収まる固定の大きさで作り、HUD はその中で下端・中央に寄せて描く。
/// 内容に合わせて window の frame を変えると、SwiftUI の window 寸法の追従と位置合わせが
/// layout の中で再入し、main thread のスタックを使い切って落ちたことがあるため。
@MainActor
final class HudController {
    /// 本文 3 行と終了時の注記 2 行が伸びた board に、周囲の余白 16 pt を足しても収まる大きさ。
    static let panelSize = NSSize(width: 472, height: 240)

    private let coordinator: DictationCoordinator
    private let settings: AppSettings
    private(set) var panel: NSPanel?
    private var observationTask: Task<Void, Never>?

    init(coordinator: DictationCoordinator, settings: AppSettings) {
        self.coordinator = coordinator
        self.settings = settings
    }

    func start() {
        observePhase()
    }

    /// Observation で phase の変化を追い、表示状態を同期する。
    private func observePhase() {
        withObservationTracking {
            _ = coordinator.phase
            _ = settings.hudEnabled
            _ = settings.applicationLanguage
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                sync()
                observePhase()
            }
        }
        sync()
    }

    private func sync() {
        let shouldShow = settings.hudEnabled && !isIdle
        if shouldShow {
            show()
        } else {
            hide()
        }
    }

    private var isIdle: Bool {
        coordinator.phase == .idle
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        reposition(panel)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
            WindowActivityLog.record("show", panel)
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        WindowActivityLog.record("hide", panel)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            MainActor.assumeIsolated {
                panel?.orderOut(nil)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingController(
            rootView: HudLocalizedView(coordinator: coordinator, settings: settings) { [weak self] in
                self?.coordinator.cancel()
            }
        )
        hosting.sizingOptions = []

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.identifier = NSUserInterfaceItemIdentifier("lore.hud")
        // contentViewControllerを設定するとcontentの大きさへ縮むため、設定後に固定の大きさへ戻す。
        panel.setContentSize(Self.panelSize)
        return panel
    }

    /// 画面下部中央。Dock の上あたりに置く。
    private func reposition(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 96
        )
        panel.setFrameOrigin(origin)
    }
}

private struct HudLocalizedView: View {
    var coordinator: DictationCoordinator
    var settings: AppSettings
    var onCancel: () -> Void

    var body: some View {
        HudView(coordinator: coordinator, onCancel: onCancel)
            .environment(\.locale, settings.applicationLanguage.resolvedLocale())
            // 固定の大きさのパネルの中で、capsuleの下端を画面の同じ高さに保ったまま上へ伸ばす。
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
