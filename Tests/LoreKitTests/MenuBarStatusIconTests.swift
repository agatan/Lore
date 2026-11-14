import AppKit
import Testing
@testable import LoreKit

@Suite("Menu bar status icon")
@MainActor
struct MenuBarStatusIconTests {
    @Test("LifeLog録音中はmonochrome Lore mark右下にrose badgeを重ねる")
    func lifeLogRecordingBadge() throws {
        let image = MenuBarStatusIcon.lifeLogRecording()
        #expect(image.size == NSSize(width: 24, height: 20))
        #expect(!image.isTemplate)

        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let iconColor = try #require(bitmap.colorAt(x: 9, y: 10)?.usingColorSpace(.deviceRGB))
        #expect(abs(iconColor.redComponent - iconColor.greenComponent) < 0.03)
        #expect(abs(iconColor.greenComponent - iconColor.blueComponent) < 0.03)

        let badgeColor = try #require(bitmap.colorAt(x: 18, y: 14)?.usingColorSpace(.deviceRGB))
        #expect(badgeColor.redComponent > badgeColor.blueComponent)
    }

    @Test("点のない待機中はtemplate画像にしてmenu barの明暗に任せる")
    func idleIsTemplate() {
        #expect(MenuBarStatusIcon.image(badge: nil).isTemplate)
        #expect(!MenuBarStatusIcon.image(badge: .processing).isTemplate)
    }

    @Test("入力levelを渡すと棒の高さを置き換え、足りない分は無音として左を埋める")
    func liveBars() {
        #expect(MenuBarStatusIcon.barHeights(levels: nil) == MenuBarStatusIcon.markHeights)
        let heights = MenuBarStatusIcon.barHeights(levels: [0, 1])
        #expect(heights.count == MenuBarStatusIcon.barCount)
        #expect(heights.first == 3)
        #expect(heights.last == 17)
    }

    @Test("音声入力の状態ごとに点の色を決め、待機中と取消は点を出さない")
    func badgeForPhase() {
        let lifeLog = LifeLogCoordinator()
        #expect(MenuBarStatusIcon.badge(phase: .idle, lifeLog: lifeLog) == nil)
        #expect(MenuBarStatusIcon.badge(phase: .recording, lifeLog: lifeLog) == .recording)
        #expect(MenuBarStatusIcon.badge(phase: .formatting, lifeLog: lifeLog) == .processing)
        #expect(MenuBarStatusIcon.badge(phase: .finished(.completed), lifeLog: lifeLog) == .done)
        #expect(MenuBarStatusIcon.badge(phase: .finished(.clipboardOnly(reason: "x")), lifeLog: lifeLog) == .attention)
        #expect(MenuBarStatusIcon.badge(phase: .finished(.failed("x")), lifeLog: lifeLog) == .attention)
        #expect(MenuBarStatusIcon.badge(phase: .finished(.cancelled), lifeLog: lifeLog) == nil)
    }
}
