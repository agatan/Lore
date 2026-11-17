import AppKit

/// Lore の全 window(main・設定・mini・menu bar panel・HUD)の出入りを unified log に残す。
///
/// AppKit や SwiftUI の layout で落ちたとき、crash report には落ちた window も、その時に開いていた
/// window も残らない。直前の window の種類と frame と画面を `log show` で辿れるようにする。
/// Window の title は利用者の内容を含みうるので出さず、識別子か class 名だけを出す。
@MainActor
enum WindowActivityLog {
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        guard observers.isEmpty else { return }
        let events: [(Notification.Name, String)] = [
            (NSWindow.didBecomeKeyNotification, "key"),
            (NSWindow.didChangeScreenNotification, "screen"),
            (NSWindow.didEndLiveResizeNotification, "resized"),
            (NSWindow.willCloseNotification, "close"),
        ]
        observers = events.map { name, event in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard let window = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated { record(event, window) }
            }
        }
    }

    static func record(_ event: String, _ window: NSWindow) {
        LoreLog.ui.notice(
            "window \(event, privacy: .public): \(name(of: window), privacy: .public) frame=\(NSStringFromRect(window.frame), privacy: .public) screen=\(window.screen?.localizedName ?? "-", privacy: .public) visible=\(window.isVisible, privacy: .public)"
        )
    }

    private static func name(of window: NSWindow) -> String {
        window.identifier?.rawValue ?? String(describing: type(of: window))
    }
}
