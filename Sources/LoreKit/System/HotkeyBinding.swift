import Foundation

/// 修飾キー単体をホットキーに使う場合の対象。
public enum ModifierKey: String, Codable, Sendable, CaseIterable, Identifiable {
    case fn
    case rightOption
    case leftOption
    case rightCommand
    case rightControl
    case rightShift

    public var id: String { rawValue }

    public var keyCode: UInt16 {
        switch self {
        case .fn: 63
        case .rightOption: 61
        case .leftOption: 58
        case .rightCommand: 54
        case .rightControl: 62
        case .rightShift: 60
        }
    }

    /// CGEventFlags のデバイス依存ビット。左右を厳密に見分けるために使う。
    public var deviceFlagBit: UInt64 {
        switch self {
        case .fn: 0x0080_0000        // maskSecondaryFn(左右の区別なし)
        case .rightOption: 0x0000_0040
        case .leftOption: 0x0000_0020
        case .rightCommand: 0x0000_0010
        case .rightControl: 0x0000_2000
        case .rightShift: 0x0000_0004
        }
    }

    public var displayName: String {
        switch self {
        case .fn: "fn"
        case .rightOption: String(lore: "右 ⌥")
        case .leftOption: String(lore: "左 ⌥")
        case .rightCommand: String(lore: "右 ⌘")
        case .rightControl: String(lore: "右 ⌃")
        case .rightShift: String(lore: "右 ⇧")
        }
    }
}

/// ホットキーの割り当て。
///
/// 修飾キー単体は flagsChanged で、通常キーは keyDown/keyUp で扱う。
/// 通常キーはイベントを飲み込めるが、修飾キー単体は他アプリの操作を壊すので素通しする。
public enum HotkeyBinding: Codable, Sendable, Hashable {
    case modifier(ModifierKey)
    case key(code: UInt16, modifiers: UInt64)

    public static let `default` = HotkeyBinding.modifier(.rightOption)

    public var displayName: String {
        switch self {
        case .modifier(let key):
            key.displayName
        case .key(let code, let modifiers):
            Self.modifierSymbols(modifiers) + (Self.keyName(code) ?? String(lore: "キー\(Int(code))"))
        }
    }

    /// 通常キーのときだけイベントを消費する。
    public var consumesEvent: Bool {
        switch self {
        case .modifier: false
        case .key: true
        }
    }

    static func modifierSymbols(_ flags: UInt64) -> String {
        var out = ""
        if flags & 0x0004_0000 != 0 { out += "⌃" }
        if flags & 0x0008_0000 != 0 { out += "⌥" }
        if flags & 0x0002_0000 != 0 { out += "⇧" }
        if flags & 0x0010_0000 != 0 { out += "⌘" }
        return out
    }

    static func keyName(_ code: UInt16) -> String? {
        switch code {
        case 0x24: "↩"
        case 0x30: "⇥"
        case 0x31: String(lore: "スペース")
        case 0x33: "⌫"
        case 0x35: "esc"
        case 0x60: "F5"
        case 0x61: "F6"
        case 0x62: "F7"
        case 0x64: "F8"
        case 0x65: "F9"
        case 0x6D: "F10"
        case 0x67: "F11"
        case 0x6F: "F12"
        case 0x69: "F13"
        case 0x6B: "F14"
        case 0x71: "F15"
        case 0x6A: "F16"
        case 0x40: "F17"
        case 0x4F: "F18"
        case 0x50: "F19"
        default: letters[code]
        }
    }

    static let letters: [UInt16: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G",
        0x04: "H", 0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N",
        0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T", 0x20: "U",
        0x09: "V", 0x0D: "W", 0x07: "X", 0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5",
        0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
    ]
}
