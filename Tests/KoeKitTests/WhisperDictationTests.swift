import AVFAudio
import Foundation
import Testing

@testable import KoeKit

@Suite("whisper.cpp入力の境界")
struct WhisperInputPolicyTests {
    private let rate = 16_000.0

    private func clip(silence leading: Double, speech: Double, silence trailing: Double) -> [Float] {
        let quiet = [Float](repeating: 0.0001, count: Int(rate * leading))
        let voiced = (0..<Int(rate * speech)).map { Float(sin(Double($0) * 0.05) * 0.1) }
        return quiet + voiced + [Float](repeating: 0.0001, count: Int(rate * trailing))
    }

    @Test("前後の無音は0.5秒の余白を残して除く")
    func trimsSilentEdgesWithMargin() {
        let samples = clip(silence: 3, speech: 2, silence: 4)
        let span = WhisperInputPolicy.speechSpan(of: samples, sampleRate: rate)
        let start = Double(span.lowerBound) / rate
        let end = Double(span.upperBound) / rate
        #expect(abs(start - 2.5) < 0.05)
        #expect(abs(end - 5.5) < 0.05)
    }

    @Test("有声frameが無い入力は判定誤りを避けて全体を渡す")
    func keepsWholeClipWithoutVoicedFrames() {
        let samples = [Float](repeating: 0.0001, count: Int(rate))
        #expect(WhisperInputPolicy.speechSpan(of: samples, sampleRate: rate) == 0..<samples.count)
        #expect(WhisperInputPolicy.speechSpan(of: [], sampleRate: rate).isEmpty)
    }

    @Test("語彙promptは並び順を保って上限まで残す")
    func fitsPromptInListOrder() {
        let prompt = "Koe、GRDB、SpeechAnalyzer、whisper.cpp"
        let fitted = WhisperInputPolicy.fittedPrompt(prompt) { $0.count <= 20 }
        #expect(fitted == "Koe、GRDB")
        #expect(WhisperInputPolicy.fittedPrompt(prompt) { _ in false } == nil)
        #expect(WhisperInputPolicy.fittedPrompt(nil) { _ in true } == nil)
    }

    @Test("語彙promptの読み上げだけのsegmentを写しと判定する")
    func detectsPromptEcho() {
        let prompt = "Koe、GRDB、SpeechAnalyzer"
        #expect(WhisperInputPolicy.isPromptEcho("Koe、GRDB、SpeechAnalyzer。", prompt: prompt))
        #expect(WhisperInputPolicy.isPromptEcho("koe grdb speechanalyzer", prompt: prompt))
        #expect(!WhisperInputPolicy.isPromptEcho("KoeでGRDBを使います", prompt: prompt))
        // 1語だけのpromptは、その語を口述した結果と区別できない。
        #expect(!WhisperInputPolicy.isPromptEcho("Koe", prompt: "Koe"))
    }
}

@Suite("音声入力のSTT選択")
struct DictationSttSelectionTests {
    @MainActor
    @Test("音声入力とライフログのSTTを個別に選べる")
    func selectsEnginePerPurpose() {
        let registry = EngineRegistry()
        #expect(registry.dictationStt.identifier == .speechAnalyzer)
        #expect(registry.lifeLogStt.identifier == .speechAnalyzer)

        registry.applyStt(dictation: .whisperCpp, lifeLog: .speechAnalyzer, model: .largeV3Turbo)
        #expect(registry.dictationStt.identifier == .whisperCpp)
        #expect(registry.lifeLogStt.identifier == .speechAnalyzer)

        registry.applyStt(dictation: .speechAnalyzer, lifeLog: .whisperCpp, model: .largeV3)
        #expect(registry.dictationStt.identifier == .speechAnalyzer)
        #expect(registry.lifeLogStt.identifier == .whisperCpp)
        #expect(registry.lifeLogStt.modelName == WhisperModel.largeV3.displayName)
    }

    @MainActor
    @Test("音声入力のSTT選択を保存し、未保存の設定はSpeechAnalyzerにする")
    func persistsDictationBackend() throws {
        let defaults = UserDefaults(suiteName: "koe-dictation-stt-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.dictationSttBackend == .speechAnalyzer)
        settings.dictationSttBackend = .whisperCpp
        settings.whisperModel = .largeV3
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.dictationSttBackend == .whisperCpp)
        #expect(reloaded.whisperModel == .largeV3)

        // 共有化前に保存したライフログのmodel選択を引き継ぐ。
        let legacy = try JSONDecoder().decode(
            AppSettings.Storage.self,
            from: Data(#"{"lifeLogWhisperModel":"large-v3-v20240930_626MB"}"#.utf8)
        )
        #expect(legacy.lifeLogWhisperModel == .largeV3)
        #expect(legacy.dictationSttBackend == .speechAnalyzer)
    }

    @Test("一括認識の確定待ちは録音長に応じて延ばす")
    func finalizationTimeoutGrowsWithRecording() {
        #expect(DictationCoordinator.finalizationTimeout(recorded: .zero) == .seconds(30))
        #expect(DictationCoordinator.finalizationTimeout(recorded: .seconds(120)) == .seconds(150))
    }

    @Test("共通ルールは数え上げを番号付きリストにし、数値を落とさない")
    func sharedRulesCoverListsAndNumbers() {
        #expect(BuiltinSharedRules.text.contains("番号付きリスト"))
        #expect(BuiltinSharedRules.text.contains("話した数値は 1 つも落とさず"))
    }
}

/// 実modelを使う統合テスト。`KOE_WHISPER_MODEL_ROOT`に取得済みLarge v3 Turbo Q5_0があるときだけ実行する。
@Suite("whisper.cpp 実model", .serialized)
struct WhisperCppIntegrationTests {
    private static let modelRoot = ProcessInfo.processInfo.environment["KOE_WHISPER_MODEL_ROOT"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    private static func speechChunk() throws -> AudioChunk {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "koe-whisper-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let aiff = directory.appending(path: "speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Kyoko", "-o", aiff.path, "明日の会議は十時からです"]
        try say.run()
        say.waitUntilExit()
        #expect(say.terminationStatus == 0)

        let file = try AVAudioFile(forReading: aiff)
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let target = AudioFormats.canonical
        let converter = AVAudioConverter(from: file.processingFormat, to: target)!
        let capacity = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / file.processingFormat.sampleRate) + 1_024
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        return AudioChunk(buffer: output, frameOffset: 0)
    }

    private static func transcribe(_ engine: WhisperCppStt, _ chunk: AudioChunk) async throws -> String {
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        continuation.yield(chunk)
        continuation.finish()
        var text = ""
        for try await event in engine.transcribe(audio: stream, hints: SttHints(vocabularyPrompt: "会議、十時", languagePreference: .ja)) {
            if case .sessionFinished(let value, _) = event { text = value }
        }
        return text
    }

    @Test("音声入力とライフログは重みを共有し、別stateで同時に認識できる",
          .enabled(if: modelRoot != nil))
    func sharedWeightsServeConcurrentStates() async throws {
        let root = try #require(Self.modelRoot)
        let cache = WhisperModelCache()
        let dictation = WhisperCppStt(model: .largeV3Turbo, modelRoot: root, cache: cache)
        let lifeLog = WhisperCppStt(model: .largeV3Turbo, modelRoot: root, cache: cache)
        try await dictation.warmUp()
        let chunk = try Self.speechChunk()

        async let first = Self.transcribe(dictation, chunk)
        async let second = Self.transcribe(lifeLog, chunk)
        let results = try await [first, second]
        for text in results {
            #expect(text.contains("会議"), "認識結果: \(text)")
        }
    }
}
