import AppKit
import Testing
@testable import LoreKit

@Suite("Menu bar status icon")
@MainActor
struct MenuBarStatusIconTests {
    @Test("LifeLog録音中はmonochromeの「L」にroseの「.」を付ける")
    func lifeLogRecordingBadge() throws {
        let image = MenuBarStatusIcon.lifeLogRecording()
        #expect(image.size == NSSize(width: 22, height: 18))
        #expect(!image.isTemplate)

        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let iconColor = try #require(bitmap.colorAt(x: 5, y: 8)?.usingColorSpace(.deviceRGB))
        #expect(abs(iconColor.redComponent - iconColor.greenComponent) < 0.03)
        #expect(abs(iconColor.greenComponent - iconColor.blueComponent) < 0.03)

        let badgeColor = try #require(bitmap.colorAt(x: 17, y: 14)?.usingColorSpace(.deviceRGB))
        #expect(badgeColor.redComponent > badgeColor.blueComponent)
    }

    @Test("点のない待機中はtemplate画像にしてmenu barの明暗に任せる")
    func idleIsTemplate() {
        #expect(MenuBarStatusIcon.image(badge: nil).isTemplate)
        #expect(!MenuBarStatusIcon.image(badge: .processing).isTemplate)
    }

    @Test("入力levelで「.」が膨らみ、上限で止まる")
    func liveDot() {
        #expect(MenuBarStatusIcon.dotRadius(level: nil) == MenuBarStatusIcon.baseDotRadius)
        #expect(MenuBarStatusIcon.dotRadius(level: 0) == MenuBarStatusIcon.baseDotRadius)
        #expect(MenuBarStatusIcon.dotRadius(level: 5) == MenuBarStatusIcon.maximumDotRadius)
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
