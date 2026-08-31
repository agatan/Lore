import AppKit
import Testing
@testable import KoeKit

@Suite("Menu bar status icon")
@MainActor
struct MenuBarStatusIconTests {
    @Test("LifeLog録音中はKoeアイコン右下に録音色バッジを重ねる")
    func lifeLogRecordingBadge() throws {
        let baseIcon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }

        let image = MenuBarStatusIcon.lifeLogRecording(baseIcon: baseIcon)
        #expect(image.size == NSSize(width: 24, height: 20))
        #expect(!image.isTemplate)

        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let iconColor = try #require(bitmap.colorAt(x: 9, y: 10)?.usingColorSpace(.deviceRGB))
        #expect(iconColor.blueComponent > iconColor.redComponent)

        let badgeColor = try #require(bitmap.colorAt(x: 18, y: 14)?.usingColorSpace(.deviceRGB))
        #expect(badgeColor.redComponent > badgeColor.blueComponent)
    }
}
