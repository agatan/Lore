import AVFAudio
import Testing

@testable import KoeKit

/// 入力レベルの算出。
///
/// エンジンが要求する音声フォーマットは Float32 とは限らず、SpeechAnalyzer は Int16 を返す。
/// Float だけを見ていると常に 0 になり、HUD の波形が動かない(実際にそうなった)。
@Suite("入力レベル")
struct AudioLevelTests {
    func buffer(format: AVAudioCommonFormat, amplitude: Double, frames: AVAudioFrameCount = 1_600) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: format, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames

        for index in 0..<Int(frames) {
            let value = sin(Double(index) * 0.1) * amplitude
            if let data = buffer.floatChannelData?[0] {
                data[index] = Float(value)
            } else if let data = buffer.int16ChannelData?[0] {
                data[index] = Int16(value * Double(Int16.max))
            } else if let data = buffer.int32ChannelData?[0] {
                data[index] = Int32(value * Double(Int32.max))
            }
        }
        return buffer
    }

    @Test("Float32 の音声でレベルが出る")
    func float32() {
        let level = AudioCapture.level(of: buffer(format: .pcmFormatFloat32, amplitude: 0.5))
        #expect(level > 0.5)
    }

    @Test("Int16 の音声でもレベルが出る")
    func int16() {
        let level = AudioCapture.level(of: buffer(format: .pcmFormatInt16, amplitude: 0.5))
        #expect(level > 0.5)
    }

    @Test("Int32 の音声でもレベルが出る")
    func int32() {
        let level = AudioCapture.level(of: buffer(format: .pcmFormatInt32, amplitude: 0.5))
        #expect(level > 0.5)
    }

    @Test("フォーマットが違ってもレベルはほぼ一致する")
    func consistentAcrossFormats() {
        let float = AudioCapture.level(of: buffer(format: .pcmFormatFloat32, amplitude: 0.3))
        let int16 = AudioCapture.level(of: buffer(format: .pcmFormatInt16, amplitude: 0.3))
        #expect(abs(float - int16) < 0.02)
    }

    @Test("無音は 0、フルスケールは上限付近")
    func rangeIsClamped() {
        #expect(AudioCapture.level(of: buffer(format: .pcmFormatInt16, amplitude: 0)) == 0)
        // フルスケールの正弦波は RMS が 0.707(-3dB)なので上限には届かない。
        let loud = AudioCapture.level(of: buffer(format: .pcmFormatInt16, amplitude: 1))
        #expect(loud > 0.9)
        #expect(loud <= 1)
    }

    @Test("小声でも 0 にはならない")
    func quietSpeechIsVisible() {
        let level = AudioCapture.level(of: buffer(format: .pcmFormatInt16, amplitude: 0.01))
        #expect(level > 0.05)
    }

    @Test("保存音声をSpeechAnalyzerが要求するInt16へ変換する")
    func convertsStoredAudioToRecognizerFormat() throws {
        let source = buffer(format: .pcmFormatFloat32, amplitude: 0.3)
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let converted = try #require(Resampler(from: source.format, to: target)?.convert(source))

        #expect(converted.format.commonFormat == .pcmFormatInt16)
        #expect(converted.int16ChannelData != nil)
        #expect(converted.frameLength > 0)
    }
}
