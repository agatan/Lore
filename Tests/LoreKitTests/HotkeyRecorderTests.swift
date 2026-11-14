import Testing

@testable import LoreKit

/// ホットキー記録の判定。
///
/// ⌥D を押すと ⌥ の flagsChanged が先に来る。そこで確定してしまうと
/// **組み合わせを一切設定できなくなる**ので、修飾キーは保留して通常キーを待つ。
@Suite("ホットキーの記録")
struct HotkeyRecorderTests {
    static let leftOptionCode = ModifierKey.leftOption.keyCode
    static let leftOptionDeviceBit = ModifierKey.leftOption.deviceFlagBit
    static let optionFlag: UInt64 = 0x0008_0000
    static let shiftFlag: UInt64 = 0x0002_0000
    static let keyD: UInt16 = 0x02
    static let f13: UInt16 = 0x69

    @Test("⌥ を押した時点では確定しない")
    func modifierAloneWaits() {
        var recorder = HotkeyRecorder()
        let step = recorder.modifierChanged(
            keyCode: Self.leftOptionCode,
            flags: Self.optionFlag | Self.leftOptionDeviceBit
        )
        #expect(step == .waiting)
        #expect(recorder.pendingModifier == .leftOption)
    }

    @Test("⌥ に続けて D を押すと ⌥D になる")
    func capturesCombination() {
        var recorder = HotkeyRecorder()
        _ = recorder.modifierChanged(
            keyCode: Self.leftOptionCode,
            flags: Self.optionFlag | Self.leftOptionDeviceBit
        )
        let step = recorder.keyDown(keyCode: Self.keyD, flags: Self.optionFlag)
        #expect(step == .captured(.key(code: Self.keyD, modifiers: Self.optionFlag)))
        #expect(recorder.pendingModifier == nil)
    }

    @Test("⌥ を押して離しただけなら修飾キー単体になる")
    func capturesModifierOnlyOnRelease() {
        var recorder = HotkeyRecorder()
        _ = recorder.modifierChanged(
            keyCode: Self.leftOptionCode,
            flags: Self.optionFlag | Self.leftOptionDeviceBit
        )
        // 離上: デバイスビットが落ちる
        let step = recorder.modifierChanged(keyCode: Self.leftOptionCode, flags: 0)
        #expect(step == .captured(.modifier(.leftOption)))
    }

    @Test("複数の修飾キーを含む組み合わせも記録できる")
    func capturesMultipleModifiers() {
        var recorder = HotkeyRecorder()
        _ = recorder.modifierChanged(
            keyCode: Self.leftOptionCode,
            flags: Self.optionFlag | Self.leftOptionDeviceBit
        )
        let step = recorder.keyDown(keyCode: Self.keyD, flags: Self.optionFlag | Self.shiftFlag)
        #expect(step == .captured(.key(code: Self.keyD, modifiers: Self.optionFlag | Self.shiftFlag)))
    }

    /// 文字キー単体はイベントタップに食われて二度と打てなくなる。
    @Test("修飾キー無しの文字キーは受け付けない")
    func rejectsBarePrintableKey() {
        var recorder = HotkeyRecorder()
        let step = recorder.keyDown(keyCode: Self.keyD, flags: 0)
        guard case .rejected = step else {
            Issue.record("D 単体を受け付けてしまうと D が打てなくなる: \(step)")
            return
        }
    }

    @Test("ファンクションキーは単体でも受け付ける")
    func allowsStandaloneFunctionKey() {
        var recorder = HotkeyRecorder()
        let step = recorder.keyDown(keyCode: Self.f13, flags: 0)
        #expect(step == .captured(.key(code: Self.f13, modifiers: 0)))
    }

    @Test("esc は割り当てない(記録の取り消しに使う)")
    func ignoresEscape() {
        var recorder = HotkeyRecorder()
        #expect(recorder.keyDown(keyCode: HotkeyRecorder.escapeKeyCode, flags: 0) == .ignored)
    }

    /// 左 ⌘ などは単体割り当ての対象にしていないが、組み合わせの一部としては使える。
    @Test("対象外の修飾キーは保留にしないが組み合わせには乗る")
    func unmodelledModifierStillCombines() {
        var recorder = HotkeyRecorder()
        let commandFlag: UInt64 = 0x0010_0000
        #expect(recorder.modifierChanged(keyCode: 55 /* 左 ⌘ */, flags: commandFlag) == .ignored)
        #expect(recorder.pendingModifier == nil)
        let step = recorder.keyDown(keyCode: Self.keyD, flags: commandFlag)
        #expect(step == .captured(.key(code: Self.keyD, modifiers: commandFlag)))
    }
}
