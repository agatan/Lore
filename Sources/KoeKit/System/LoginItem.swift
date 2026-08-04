import Foundation
import ServiceManagement

/// ログイン時起動(FR-10.1)。登録・解除はユーザーの明示操作のみ(NFR-5)。
@MainActor
public enum LoginItem {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// - Returns: 実際に反映できたか。`requiresApproval` のときはシステム設定での承認待ち。
    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    public static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }
}
