import AppKit
import Foundation

/// 自分自身を起動し直す。
///
/// Speech の在庫 API(`AssetInventory`)はプロセス内で一度死ぬと戻らない(C-15d)。
/// 予約も解放も再取得も何も起きなくなり、聞き取りは永久に始められない。
/// **プロセスを作り直す以外に手段が無い**ので、利用者に手作業を強いる代わりにここで畳む。
///
/// 保存していない状態は持たない(履歴も設定も DB とファイルにある)ので、
/// 起動し直しで失われるのは進行中の録音だけ。その録音はどのみち始められない。
enum AppRelauncher {
    /// 起動してからこれだけ経っていなければ、作り直しても同じだと見なす。
    ///
    /// 在庫 API が死ぬのは長時間動き続けたプロセスで、起動直後の失敗は別の原因。
    /// この下限が「直らないのに再起動を繰り返す」ループを止める唯一の歯止めになる。
    static let minimumUptime: Duration = .seconds(300)

    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        // 同じアプリが動いている間に起動するので、明示しないと前面に出るだけで終わる。
        configuration.createsNewApplicationInstance = true
        LoreLog.ui.error("音声モデルを使えなくなったため Lore を起動し直します")
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                LoreLog.ui.error("起動し直せませんでした: \(error.localizedDescription, privacy: .public)")
                return
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
