import Foundation

/// STTへ渡すに足る発話量が一つのburstに含まれるかを表す。
/// 一瞬の生活音をWhisperへ渡すと無音hallucinationと不要な推論負荷になるため、
/// 発話開始より強い条件を確定・previewの共通境界にする。
public struct SpeechBurstEvidence: Sendable, Equatable {
    public static let minimumVoicedDuration: TimeInterval = 0.5
    public static let minimumVoicedRatio = 0.2

    public let voicedDuration: TimeInterval
    public let burstDuration: TimeInterval
    public let peakSpeechLevel: Float

    public var voicedRatio: Double {
        guard burstDuration > 0 else { return 0 }
        return min(1, voicedDuration / burstDuration)
    }

    public var isTranscriptionCandidate: Bool {
        voicedDuration + 0.000_001 >= Self.minimumVoicedDuration
            && voicedRatio + 0.000_001 >= Self.minimumVoicedRatio
    }
}

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
    public private(set) var peakSpeechLevel: Float = 0
    public private(set) var completedBurstEvidence: SpeechBurstEvidence?
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
            peakSpeechLevel = candidateMaximum
            completedBurstEvidence = nil
            resetCandidate()
            return .started
        }

        burstDuration += duration
        if considersSpeech(level: level) {
            voicedDuration += duration
            silenceDuration = 0
            peakSpeechLevel = max(peakSpeechLevel, level)
        } else {
            silenceDuration += duration
        }

        if silenceDuration >= Self.requiredSilence(afterVoicedDuration: voicedDuration)
            || burstDuration >= Self.maximumBurstDuration {
            completedBurstEvidence = currentBurstEvidence
            reset()
            return .flush
        }
        return .buffer
    }

    public mutating func finish() -> Bool {
        let hadSpeech = isActive && voicedDuration > 0
        completedBurstEvidence = hadSpeech ? currentBurstEvidence : nil
        reset()
        return hadSpeech
    }

    public var currentBurstEvidence: SpeechBurstEvidence? {
        guard isActive else { return nil }
        return SpeechBurstEvidence(
            voicedDuration: voicedDuration,
            burstDuration: burstDuration,
            peakSpeechLevel: peakSpeechLevel
        )
    }

    public func considersSpeech(level: Float) -> Bool {
        level >= speechThreshold
    }

    public static func requiredSilence(afterVoicedDuration duration: TimeInterval) -> TimeInterval {
        switch duration {
        case ..<30: 1.5
        default: 1
        }
    }

    private mutating func reset() {
        isActive = false
        voicedDuration = 0
        silenceDuration = 0
        burstDuration = 0
        peakSpeechLevel = 0
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
