import AppKit
import SwiftUI

/// ウィンドウを開いている間だけ通常アプリとして振る舞わせる。
///
/// `LSUIElement` のアクセサリアプリは ⌘Tab の切替対象に入らず、Dock にも出ない。
/// 常駐中はそれが正しいが、設定・履歴ウィンドウを開いている間は切り替えられないと使いづらい。
/// そこでウィンドウの開閉に合わせて activation policy を出し入れする。
@MainActor
final class WindowActivation {
    static let shared = WindowActivation()

    private var openCount = 0

    private init() {}

    func windowAppeared() {
        openCount += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func windowDisappeared() {
        openCount = max(0, openCount - 1)
        guard openCount == 0 else { return }
        // 常駐状態に戻す(Dock アイコンと ⌘Tab から消える)。
        NSApp.setActivationPolicy(.accessory)
    }
}

extension View {
    /// Koe のウィンドウ(設定・履歴)のルートに付ける。
    func koeWindow() -> some View {
        onAppear { WindowActivation.shared.windowAppeared() }
            .onDisappear { WindowActivation.shared.windowDisappeared() }
    }
}
