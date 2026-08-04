import AVFAudio
import Foundation
import Testing

@testable import KoeKit

/// SpeechAnalyzer エンジンのスモークテスト。
///
/// 狙いは 1 点: **どんなアセット状態でも trap させない**こと。
/// `AssetInventory.reserve(locale:)` を忘れると framework 内部で trap して
/// プロセスごと落ちるため、この経路を通すだけで回帰を検出できる。
/// アセットが未取得の環境では「正常に失敗する」ことを確認する。
@Suite("SpeechAnalyzer スモーク")
struct SpeechAnalyzerSmokeTests {
    @Test("アセットが揃っていなくても trap せず、連続 2 回でも一周できる")
    func doesNotTrapAcrossRepeatedSessions() async throws {
        let engine = SpeechAnalyzerStt()
        let availability = await engine.availability(languagePreference: .auto)

        let format: AVAudioFormat
        do {
            format = try await engine.prepare(hints: .init()) ?? AudioFormats.canonical
        } catch {
            // 未取得なら理由付きで失敗するのが正しい振る舞い。
            #expect(!availability.isReady)
            #expect(error.localizedDescription.isEmpty == false)
            return
        }

        #expect(format.sampleRate > 0)
        #expect(format.channelCount == 1)

        // 2 回連続で回す。transcriber を使い回すと 2 回目で trap するため、
        // ここを通すだけでその回帰を検出できる。
        for session in 1...2 {
            let sawFinal = await runOneSession(engine: engine, format: format)
            #expect(sawFinal, "セッション \(session) が確定イベントを返さなかった")
        }
    }

    private func runOneSession(engine: SpeechAnalyzerStt, format: AVAudioFormat) async -> Bool {
        let (chunks, continuation) = AsyncStream<AudioChunk>.makeStream()
        let feeder = Task {
            for index in 0..<12 {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600) else { break }
                buffer.frameLength = 1_600
                if let data = buffer.floatChannelData?[0] {
                    for sample in 0..<1_600 { data[sample] = sin(Float(sample) * 0.03) * 0.08 }
                }
                continuation.yield(AudioChunk(buffer: buffer, frameOffset: AVAudioFramePosition(index * 1_600)))
                try? await Task.sleep(for: .milliseconds(20))
            }
            continuation.finish()
        }

        var sawFinal = false
        do {
            for try await event in engine.transcribe(audio: chunks, hints: .init()) {
                if case .final = event { sawFinal = true }
            }
        } catch {
            Issue.record("transcribe が失敗: \(error.localizedDescription)")
        }
        await feeder.value
        return sawFinal
    }
}
