import AppKit
import SwiftUI

/// Memoの入力欄の下に出す操作のヒント。入力した文字と見分けられるよう、本文より小さく薄くする。
struct MemoKeyHint: View {
    var text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: LoreTheme.TextSize.micro))
            // Glassの上では階層の色（.tertiary）が濃く描かれることがあるため、濃さを直接決める。
            .foregroundStyle(Color.primary.opacity(0.4))
            .lineLimit(1)
    }
}

extension View {
    /// Shift-Returnで改行する。Returnだけの時は`onSubmit`に任せる。
    func memoShiftReturnInsertsNewline() -> some View {
        onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.shift) else { return .ignored }
            // 入力中のfield editorへ送り、cursorの位置に改行を入れる。
            NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
            return .handled
        }
    }
}
