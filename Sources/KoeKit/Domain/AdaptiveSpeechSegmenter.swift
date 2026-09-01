import Foundation

/// 常時録音の入力levelから、背景noiseとの差がある発話burstだけを後追いSTTへ渡す。
public struct AdaptiveSpeechSegmenter: Sendable {
    public enum Decision: Sendable, Equatable {
        case ignore
        case started
        case buffer
        case flush
    }

    public static let minimumSpeechLevel: Float = 0.015
    public static let minimumRiseAboveNoise: Float = 0.012
    public static let speechToNoiseRatio: Float = 1.6
    public static let calibrationDuration: TimeInterval = 1
    public static let onsetDuration: TimeInterval = 0.25
    public static let backgroundAdaptationDuration: TimeInterval = 1
    public static let maximumBurstDuration: TimeInterval = 5 * 60

    public private(set) var isActive = false
    public private(set) var noiseFloor: Float = 0.01
    public private(set) var speechThreshold: Float = 0.025
    public private(set) var voicedDuration: TimeInterval = 0
    public private(set) var silenceDuration: TimeInterval = 0
    public private(set) var burstDuration: TimeInterval = 0
    private var calibratedDuration: TimeInterval = 0
    private var candidateDuration: TimeInterval = 0
    private var candidateMinimum: Float = .greatestFiniteMagnitude
    private var candidateMaximum: Float = 0
    private var candidateWeightedLevel: Double = 0

    public init() {}

    public mutating func consume(level: Float, duration: TimeInterval) -> Decision {
        let duration = max(0, duration)
        let level = max(0, level)
        guard isActive else {
            if calibratedDuration + 0.000_001 < Self.calibrationDuration {
                updateNoiseFloor(with: level, duration: duration, timeConstant: 0.5)
                calibratedDuration += duration
                updateSpeechThreshold()
                return .ignore
            }
            guard level >= speechThreshold else {
                resetCandidate()
                updateNoiseFloor(with: level, duration: duration, timeConstant: 8)
                updateSpeechThreshold()
                return .ignore
            }

            candidateDuration += duration
            candidateMinimum = min(candidateMinimum, level)
            candidateMaximum = max(candidateMaximum, level)
            candidateWeightedLevel += Double(level) * duration
            let modulation = candidateMaximum - candidateMinimum
            let requiredModulation = max(0.004, noiseFloor * 0.2)
            if candidateDuration + 0.000_001 < Self.onsetDuration || modulation < requiredModulation {
                if candidateDuration + 0.000_001 >= Self.backgroundAdaptationDuration {
                    noiseFloor = Float(candidateWeightedLevel / candidateDuration)
                    updateSpeechThreshold()
                    resetCandidate()
                }
                return .ignore
            }

            isActive = true
            voicedDuration = candidateDuration
            silenceDuration = 0
            burstDuration = candidateDuration
            resetCandidate()
            return .started
        }

        burstDuration += duration
        if considersSpeech(level: level) {
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

    public func considersSpeech(level: Float) -> Bool {
        level >= speechThreshold
    }

    public static func requiredSilence(afterVoicedDuration duration: TimeInterval) -> TimeInterval {
        switch duration {
        case ..<3: 8
        case ..<10: 5
        case ..<30: 3
        default: 2
        }
    }

    private mutating func reset() {
        isActive = false
        voicedDuration = 0
        silenceDuration = 0
        burstDuration = 0
        resetCandidate()
        updateSpeechThreshold()
    }

    private mutating func updateNoiseFloor(with level: Float, duration: TimeInterval, timeConstant: TimeInterval) {
        let alpha = Float(min(1, duration / max(0.001, timeConstant)))
        noiseFloor += (level - noiseFloor) * alpha
    }

    private mutating func updateSpeechThreshold() {
        speechThreshold = max(
            Self.minimumSpeechLevel,
            noiseFloor + Self.minimumRiseAboveNoise,
            noiseFloor * Self.speechToNoiseRatio
        )
    }

    private mutating func resetCandidate() {
        candidateDuration = 0
        candidateMinimum = .greatestFiniteMagnitude
        candidateMaximum = 0
        candidateWeightedLevel = 0
    }
}
