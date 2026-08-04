import AppKit
import Foundation

/// 録音の状態遷移を知らせる効果音(FR-1.5)。HUD を見ていなくても状態が分かるようにする。
///
/// システム標準音(Tink 等)はどれも主張が強く、1 日に何十回も鳴らす用途には向かない。
/// ごく短い正弦波を自前で合成し、フェードを付けて「気配」程度の音にする。
@MainActor
public final class SoundPlayer {
    public enum Cue: CaseIterable {
        case start
        case stop
        case complete
        case cancel
        case failure

        /// (周波数, 長さ, 相対音量)。上向きは開始・完了、下向きは停止・中止。
        var tones: [(frequency: Double, seconds: Double, gain: Double)] {
            switch self {
            case .start: [(784, 0.045, 0.5)]
            case .stop: [(587, 0.04, 0.35)]
            case .complete: [(784, 0.035, 0.32), (1_047, 0.055, 0.42)]
            case .cancel: [(494, 0.05, 0.3)]
            case .failure: [(392, 0.07, 0.4), (294, 0.09, 0.4)]
            }
        }
    }

    public var isEnabled = true
    /// 0...1。既定は控えめに。
    public var volume: Float = 0.18

    private var cache: [Cue: NSSound] = [:]

    public init() {}

    /// 効果音の生成と**出力経路の初期化**を先に済ませる。起動時に一度呼ぶ。
    ///
    /// 重いのは波形の合成(実測 9ms)ではなく最初の `NSSound.play()` で、
    /// CoreAudio の初期化に 180ms ほどかかる。無音で一度鳴らして先に払っておく。
    /// これをしないと、最初の録音の立ち上がりがその分だけ遅れる(FR-1.1)。
    public func prewarm() {
        for cue in Cue.allCases where cache[cue] == nil {
            cache[cue] = NSSound(data: ToneSynth.wav(for: cue))
        }
        guard let silent = cache[.start] else { return }
        silent.volume = 0
        silent.play()
        silent.stop()
    }

    public func play(_ cue: Cue) {
        guard isEnabled, volume > 0 else { return }
        let sound = cache[cue] ?? NSSound(data: ToneSynth.wav(for: cue))
        guard let sound else { return }
        cache[cue] = sound
        sound.volume = volume
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}

/// 短い音を WAV(16bit PCM)として合成する。NSSound はこのデータをそのまま再生できる。
enum ToneSynth {
    static let sampleRate = 44_100.0

    static func wav(for cue: SoundPlayer.Cue) -> Data {
        var samples: [Int16] = []
        for tone in cue.tones {
            samples.append(contentsOf: render(tone: tone))
        }
        return wavData(samples: samples)
    }

    /// クリックノイズを避けるため、両端をコサインでフェードする。
    private static func render(tone: (frequency: Double, seconds: Double, gain: Double)) -> [Int16] {
        let count = Int(sampleRate * tone.seconds)
        guard count > 0 else { return [] }
        let fade = max(1, Int(Double(count) * 0.35))

        return (0..<count).map { index in
            let phase = 2 * Double.pi * tone.frequency * Double(index) / sampleRate
            var envelope = 1.0
            if index < fade {
                envelope = 0.5 - 0.5 * cos(Double.pi * Double(index) / Double(fade))
            }
            let remaining = count - index
            if remaining < fade {
                envelope = min(envelope, 0.5 - 0.5 * cos(Double.pi * Double(remaining) / Double(fade)))
            }
            let value = sin(phase) * envelope * tone.gain
            return Int16(max(-1, min(1, value)) * Double(Int16.max))
        }
    }

    private static func wavData(samples: [Int16]) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        var data = Data(capacity: 44 + dataSize)

        func append(_ string: String) {
            data.append(contentsOf: Array(string.utf8))
        }
        func append32(_ value: UInt32) {
            data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
        }
        func append16(_ value: UInt16) {
            data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
        }

        append("RIFF")
        append32(UInt32(36 + dataSize))
        append("WAVE")
        append("fmt ")
        append32(16)              // fmt チャンクのサイズ
        append16(1)               // PCM
        append16(1)               // モノラル
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate) * 2)  // バイト/秒
        append16(2)               // ブロックサイズ
        append16(16)              // ビット深度
        append("data")
        append32(UInt32(dataSize))
        for sample in samples {
            append16(UInt16(bitPattern: sample))
        }
        return data
    }
}
