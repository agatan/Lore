import AVFoundation
import Foundation

/// マイク入力をエンジンが要求するフォーマットに変換して流す。
///
/// 変換をここで 1 回だけ行い、エンジン側では素のバッファを受け取るだけにする
/// (二重リサンプリングを避ける)。HUD 用の入力レベルも同じタップから配信する。
@MainActor
public final class AudioCapture {
    public struct Streams: Sendable {
        public let chunks: AsyncStream<AudioChunk>
        /// 0...1 に正規化した入力レベル。
        public let levels: AsyncStream<Float>
    }

    public enum Failure: LocalizedError {
        case microphoneDenied
        case noInputDevice
        case formatUnsupported

        public var errorDescription: String? {
            switch self {
            case .microphoneDenied: String(lore: "マイクの使用が許可されていません")
            case .noInputDevice: String(lore: "入力デバイスが見つかりません")
            case .formatUnsupported: String(lore: "この入力フォーマットを変換できません")
            }
        }
    }

    private var engine: AVAudioEngine?
    private var chunkContinuation: AsyncStream<AudioChunk>.Continuation?
    private var levelContinuation: AsyncStream<Float>.Continuation?
    private var capturedFrames: AVAudioFramePosition = 0
    private var captureSampleRate: Double = 16_000

    public private(set) var isRunning = false
    /// いま録音に使っている入力デバイス名。実際に束ねたデバイスから引く(HUD 表示用)。
    public private(set) var inputDeviceName: String?
    /// 直近の録音で受け取ったチャンク数と最大入力レベル。入力が来ているかの診断用。
    public private(set) var lastChunkCount = 0
    public private(set) var lastPeakLevel: Float = 0

    public init() {}

    /// 録音した音声の長さ(ms)。停止後も直近の値を保持する。
    public var capturedDurationMs: Int {
        guard captureSampleRate > 0 else { return 0 }
        return Int(Double(capturedFrames) / captureSampleRate * 1000)
    }

    public func start(format requested: AVAudioFormat?) throws -> Streams {
        guard Permissions.isMicrophoneGranted else { throw Failure.microphoneDenied }
        stop()

        let target = requested ?? AudioFormats.canonical
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw Failure.noInputDevice
        }
        guard let resampler = Resampler(from: inputFormat, to: target) else {
            throw Failure.formatUnsupported
        }

        let (chunks, chunkContinuation) = AsyncStream<AudioChunk>.makeStream(
            bufferingPolicy: .unbounded
        )
        let (levels, levelContinuation) = AsyncStream<Float>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )

        capturedFrames = 0
        captureSampleRate = target.sampleRate

        input.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: inputFormat,
            block: Self.makeTapBlock(
                resampler: resampler,
                chunks: chunkContinuation,
                levels: levelContinuation
            )
        )

        // 入力を無音のミキサーへ繋いでグラフを確実に駆動する。
        // 接続が無いと環境によって入力チェーンが回らず、タップが呼ばれない。
        // 音量 0 なのでスピーカーには出ない(ハウリングしない)。
        engine.connect(input, to: engine.mainMixerNode, format: inputFormat)
        engine.mainMixerNode.outputVolume = 0

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            chunkContinuation.finish()
            levelContinuation.finish()
            throw error
        }

        self.engine = engine
        self.chunkContinuation = chunkContinuation
        self.levelContinuation = levelContinuation
        self.resampler = resampler
        // 起動後に読む。デバイスが確定するのは engine.start() の後。
        inputDeviceName = AudioDevices.currentInputName()
        isRunning = true

        return Streams(chunks: chunks, levels: levels)
    }

    /// 停止 = ストリームの終了。エンジン側はこれを「録音停止」として受け取り最終確定に進む。
    public func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        if let resampler {
            capturedFrames = resampler.producedFrames
            lastChunkCount = resampler.chunkCount
            lastPeakLevel = resampler.peakLevel
        }
        resampler = nil
        chunkContinuation?.finish()
        levelContinuation?.finish()
        chunkContinuation = nil
        levelContinuation = nil
        isRunning = false
    }

    private var resampler: Resampler?

    /// タップのブロックは**必ず nonisolated な文脈で作る**。
    ///
    /// `@MainActor` のメソッド内で作ったクロージャは MainActor 隔離を継承するため、
    /// オーディオのリアルタイムスレッドから呼ばれた瞬間に隔離アサーションで落ちる。
    /// キャプチャするのは Sendable なものだけに限定する。
    private nonisolated static func makeTapBlock(
        resampler: Resampler,
        chunks: AsyncStream<AudioChunk>.Continuation,
        levels: AsyncStream<Float>.Continuation
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let converted = resampler.convert(buffer) else { return }
            let offset = resampler.advance(by: AVAudioFramePosition(converted.frameLength))
            let level = AudioCapture.level(of: converted)
            resampler.observe(level: level)
            chunks.yield(AudioChunk(buffer: converted, frameOffset: offset))
            levels.yield(level)
        }
    }

    /// RMS を -60...0dB のレンジで 0...1 に正規化する。
    ///
    /// エンジンが希望するフォーマットは Float32 とは限らない
    /// (SpeechAnalyzer の `bestAvailableAudioFormat` は Int16 を返す)。
    /// Float だけを見ていると常に 0 になり、波形が動かなくなる。
    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        let rms = rootMeanSquare(of: buffer)
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 60) / 60))
    }

    /// 発話判定に使う線形RMS。UI用の対数正規化をdomain thresholdへ流用しない。
    nonisolated static func rootMeanSquare(of buffer: AVAudioPCMBuffer) -> Float {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        let stride = Int(buffer.stride)

        var sum: Float = 0
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<count {
                let sample = channel[index * stride]
                sum += sample * sample
            }
        } else if let channel = buffer.int16ChannelData?[0] {
            let scale = Float(Int16.max)
            for index in 0..<count {
                let sample = Float(channel[index * stride]) / scale
                sum += sample * sample
            }
        } else if let channel = buffer.int32ChannelData?[0] {
            let scale = Float(Int32.max)
            for index in 0..<count {
                let sample = Float(channel[index * stride]) / scale
                sum += sample * sample
            }
        } else {
            return 0
        }

        return (sum / Float(count)).squareRoot()
    }
}

/// 変換ブロックへ入力バッファを 1 回だけ渡すための箱。
/// 生成と消費が同じタップ呼び出しの中で完結するため、競合は起きない。
final class PendingInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// タップスレッドからのみ触るため `@unchecked Sendable`。
/// 生成・破棄は MainActor 側、変換はタップスレッド側で、両者は同時に走らない。
final class Resampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let ratio: Double
    private(set) var producedFrames: AVAudioFramePosition = 0
    private(set) var chunkCount = 0
    private(set) var peakLevel: Float = 0

    init?(from input: AVAudioFormat, to target: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: target) else { return nil }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        // ステレオ入力 → モノラルは明示的にダウンミックスを指示する。
        // 既定では片チャンネルだけを拾い、環境によっては無音になる。
        if input.channelCount > target.channelCount {
            converter.downmix = true
        }
        self.converter = converter
        self.target = target
        self.ratio = target.sampleRate / input.sampleRate
    }

    func advance(by frames: AVAudioFramePosition) -> AVAudioFramePosition {
        let offset = producedFrames
        producedFrames += frames
        chunkCount += 1
        return offset
    }

    func observe(level: Float) {
        peakLevel = max(peakLevel, level)
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        // 変換ブロックは @Sendable として扱われるため、1 回だけ渡す入力を箱に入れて受け渡す。
        let pending = PendingInput(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            guard let next = pending.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return next
        }

        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

}
