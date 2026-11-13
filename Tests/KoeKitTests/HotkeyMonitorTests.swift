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

    private func keyEvent(code: UInt16, keyDown: Bool, flags: UInt64) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: keyDown)!
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

    @Test("Optionだけを伴う組み合わせだけ入力監視を要求する")
    func requiresInputMonitoringForOptionOnlyCombination() {
        #expect(HotkeyMonitor.requiresInputMonitoring(modifiers: Self.optionFlag))
        #expect(HotkeyMonitor.requiresInputMonitoring(modifiers: Self.optionFlag | Self.shiftFlag))
        #expect(!HotkeyMonitor.requiresInputMonitoring(modifiers: Self.controlFlag | Self.optionFlag))
        #expect(!HotkeyMonitor.requiresInputMonitoring(modifiers: Self.commandFlag | Self.optionFlag))
    }

    @Test("Option文字keyの押下と離上を消費する")
    func optionKeyBindingConsumesPressAndRelease() {
        let monitor = HotkeyMonitor()
        monitor.update(binding: .key(code: 2, modifiers: Self.optionFlag))

        let down = monitor.handle(
            type: .keyDown,
            event: keyEvent(code: 2, keyDown: true, flags: Self.optionFlag)
        )
        let up = monitor.handle(
            type: .keyUp,
            event: keyEvent(code: 2, keyDown: false, flags: Self.optionFlag)
        )

        #expect(down == nil)
        #expect(up == nil)
    }

    @Test("同じ押下が二つの監視経路から届いても一度だけ通知する")
    func duplicateOptionKeyDeliveryIsDeduplicated() async {
        let monitor = HotkeyMonitor()
        monitor.update(binding: .key(code: 2, modifiers: Self.optionFlag))

        final class Box { var events: [HotkeyPhysicalEvent] = [] }
        let box = Box()
        monitor.onEvent = { box.events.append($0) }

        let down = keyEvent(code: 2, keyDown: true, flags: Self.optionFlag)
        _ = monitor.handle(type: .keyDown, event: down)
        _ = monitor.handle(type: .keyDown, event: down)
        await Task.yield()
        #expect(box.events.count == 1)

        let up = keyEvent(code: 2, keyDown: false, flags: Self.optionFlag)
        _ = monitor.handle(type: .keyUp, event: up)
        _ = monitor.handle(type: .keyUp, event: up)
        await Task.yield()
        #expect(box.events.count == 2)
    }

    @Test("録音中のEscをevent tapで消費する")
    func escapeIsConsumedWhileRecording() {
        let monitor = HotkeyMonitor()
        monitor.update(binding: .key(code: 2, modifiers: Self.optionFlag))
        monitor.shouldSwallowEscape = { true }

        let result = monitor.handle(type: .keyDown, event: keyEvent(code: 0x35, keyDown: true, flags: 0))

        #expect(result == nil)
    }

    @Test("録音中でなければEscを素通しする")
    func escapePassesThroughWhileIdle() {
        let monitor = HotkeyMonitor()
        monitor.update(binding: .key(code: 2, modifiers: Self.optionFlag))
        monitor.shouldSwallowEscape = { false }

        let result = monitor.handle(type: .keyDown, event: keyEvent(code: 0x35, keyDown: true, flags: 0))

        #expect(result != nil)
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
