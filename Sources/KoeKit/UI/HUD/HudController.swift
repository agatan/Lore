import AppKit
import Observation
import SwiftUI

/// HUD の表示・非表示と位置決め。
///
/// フォーカスを奪わないことが要件(FR-8.2)なので、非アクティブ化パネルを使い、
/// キー入力は受け取らない。Esc は既存のイベントタップ側で拾う。
@MainActor
final class HudController {
    private let coordinator: DictationCoordinator
    private let settings: AppSettings
    private var panel: NSPanel?
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
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
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
            rootView: HudView(coordinator: coordinator) { [weak self] in
                self?.coordinator.cancel()
            }
        )
        hosting.sizingOptions = [.preferredContentSize]

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 468, height: 120),
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

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.reposition(panel)
            }
        }

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
