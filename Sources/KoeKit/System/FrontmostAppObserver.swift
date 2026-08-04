import AppKit
import Foundation

/// 挿入先アプリの追跡。
///
/// 設計上は「セッション開始時に 1 回読むだけ」だが、設定・履歴ウィンドウを開くと
/// 前面アプリが Koe 自身になってしまうため、直近の「Koe 以外の前面アプリ」を覚えておく。
/// 取得するのは bundle ID とアプリ名だけで、画面内容やウィンドウ内テキストは読まない(NFR-2)。
@MainActor
public final class FrontmostAppObserver {
    public struct Target: Sendable {
        public let bundleID: String?
        public let name: String?
        public let processIdentifier: pid_t?

        public init(bundleID: String?, name: String?, processIdentifier: pid_t?) {
            self.bundleID = bundleID
            self.name = name
            self.processIdentifier = processIdentifier
        }

        public static let unknown = Target(bundleID: nil, name: nil, processIdentifier: nil)
    }

    private var lastExternal: NSRunningApplication?
    /// deinit(nonisolated)から解除するため unsafe 指定。生成・解除はどちらも 1 回だけ。
    private nonisolated(unsafe) var observer: NSObjectProtocol?
    private let selfBundleID = Bundle.main.bundleIdentifier

    public init() {
        lastExternal = NSWorkspace.shared.frontmostApplication.flatMap { isExternal($0) ? $0 : nil }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            MainActor.assumeIsolated {
                guard let self, self.isExternal(app) else { return }
                self.lastExternal = app
            }
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// 挿入先として扱うアプリ。
    public var current: NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication, isExternal(front) {
            lastExternal = front
            return front
        }
        if let lastExternal, !lastExternal.isTerminated {
            return lastExternal
        }
        return nil
    }

    public var target: Target {
        guard let app = current else { return .unknown }
        return Target(
            bundleID: app.bundleIdentifier,
            name: app.localizedName,
            processIdentifier: app.processIdentifier
        )
    }

    private func isExternal(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else { return true }
        return bundleID != selfBundleID
    }
}
