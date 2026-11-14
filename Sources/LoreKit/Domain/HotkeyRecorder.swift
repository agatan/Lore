import Foundation

/// ホットキー記録の判定(純粋ドメイン)。
///
/// 難しいのは「⌥ 単体」と「⌥D」を同じ操作列から見分ける点。
/// ⌥D を押すと、まず ⌥ の `flagsChanged` が来て、そのあと D の `keyDown` が来る。
/// **最初の `flagsChanged` で確定してしまうと、組み合わせを記録できない。**
/// そこで修飾キーは「保留」にして、通常キーが続けばそちらを採る。
/// 修飾キーが押して離されただけなら、そのとき単体割り当てとして確定する。
public struct HotkeyRecorder: Sendable {
    public enum Step: Sendable, Equatable {
        /// まだ確定しない。記録を続ける。
        case waiting
        case captured(HotkeyBinding)
        /// 割り当てとして受け付けられない。理由を UI に出す。
        case rejected(String)
        case ignored
    }

    /// 修飾キーとして扱うフラグ(左右の区別なし)。
    static let modifierMask: UInt64 = 0x0004_0000 | 0x0008_0000 | 0x0002_0000 | 0x0010_0000

    /// 単体でも安全に割り当てられるキー。
    ///
    /// 文字キーを単体で割り当てると、そのキーはイベントタップに食われて
    /// **二度と入力できなくなる**。ファンクションキーだけ例外にする。
    static let standaloneKeyCodes: Set<UInt16> = [
        0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,  // F5...F12
        0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50,        // F13...F19
    ]

    static let escapeKeyCode: UInt16 = 0x35

    private static let modifierKeyCodes: [UInt16: ModifierKey] = Dictionary(
        uniqueKeysWithValues: ModifierKey.allCases.map { ($0.keyCode, $0) }
    )

    /// 押されたままの修飾キー。単体割り当ての候補。
    public private(set) var pendingModifier: ModifierKey?

    public init() {}

    /// 修飾キーの押下・離上。
    public mutating func modifierChanged(keyCode: UInt16, flags: UInt64) -> Step {
        guard let key = Self.modifierKeyCodes[keyCode] else {
            // 左 ⌘ など単体割り当ての対象にしていない修飾キー。
            // 組み合わせの一部としては flags に乗ってくるので、ここでは何もしない。
            return .ignored
        }
        let isDown = flags & key.deviceFlagBit != 0
        if isDown {
            // ここで確定させない。通常キーが続く可能性がある。
            pendingModifier = key
            return .waiting
        }
        // 押して離しただけなら単体割り当て。
        guard pendingModifier == key else {
            pendingModifier = nil
            return .ignored
        }
        pendingModifier = nil
        return .captured(.modifier(key))
    }

    /// 通常キーの押下。修飾キーが押されていれば、その組み合わせで確定する。
    public mutating func keyDown(keyCode: UInt16, flags: UInt64) -> Step {
        // esc は記録の取り消しに使うので割り当てられない。
        guard keyCode != Self.escapeKeyCode else { return .ignored }

        pendingModifier = nil
        let modifiers = flags & Self.modifierMask
        guard modifiers != 0 || Self.standaloneKeyCodes.contains(keyCode) else {
            return .rejected(String(lore: "このキーは単体では割り当てられません。⌘ ⌥ ⌃ ⇧ と組み合わせるか、F13 などを使ってください"))
        }
        return .captured(.key(code: keyCode, modifiers: modifiers))
    }

    /// 記録を始める・やめるときに呼ぶ。
    public mutating func reset() {
        pendingModifier = nil
    }
}
