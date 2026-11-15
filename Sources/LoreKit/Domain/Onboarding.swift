import Foundation

public enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome
    case tryDictation
    case ready
}

/// 初回案内で音声入力を試せない理由。足りない権限ごとに一つ。
public enum OnboardingDictationBlocker: Sendable, Equatable {
    case microphone
    case accessibility

    public static func missing(microphone: Bool, accessibility: Bool) -> [OnboardingDictationBlocker] {
        var blockers: [OnboardingDictationBlocker] = []
        if !microphone { blockers.append(.microphone) }
        if !accessibility { blockers.append(.accessibility) }
        return blockers
    }
}
