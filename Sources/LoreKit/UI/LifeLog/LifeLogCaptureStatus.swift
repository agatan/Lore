import SwiftUI

/// 記録状態の文言・symbol・色。Menu barとmain/miniのbarで同じ判断を使う。
@MainActor
struct LifeLogCaptureStatus {
    var lifeLog: LifeLogCoordinator
    var scheduleCaption: AppEnvironment.LifeLogScheduleCaption?

    /// 停止中は見出しだけで状態が伝わるため、同じ意味の補足を重ねない。
    /// 自動記録の時刻は停止中でも次の動きを示す情報なので出す。
    var subtitle: LocalizedStringKey? {
        guard lifeLog.hasCaptureIntent else { return scheduleCaption?.text }
        // 再接続やボイスメモの中断は自動記録の時刻より優先して伝える。holdの間は再開の時刻を伝える。
        if lifeLog.isCapturing || lifeLog.isHeld, let scheduleCaption { return scheduleCaption.text }
        return LocalizedStringKey(lifeLog.captureStatusText)
    }

    var title: String {
        if lifeLog.isSuspendedForVoiceMemo || lifeLog.isHeld { return "ライフログ一時停止中" }
        if lifeLog.isRecoveringCapture { return "ライフログ再接続中" }
        if lifeLog.isCapturing { return "ライフログ記録中" }
        if lifeLog.hasCaptureIntent { return "ライフログ開始中" }
        return "ライフログ停止中"
    }

    var actionLabel: String {
        lifeLog.hasCaptureIntent ? "ライフログ録音を停止" : "ライフログ録音を開始"
    }
}

extension AppEnvironment.LifeLogScheduleCaption {
    var text: LocalizedStringKey {
        switch self {
        case .recordingUntil(let time): "自動記録中・\(time)まで"
        case .nextStart(let time): "次の自動記録 \(time)"
        case .resumesAt(let time): "\(time)に再開"
        case .heldForEvent(let time): "この予定中は記録しません・\(time)まで"
        }
    }
}
