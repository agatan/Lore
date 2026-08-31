import Foundation

/// 常時録音の入力levelから、後追いSTTへ渡す発話burstの境界を決める。
/// 長く話すほど短い無音で確定し、認識latencyとモデル負荷を抑える。
public struct AdaptiveSpeechSegmenter: Sendable {
    public enum Decision: Sendable, Equatable {
        case ignore
        case started
        case buffer
        case flush
    }

    public static let speechLevelThreshold: Float = 0.05
    public static let maximumBurstDuration: TimeInterval = 5 * 60

    public private(set) var isActive = false
    public private(set) var voicedDuration: TimeInterval = 0
    public private(set) var silenceDuration: TimeInterval = 0
    public private(set) var burstDuration: TimeInterval = 0

    public init() {}

    public mutating func consume(level: Float, duration: TimeInterval) -> Decision {
        let duration = max(0, duration)
        let isSpeech = level >= Self.speechLevelThreshold
        guard isActive else {
            guard isSpeech else { return .ignore }
            isActive = true
            voicedDuration = duration
            silenceDuration = 0
            burstDuration = duration
            return .started
        }

        burstDuration += duration
        if isSpeech {
            voicedDuration += duration
            silenceDuration = 0
        } else {
            silenceDuration += duration
        }

        if silenceDuration >= Self.requiredSilence(afterVoicedDuration: voicedDuration)
            || burstDuration >= Self.maximumBurstDuration {
            reset()
            return .flush
        }
        return .buffer
    }

    public mutating func finish() -> Bool {
        let hadSpeech = isActive && voicedDuration > 0
        reset()
        return hadSpeech
    }

    public static func requiredSilence(afterVoicedDuration duration: TimeInterval) -> TimeInterval {
        switch duration {
        case ..<3: 30
        case ..<10: 10
        case ..<30: 5
        default: 3
        }
    }

    private mutating func reset() {
        isActive = false
        voicedDuration = 0
        silenceDuration = 0
        burstDuration = 0
    }
}
