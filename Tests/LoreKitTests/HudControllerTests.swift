import AppKit
import Testing
@testable import LoreKit

@MainActor
struct HudControllerTests {
    /// 逐次textで HUD が伸び縮みしても、パネルの window frame は動かさない。
    /// 内容に合わせて frame を変えると layout の中で再入し、スタックを使い切って落ちたことがある。
    @Test func panelKeepsItsFrameWhileTheHudGrowsAndShrinks() async throws {
        _ = NSApplication.shared
        let settings = AppSettings()
        settings.hudEnabled = true
        let coordinator = DictationCoordinator(
            dependencies: .init(
                settings: settings,
                engines: EngineRegistry(),
                historyStore: { nil },
                modes: { BuiltinModes.all },
                vocabulary: { [] },
                onRecordChanged: { _ in }
            )
        )
        let hud = HudController(coordinator: coordinator, settings: settings)
        hud.start()

        coordinator.applyPreviewState(phase: .recording)
        try await Task.sleep(for: .milliseconds(300))
        let panel = try #require(hud.panel)
        #expect(panel.frame.size == HudController.panelSize)
        let shown = panel.frame

        coordinator.applyPreviewState(phase: .recording, transcript: String(repeating: "長い逐次テキスト ", count: 20))
        try await Task.sleep(for: .milliseconds(600))
        #expect(panel.frame == shown)

        coordinator.applyPreviewState(
            phase: .finished(.formattingSkipped(reason: "タイムアウト")),
            transcript: "整形前の文",
            detail: "整形をスキップしました(処理がタイムアウトしました)"
        )
        try await Task.sleep(for: .milliseconds(600))
        #expect(panel.frame.size == HudController.panelSize)

        coordinator.applyPreviewState(phase: .idle)
        try await Task.sleep(for: .milliseconds(400))
        #expect(panel.frame.size == HudController.panelSize)
    }
}
