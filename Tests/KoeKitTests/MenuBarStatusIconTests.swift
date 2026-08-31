import AppKit
import Testing
@testable import KoeKit

@Suite("Menu bar status icon")
@MainActor
struct MenuBarStatusIconTests {
    @Test("LifeLog録音中はmonochrome Koe mark右下にrose badgeを重ねる")
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
}
