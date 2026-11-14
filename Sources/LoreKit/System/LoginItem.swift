import Foundation
import ServiceManagement

/// ログイン時起動(FR-10.1)。登録・解除はユーザーの明示操作のみ(NFR-5)。
///
/// `SMAppService` の `status` / `register` / `unregister` はいずれも
/// Background Task Management デーモンへの**同期 XPC** で、数十〜数百 ms かかりうる。
/// そのため:
/// - **描画中(`body`)から呼ばない。** 状態は `AppEnvironment` にキャッシュした値を読む。
/// - メインスレッドを止めないよう、問い合わせ自体を別スレッドへ出す。
public enum LoginItem {
    /// ログイン項目の状態。「まだ分からない」を型で持ち、UI が false と取り違えないようにする。
    public enum State: Sendable, Equatable {
        case unknown
        case enabled
        case disabled
        /// 登録はできたが、システム設定でユーザーの承認待ち。
        case requiresApproval

        public var isEnabled: Bool { self == .enabled }
    }

    /// 現在の状態を問い合わせる。所要時間はログに残す(体感の遅さを後から追えるようにする)。
    public static func currentState() async -> State {
        let started = ContinuousClock.now
        let state = await Task.detached(priority: .userInitiated) { () -> State in
            switch SMAppService.mainApp.status {
            case .enabled: .enabled
            case .requiresApproval: .requiresApproval
            default: .disabled
            }
        }.value
        logElapsed("状態取得", since: started)
        return state
    }

    /// 登録・解除して、反映後の状態を返す。
    public static func setEnabled(_ enabled: Bool) async throws -> State {
        let started = ContinuousClock.now
        try await Task.detached(priority: .userInitiated) {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        }.value
        logElapsed(enabled ? "登録" : "解除", since: started)
        return await currentState()
    }

    private static func logElapsed(_ label: String, since started: ContinuousClock.Instant) {
        let duration = ContinuousClock.now - started
        let ms = duration.components.seconds * 1_000
            + duration.components.attoseconds / 1_000_000_000_000_000
        LoreLog.ui.info("ログイン項目の\(label, privacy: .public): \(ms, privacy: .public)ms")
    }
}
