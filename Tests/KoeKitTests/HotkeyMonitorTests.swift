import CoreGraphics
import Testing

@testable import KoeKit

@MainActor
@Suite("グローバルホットキー")
struct HotkeyMonitorTests {
    static let optionFlag: UInt64 = 0x0008_0000
    static let controlFlag: UInt64 = 0x0004_0000
    static let shiftFlag: UInt64 = 0x0002_0000
    static let commandFlag: UInt64 = 0x0010_0000

    private func modifierEvent(_ key: ModifierKey, flags: UInt64) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key.keyCode, keyDown: flags != 0)!
        event.flags = CGEventFlags(rawValue: flags)
        return event
    }

    @Test("すべての修飾キーを登録型hotkeyへ変換する")
    func convertsModifiersForRegisteredHotKey() {
        #expect(HotkeyMonitor.carbonModifiers(from: Self.optionFlag) == 0x0800)
        #expect(HotkeyMonitor.carbonModifiers(from: Self.shiftFlag) == 0x0200)
        #expect(HotkeyMonitor.carbonModifiers(from: Self.controlFlag | Self.optionFlag) == 0x1800)
        #expect(HotkeyMonitor.carbonModifiers(from: Self.shiftFlag | Self.commandFlag) == 0x0300)
        #expect(HotkeyMonitor.carbonModifiers(from: 0) == 0)
    }

    @Test("修飾キー単体の割り当ては素通しする")
    func modifierBindingPassesThrough() {
        let monitor = HotkeyMonitor()
        monitor.update(binding: .modifier(.rightOption))
        let result = monitor.handle(
            type: .flagsChanged,
            event: modifierEvent(.rightOption, flags: ModifierKey.rightOption.deviceFlagBit)
        )
        #expect(result != nil, "修飾キーは他アプリの操作に必要なので消費しない")
    }

    @Test("一時停止中は修飾キーを解釈しない")
    func suspendedModifierPassesThroughWithoutNotification() {
        let monitor = HotkeyMonitor()
        monitor.update(binding: .modifier(.rightOption))

        final class Box { var called = false }
        let box = Box()
        monitor.onEvent = { _ in box.called = true }
        monitor.setSuspended(true)

        let result = monitor.handle(
            type: .flagsChanged,
            event: modifierEvent(.rightOption, flags: ModifierKey.rightOption.deviceFlagBit)
        )
        #expect(result != nil)
        #expect(box.called == false)
    }
}
