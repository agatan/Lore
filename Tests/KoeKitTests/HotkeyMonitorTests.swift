import CoreGraphics
import Testing

@testable import KoeKit

/// イベントタップの消費判定。
///
/// ⌥D のように文字を生むキーを割り当てたとき、イベントを取りこぼすと
/// その文字(∂)が前面アプリに入力されてしまう(C-57)。
@MainActor
@Suite("ホットキーのイベント消費")
struct HotkeyMonitorTests {
    static let optionFlag: UInt64 = 0x0008_0000
    static let controlFlag: UInt64 = 0x0004_0000
    static let shiftFlag: UInt64 = 0x0002_0000
    static let commandFlag: UInt64 = 0x0010_0000
    static let keyD: UInt16 = 0x02

    private func keyEvent(_ code: UInt16, down: Bool, flags: UInt64) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = CGEventFlags(rawValue: flags)
        return event
    }

    @Test("CGEventの修飾キーを登録型hotkeyへ変換する")
    func convertsModifiersForRegisteredHotKey() {
        #expect(HotkeyMonitor.carbonModifiers(from: Self.controlFlag | Self.optionFlag) == 0x1800)
        #expect(HotkeyMonitor.carbonModifiers(from: Self.shiftFlag | Self.commandFlag) == 0x0300)
        #expect(HotkeyMonitor.carbonModifiers(from: 0) == 0)
    }

    @Test("⌥D を割り当てたら押下・離上の両方を飲み込む")
    func swallowsBoundKeyEvents() {
        let monitor = HotkeyMonitor()
        monitor.update(binding: .key(code: Self.keyD, modifiers: Self.optionFlag))

        let down = monitor.handle(type: .keyDown, event: keyEvent(Self.keyD, down: true, flags: Self.optionFlag))
        #expect(down == nil, "押下を飲み込まないと ∂ が入力される")

        let up = monitor.handle(type: .keyUp, event: keyEvent(Self.keyD, down: false, flags: Self.optionFlag))
        #expect(up == nil, "離上を飲み込まないと ∂ が入力される")
    }

    @Test("修飾キーが揃っていない D の押下と離上は素通しする")
    func passesThroughWithoutModifier() async {
        let monitor = HotkeyMonitor()
        monitor.update(binding: .key(code: Self.keyD, modifiers: Self.optionFlag))
        final class Box { var events: [HotkeyPhysicalEvent] = [] }
        let box = Box()
        monitor.onEvent = { box.events.append($0) }

        let down = monitor.handle(type: .keyDown, event: keyEvent(Self.keyD, down: true, flags: 0))
        let up = monitor.handle(type: .keyUp, event: keyEvent(Self.keyD, down: false, flags: 0))
        #expect(down != nil, "⌥ 無しの D の押下は普通に入力できなければならない")
        #expect(up != nil, "成立した押下がない離上からhotkeyを発火してはいけない")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(box.events.isEmpty)
    }

    @Test("関係ないキーは素通しする")
    func passesThroughOtherKeys() {
        let monitor = HotkeyMonitor()
        monitor.update(binding: .key(code: Self.keyD, modifiers: Self.optionFlag))
        let result = monitor.handle(type: .keyDown, event: keyEvent(0x00, down: true, flags: Self.optionFlag))
        #expect(result != nil)
    }

    /// タップのコールバックは即座に返さなければならない。
    /// ここで通知を同期実行すると、その処理時間ぶんタップが遅れ、
    /// OS がタップを無効化して以降のキーが素通しする(= ∂ が入力される)。
    @Test("通知はコールバックの中で同期実行しない")
    func notifiesAsynchronously() {
        let monitor = HotkeyMonitor()
        monitor.update(binding: .key(code: Self.keyD, modifiers: Self.optionFlag))

        final class Box { var called = false }
        let box = Box()
        monitor.onEvent = { _ in box.called = true }

        _ = monitor.handle(type: .keyDown, event: keyEvent(Self.keyD, down: true, flags: Self.optionFlag))
        #expect(box.called == false, "コールバック内で同期実行するとタップが無効化される")
    }

    /// 設定画面でホットキーを記録している間は、押したキーで録音が始まってはいけない。
    @Test("一時停止中は解釈も消費もしない")
    func suspendedPassesEverythingThrough() {
        let monitor = HotkeyMonitor()
        monitor.update(binding: .key(code: Self.keyD, modifiers: Self.optionFlag))

        final class Box { var called = false }
        let box = Box()
        monitor.onEvent = { _ in box.called = true }
        monitor.shouldSwallowEscape = { true }

        monitor.setSuspended(true)
        let down = monitor.handle(type: .keyDown, event: keyEvent(Self.keyD, down: true, flags: Self.optionFlag))
        #expect(down != nil, "一時停止中は消費しない")
        #expect(box.called == false, "一時停止中は録音を始めない")

        // esc も飲み込まない(記録の取り消しはローカルモニタ側の仕事)。
        let esc = monitor.handle(type: .keyDown, event: keyEvent(0x35, down: true, flags: 0))
        #expect(esc != nil)

        // 再開したら元どおり消費する。
        monitor.setSuspended(false)
        let resumed = monitor.handle(type: .keyDown, event: keyEvent(Self.keyD, down: true, flags: Self.optionFlag))
        #expect(resumed == nil)
    }

    @Test("修飾キー単体の割り当ては素通しする")
    func modifierBindingPassesThrough() {
        let monitor = HotkeyMonitor()
        monitor.update(binding: .modifier(.rightOption))
        let event = CGEvent(keyboardEventSource: nil, virtualKey: ModifierKey.rightOption.keyCode, keyDown: true)!
        event.flags = CGEventFlags(rawValue: ModifierKey.rightOption.deviceFlagBit)
        let result = monitor.handle(type: .flagsChanged, event: event)
        #expect(result != nil, "修飾キーは他アプリの操作に必要なので消費しない")
    }
}
