import Foundation
import Testing

@testable import LoreKit

@Suite("仕上げバックエンドの選択")
struct FormattingBackendTests {
    @Test("ローカルとクラウドの境界を明示する")
    func separatesLocalAndCloudProviders() {
        #expect(FormattingBackend.onDevice.sendsTranscriptOffDevice == false)
        #expect(FormattingBackend.ollama.sendsTranscriptOffDevice == false)
        #expect(FormattingBackend.lmStudio.sendsTranscriptOffDevice == false)
        #expect(FormattingBackend.openAI.sendsTranscriptOffDevice)
        #expect(FormattingBackend.anthropic.sendsTranscriptOffDevice)
        #expect(FormattingBackend.gemini.sendsTranscriptOffDevice)
        #expect(FormattingBackend.groq.sendsTranscriptOffDevice)
    }

    @MainActor
    @Test("既定はオンデバイス")
    func defaultsToOnDevice() {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.formattingBackend == .onDevice)
        #expect(settings.model(for: .groq) == GroqLlm.defaultModel)
        #expect(settings.lifeLogAudioRetentionPolicy == .processedOnly)
        #expect(!settings.onboardingCompleted)
        #expect(!settings.lifeLogAudioStorageConfirmed)
    }

    @MainActor
    @Test("旧版の音声保持設定は更新だけで破壊的に変更しない")
    func preservesLegacyAudioRetention() throws {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        var storage = AppSettings.Storage()
        storage.lifeLogAudioRetentionDays = 0
        defaults.set(try JSONEncoder().encode(storage), forKey: AppSettings.defaultsKey)

        let settings = AppSettings(defaults: defaults)
        #expect(settings.lifeLogAudioRetentionPolicy == .unlimited)
        settings.lifeLogAudioRetentionPolicy = .days(7)
        #expect(settings.lifeLogAudioRetentionDays == 7)
    }

    @MainActor
    @Test("廃止したライフログ用の接続先設定は読み捨て、音声入力の設定を保つ")
    func ignoresRemovedLifeLogLlmSettings() {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let stored = """
        {"formattingBackend":"openAI","openAIModel":"voice-model",\
        "lifeLogFormattingBackend":"groq","lifeLogGroqModel":"life-model",\
        "lifeLogSummaryPrompt":"old","lifeLogTodoPrompt":"old","lifeLogSummaryIntervalMinutes":30}
        """
        defaults.set(Data(stored.utf8), forKey: AppSettings.defaultsKey)

        let settings = AppSettings(defaults: defaults)
        #expect(settings.formattingBackend == .openAI)
        #expect(settings.model(for: .openAI) == "voice-model")
    }

    @MainActor
    @Test("選択に応じて整形エンジンが切り替わる")
    func registrySwitchesEngine() {
        let registry = EngineRegistry()

        registry.apply(backend: .onDevice, model: "test-model")
        #expect(registry.llm.identifier == .foundationModels)

        registry.apply(backend: .groq, model: "test-model")
        #expect(registry.llm.identifier == .groq)
        // 履歴にどのモデルで整形したかが残るよう、モデル ID がそのまま出る。
        #expect(registry.llm.modelName == "test-model")
    }

    @MainActor
    @Test("空のモデル ID は既定値に丸める")
    func blankModelFallsBack() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: #function)!)
        settings.setModel("   ", for: .groq)
        #expect(settings.model(for: .groq) == GroqLlm.defaultModel)
    }

    @Test("推論を垂れ流すモデルの <think> は落とす")
    func stripsReasoning() {
        #expect(GroqLlm.strippingReasoning("<think>ええと</think>本文です") == "本文です")
        #expect(GroqLlm.strippingReasoning("本文だけ") == "本文だけ")
    }
}

@Suite("HUD の居残り時間")
struct HudLingerTests {
    @MainActor
    @Test("挿入まで通ったら即座に引く")
    func successVanishes() {
        let linger = DictationCoordinator.lingerDuration(for: .finished(.completed), detail: nil)
        #expect(linger == DictationCoordinator.hudSuccessLingerDuration)
    }

    @MainActor
    @Test("読ませたい終わり方は残す")
    func noticesLinger() {
        let cases: [SessionPhase] = [
            .finished(.failed("失敗")),
            .finished(.clipboardOnly(reason: "挿入できません")),
            .finished(.formattingSkipped(reason: "タイムアウト")),
        ]
        for phase in cases {
            #expect(DictationCoordinator.lingerDuration(for: phase, detail: nil)
                == DictationCoordinator.hudNoticeLingerDuration)
        }
    }

    @MainActor
    @Test("成功でも注記が残っているなら読む時間を取る")
    func completedWithDetailLingers() {
        let linger = DictationCoordinator.lingerDuration(
            for: .finished(.completed),
            detail: "整形をスキップしました"
        )
        #expect(linger == DictationCoordinator.hudNoticeLingerDuration)
    }
}

/// 消えた選択肢が設定に残っていても、**他の設定を巻き添えにしない**(C-70)。
@Suite("設定の前方互換")
struct SettingsForwardCompatTests {
    @MainActor
    @Test("知らないバックエンド名が入っていても他の設定は生き残る")
    func unknownBackendKeepsOtherSettings() {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        // 旧版が書いた「今は存在しない選択肢」を含む設定
        let stored = """
        {"transcriptionBackend":"qwen3Asr","formattingBackend":"nope",\
        "groqModel":"my-model","formattingTimeoutMs":20000,"holdThresholdMs":777}
        """
        defaults.set(Data(stored.utf8), forKey: AppSettings.defaultsKey)

        let settings = AppSettings(defaults: defaults)
        #expect(settings.formattingBackend == .onDevice)  // 知らない値は既定へ
        // 消えたキー(transcriptionBackend)も知らない値も、他の設定を巻き添えにしない
        #expect(settings.model(for: .groq) == "my-model")
        #expect(settings.formattingTimeoutMs == 20_000)
        #expect(settings.holdThresholdMs == 777)
    }
}
