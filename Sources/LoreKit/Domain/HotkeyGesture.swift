import Foundation

/// ホットキーの物理イベント。
public enum HotkeyPhysicalEvent: Sendable, Equatable {
    case pressed
    case released(heldFor: Duration)
}

/// ホットキーから導かれる操作意図。
public enum HotkeyIntent: Sendable, Equatable {
    case start(DictationTrigger)
    case stopAndProcess
    case ignore
}

/// 短押し = トグル / 長押し = push-to-talk のハイブリッド判定(FR-1.2 / FR-1.3)。
///
/// 押した瞬間に必ず録音を開始する(FR-1.1 のレイテンシ目標 ≤100ms を満たすため)。
/// トグルか PTT かは「離すまでの保持時間」で事後的に決まる。
public struct HotkeyGestureInterpreter: Sendable {
    public var holdThreshold: Duration

    public init(holdThreshold: Duration = .milliseconds(300)) {
        self.holdThreshold = holdThreshold
    }

    /// - Parameters:
    ///   - isRecording: 現在録音中か
    ///   - pressStartedSession: いま離そうとしている押下が、その録音を開始した押下か
    public func intent(
        for event: HotkeyPhysicalEvent,
        isRecording: Bool,
        pressStartedSession: Bool
    ) -> HotkeyIntent {
        switch event {
        case .pressed:
            // 録音中の再押下は停止(トグル)。それ以外は即座に録音開始。
            return isRecording ? .stopAndProcess : .start(.toggle)

        case .released(let heldFor):
            guard isRecording, pressStartedSession else { return .ignore }
            // 閾値以上保持していたら push-to-talk として離した瞬間に停止。
            // 閾値未満ならトグル開始だったので録音を続ける。
            return heldFor >= holdThreshold ? .stopAndProcess : .ignore
        }
    }

    /// 停止時に履歴へ記録するトリガー種別。
    public func trigger(forHeldFor heldFor: Duration) -> DictationTrigger {
        heldFor >= holdThreshold ? .pushToTalk : .toggle
    }
}
