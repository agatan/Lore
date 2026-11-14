import AppKit
import Carbon.HIToolbox
import Foundation

/// カーソル位置への一括挿入。
///
/// ペーストボード方式を採る(設計 D-7): キーストローク合成は日本語 IME と衝突するため、
/// ⌘V が最も互換性が高い。クリップボード汚染は退避 → 復元で緩和する。
@MainActor
public enum TextInserter {
    public enum Failure: LocalizedError {
        case notTrusted
        case secureInput
        case activationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notTrusted: String(lore: "アクセシビリティの許可がないため挿入できません")
            case .secureInput: String(lore: "セキュア入力中のため挿入できません")
            case .activationFailed(let app): String(lore: "\(app) を前面に戻せませんでした")
            }
        }
    }

    /// ⌘V が処理されるのを待つ時間。短すぎると復元がペーストに割り込む。
    static let pasteSettleDelay: Duration = .milliseconds(320)
    static let activationDelay: Duration = .milliseconds(140)

    /// - Parameter target: 録音開始時に前面だったアプリ。別アプリが前面なら戻してから挿入する。
    public static func insert(_ text: String, into target: NSRunningApplication?) async throws {
        guard !text.isEmpty else { return }
        guard Permissions.isAccessibilityGranted else { throw Failure.notTrusted }
        guard !IsSecureEventInputEnabled() else { throw Failure.secureInput }

        if let target, !target.isActive, !target.isTerminated {
            target.activate()
            try? await Task.sleep(for: activationDelay)
            guard target.isActive else {
                throw Failure.activationFailed(target.localizedName ?? String(lore: "対象アプリ"))
            }
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCommandV()

        try? await Task.sleep(for: pasteSettleDelay)
        snapshot.restore(to: pasteboard)
    }

    /// 挿入に失敗したときの最終手段。結果を絶対に失わない(FR-5.3)。
    public static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitLocalMouseEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}

/// クリップボードの中身を型ごとに丸ごと退避する。
struct PasteboardSnapshot {
    private struct Item {
        var contents: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private var items: [Item]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(contents: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.compactMap { item -> NSPasteboardItem? in
            guard !item.contents.isEmpty else { return nil }
            let pasteboardItem = NSPasteboardItem()
            for content in item.contents {
                pasteboardItem.setData(content.data, forType: content.type)
            }
            return pasteboardItem
        }
        guard !restored.isEmpty else { return }
        pasteboard.writeObjects(restored)
    }
}
