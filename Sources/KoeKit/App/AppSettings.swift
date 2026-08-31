import Foundation
import Observation

public enum LlmPurpose: String, Sendable, CaseIterable {
    case dictation
    case lifeLog
}

/// ユーザー設定。UserDefaults(plist) に 1 つの JSON として保存する(FR-10.2)。
///
/// 全フィールドを 1 つの `Storage` に集約しているので、観測は `storage` の変更 1 点で成立し、
/// 保存も 1 箇所に閉じる。読み出しは欠損キーを既定値で埋める(将来の項目追加で壊れない)。
@MainActor
@Observable
public final class AppSettings {
    public struct Storage: Codable, Sendable {
        public var hotkey: HotkeyBinding = .default
        public var lifeLogCaptureHotkey: HotkeyBinding = .key(code: 0x25, modifiers: 0x000C_0000)
        public var lifeLogMiniWindowHotkey: HotkeyBinding = .key(code: 0x2E, modifiers: 0x000C_0000)
        public var voiceMemoHotkey: HotkeyBinding = .key(code: 0x09, modifiers: 0x000C_0000)
        /// 300ms だと「軽く叩いた」つもりの押下が長押し扱いになり、トグルが効かないことが多かった。
        public var holdThresholdMs: Int = 500
        public var soundsEnabled: Bool = true
        public var soundVolume: Double = 0.18
        public var hudEnabled: Bool = true
        /// 0 = 無期限。
        public var historyRetentionDays: Int = 0
        public var formattingTimeoutMs: Int = 6_000
        public var vocabularyAnalysisEnabled: Bool = true
        public var showLevelMeterInMenuBar: Bool = true
        /// 初回案内を完了するまで、権限と保存範囲を説明する。
        public var onboardingCompleted: Bool = false
        /// 文章の仕上げをどこで動かすか。既定はオンデバイス(外に出さない)。
        public var formattingBackend: FormattingBackend = .onDevice
        /// ライフログの要約・TODO生成は音声入力の整形と独立して選ぶ。
        public var lifeLogFormattingBackend: FormattingBackend = .onDevice
        public var openAIModel: String = "gpt-5.4-mini"
        public var anthropicModel: String = "claude-sonnet-5"
        public var geminiModel: String = "gemini-3.6-flash"
        /// Groq を選んだときに叩くモデル ID。API キーは Keychain(`SecretStore`)に置く。
        public var groqModel: String = GroqLlm.defaultModel
        public var ollamaModel: String = "gpt-oss:20b"
        public var lmStudioModel: String = "openai/gpt-oss-20b"
        public var lifeLogOpenAIModel: String = "gpt-5.4-mini"
        public var lifeLogAnthropicModel: String = "claude-sonnet-5"
        public var lifeLogGeminiModel: String = "gemini-3.6-flash"
        public var lifeLogGroqModel: String = GroqLlm.defaultModel
        public var lifeLogOllamaModel: String = "gpt-oss:20b"
        public var lifeLogLmStudioModel: String = "openai/gpt-oss-20b"
        public var lifeLogCaptureEnabled: Bool = false
        public var lifeLogInputDeviceUID: String?
        /// 音声は発話本文より機微性と容量が大きいので、既定では有限にする。0 = 無期限。
        public var lifeLogAudioRetentionDays: Int = 30
        /// ライフログが音声ファイルを保存することへの明示同意。
        public var lifeLogAudioStorageConfirmed: Bool = false
        public var lifeLogCalendarTitles: [String] = []
        public var lifeLogParticipatingEventsOnly: Bool = true
        public var lifeLogSummaryIntervalMinutes: Int = 60
        public var lifeLogTodoPrompt: String = BuiltinLifeLogPrompts.todo
        public var lifeLogSummaryPrompt: String = BuiltinLifeLogPrompts.summary
        public var lifeLogMiniWindowAlwaysOnTop: Bool = false
        public var accentPalette: AccentPalette = .ocean

        init() {}

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let fallback = Storage()
            hotkey = try container.decodeIfPresent(HotkeyBinding.self, forKey: .hotkey) ?? fallback.hotkey
            lifeLogCaptureHotkey = try container.decodeIfPresent(HotkeyBinding.self, forKey: .lifeLogCaptureHotkey) ?? fallback.lifeLogCaptureHotkey
            lifeLogMiniWindowHotkey = try container.decodeIfPresent(HotkeyBinding.self, forKey: .lifeLogMiniWindowHotkey) ?? fallback.lifeLogMiniWindowHotkey
            voiceMemoHotkey = try container.decodeIfPresent(HotkeyBinding.self, forKey: .voiceMemoHotkey) ?? fallback.voiceMemoHotkey
            holdThresholdMs = try container.decodeIfPresent(Int.self, forKey: .holdThresholdMs) ?? fallback.holdThresholdMs
            soundsEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundsEnabled) ?? fallback.soundsEnabled
            soundVolume = try container.decodeIfPresent(Double.self, forKey: .soundVolume) ?? fallback.soundVolume
            hudEnabled = try container.decodeIfPresent(Bool.self, forKey: .hudEnabled) ?? fallback.hudEnabled
            historyRetentionDays = try container.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? fallback.historyRetentionDays
            formattingTimeoutMs = try container.decodeIfPresent(Int.self, forKey: .formattingTimeoutMs) ?? fallback.formattingTimeoutMs
            vocabularyAnalysisEnabled = try container.decodeIfPresent(Bool.self, forKey: .vocabularyAnalysisEnabled) ?? fallback.vocabularyAnalysisEnabled
            showLevelMeterInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showLevelMeterInMenuBar) ?? fallback.showLevelMeterInMenuBar
            onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
            // 選択肢が消えた版へ戻したときに、**設定ファイル全体が捨てられない**ようにする。
            // ここで throw すると `AppSettings.init` の `try?` が丸ごと初期値へ倒し、
            // API キー以外の設定(ホットキー・モード・タイムアウト)が全部消える。
            formattingBackend = (try? container.decodeIfPresent(FormattingBackend.self, forKey: .formattingBackend))
                .flatMap { $0 } ?? fallback.formattingBackend
            // 分離前の利用者は、従来選んでいた接続先を両用途へ引き継ぐ。
            lifeLogFormattingBackend = (try? container.decodeIfPresent(FormattingBackend.self, forKey: .lifeLogFormattingBackend))
                .flatMap { $0 } ?? formattingBackend
            openAIModel = try container.decodeIfPresent(String.self, forKey: .openAIModel) ?? fallback.openAIModel
            anthropicModel = try container.decodeIfPresent(String.self, forKey: .anthropicModel) ?? fallback.anthropicModel
            geminiModel = try container.decodeIfPresent(String.self, forKey: .geminiModel) ?? fallback.geminiModel
            groqModel = try container.decodeIfPresent(String.self, forKey: .groqModel) ?? fallback.groqModel
            ollamaModel = try container.decodeIfPresent(String.self, forKey: .ollamaModel) ?? fallback.ollamaModel
            lmStudioModel = try container.decodeIfPresent(String.self, forKey: .lmStudioModel) ?? fallback.lmStudioModel
            lifeLogOpenAIModel = try container.decodeIfPresent(String.self, forKey: .lifeLogOpenAIModel) ?? openAIModel
            lifeLogAnthropicModel = try container.decodeIfPresent(String.self, forKey: .lifeLogAnthropicModel) ?? anthropicModel
            lifeLogGeminiModel = try container.decodeIfPresent(String.self, forKey: .lifeLogGeminiModel) ?? geminiModel
            lifeLogGroqModel = try container.decodeIfPresent(String.self, forKey: .lifeLogGroqModel) ?? groqModel
            lifeLogOllamaModel = try container.decodeIfPresent(String.self, forKey: .lifeLogOllamaModel) ?? ollamaModel
            lifeLogLmStudioModel = try container.decodeIfPresent(String.self, forKey: .lifeLogLmStudioModel) ?? lmStudioModel
            lifeLogCaptureEnabled = try container.decodeIfPresent(Bool.self, forKey: .lifeLogCaptureEnabled) ?? false
            lifeLogInputDeviceUID = try container.decodeIfPresent(String.self, forKey: .lifeLogInputDeviceUID)
            lifeLogAudioRetentionDays = try container.decodeIfPresent(Int.self, forKey: .lifeLogAudioRetentionDays) ?? fallback.lifeLogAudioRetentionDays
            lifeLogAudioStorageConfirmed = try container.decodeIfPresent(Bool.self, forKey: .lifeLogAudioStorageConfirmed) ?? false
            lifeLogCalendarTitles = try container.decodeIfPresent([String].self, forKey: .lifeLogCalendarTitles) ?? []
            lifeLogParticipatingEventsOnly = try container.decodeIfPresent(Bool.self, forKey: .lifeLogParticipatingEventsOnly) ?? true
            lifeLogSummaryIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .lifeLogSummaryIntervalMinutes) ?? 60
            lifeLogTodoPrompt = try container.decodeIfPresent(String.self, forKey: .lifeLogTodoPrompt) ?? fallback.lifeLogTodoPrompt
            lifeLogSummaryPrompt = try container.decodeIfPresent(String.self, forKey: .lifeLogSummaryPrompt) ?? fallback.lifeLogSummaryPrompt
            lifeLogMiniWindowAlwaysOnTop = try container.decodeIfPresent(Bool.self, forKey: .lifeLogMiniWindowAlwaysOnTop) ?? false
            accentPalette = try container.decodeIfPresent(AccentPalette.self, forKey: .accentPalette) ?? fallback.accentPalette

        }
    }

    static let defaultsKey = "koe.settings.v1"

    @ObservationIgnored private let defaults: UserDefaults
    private var storage: Storage

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(Storage.self, from: data) {
            storage = decoded
        } else {
            storage = Storage()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public var hotkey: HotkeyBinding {
        get { storage.hotkey }
        set { storage.hotkey = newValue; persist() }
    }

    public var lifeLogCaptureHotkey: HotkeyBinding {
        get { storage.lifeLogCaptureHotkey }
        set { storage.lifeLogCaptureHotkey = newValue; persist() }
    }

    public var lifeLogMiniWindowHotkey: HotkeyBinding {
        get { storage.lifeLogMiniWindowHotkey }
        set { storage.lifeLogMiniWindowHotkey = newValue; persist() }
    }

    public var voiceMemoHotkey: HotkeyBinding {
        get { storage.voiceMemoHotkey }
        set { storage.voiceMemoHotkey = newValue; persist() }
    }

    public var holdThreshold: Duration {
        .milliseconds(storage.holdThresholdMs)
    }

    public var holdThresholdMs: Int {
        get { storage.holdThresholdMs }
        set { storage.holdThresholdMs = max(80, min(1_500, newValue)); persist() }
    }

    public var soundsEnabled: Bool {
        get { storage.soundsEnabled }
        set { storage.soundsEnabled = newValue; persist() }
    }

    public var soundVolume: Double {
        get { storage.soundVolume }
        set { storage.soundVolume = max(0, min(1, newValue)); persist() }
    }

    public var hudEnabled: Bool {
        get { storage.hudEnabled }
        set { storage.hudEnabled = newValue; persist() }
    }

    public var historyRetentionDays: Int {
        get { storage.historyRetentionDays }
        set { storage.historyRetentionDays = max(0, newValue); persist() }
    }

    public var formattingTimeout: Duration {
        .milliseconds(storage.formattingTimeoutMs)
    }

    public var formattingTimeoutMs: Int {
        get { storage.formattingTimeoutMs }
        set { storage.formattingTimeoutMs = max(1_000, min(60_000, newValue)); persist() }
    }

    public var vocabularyAnalysisEnabled: Bool {
        get { storage.vocabularyAnalysisEnabled }
        set { storage.vocabularyAnalysisEnabled = newValue; persist() }
    }

    public var showLevelMeterInMenuBar: Bool {
        get { storage.showLevelMeterInMenuBar }
        set { storage.showLevelMeterInMenuBar = newValue; persist() }
    }

    public var onboardingCompleted: Bool {
        get { storage.onboardingCompleted }
        set { storage.onboardingCompleted = newValue; persist() }
    }

    public var formattingBackend: FormattingBackend {
        get { storage.formattingBackend }
        set { storage.formattingBackend = newValue; persist() }
    }

    public var lifeLogFormattingBackend: FormattingBackend {
        get { storage.lifeLogFormattingBackend }
        set { storage.lifeLogFormattingBackend = newValue; persist() }
    }

    public func backend(for purpose: LlmPurpose) -> FormattingBackend {
        purpose == .dictation ? storage.formattingBackend : storage.lifeLogFormattingBackend
    }

    public func setBackend(_ backend: FormattingBackend, for purpose: LlmPurpose) {
        switch purpose {
        case .dictation: storage.formattingBackend = backend
        case .lifeLog: storage.lifeLogFormattingBackend = backend
        }
        persist()
    }

    public func model(for backend: FormattingBackend, purpose: LlmPurpose) -> String {
        if purpose == .lifeLog {
            return switch backend {
            case .onDevice: "Apple Foundation Models"
            case .openAI: storage.lifeLogOpenAIModel
            case .anthropic: storage.lifeLogAnthropicModel
            case .gemini: storage.lifeLogGeminiModel
            case .groq: storage.lifeLogGroqModel
            case .ollama: storage.lifeLogOllamaModel
            case .lmStudio: storage.lifeLogLmStudioModel
            }
        }
        return switch backend {
        case .onDevice: "Apple Foundation Models"
        case .openAI: storage.openAIModel
        case .anthropic: storage.anthropicModel
        case .gemini: storage.geminiModel
        case .groq: storage.groqModel
        case .ollama: storage.ollamaModel
        case .lmStudio: storage.lmStudioModel
        }
    }

    public func setModel(_ value: String, for backend: FormattingBackend, purpose: LlmPurpose) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if purpose == .lifeLog {
            switch backend {
            case .onDevice: return
            case .openAI: storage.lifeLogOpenAIModel = trimmed
            case .anthropic: storage.lifeLogAnthropicModel = trimmed
            case .gemini: storage.lifeLogGeminiModel = trimmed
            case .groq: storage.lifeLogGroqModel = trimmed
            case .ollama: storage.lifeLogOllamaModel = trimmed
            case .lmStudio: storage.lifeLogLmStudioModel = trimmed
            }
            persist()
            return
        }
        switch backend {
        case .onDevice: return
        case .openAI: storage.openAIModel = trimmed
        case .anthropic: storage.anthropicModel = trimmed
        case .gemini: storage.geminiModel = trimmed
        case .groq: storage.groqModel = trimmed
        case .ollama: storage.ollamaModel = trimmed
        case .lmStudio: storage.lmStudioModel = trimmed
        }
        persist()
    }

    public var lifeLogCaptureEnabled: Bool { get { storage.lifeLogCaptureEnabled } set { storage.lifeLogCaptureEnabled = newValue; persist() } }
    public var lifeLogInputDeviceUID: String? { get { storage.lifeLogInputDeviceUID } set { storage.lifeLogInputDeviceUID = newValue; persist() } }
    public var lifeLogAudioRetentionDays: Int { get { storage.lifeLogAudioRetentionDays } set { storage.lifeLogAudioRetentionDays = max(0, newValue); persist() } }
    public var lifeLogAudioStorageConfirmed: Bool { get { storage.lifeLogAudioStorageConfirmed } set { storage.lifeLogAudioStorageConfirmed = newValue; persist() } }
    public var lifeLogCalendarTitles: [String] { get { storage.lifeLogCalendarTitles } set { storage.lifeLogCalendarTitles = newValue; persist() } }
    public var lifeLogParticipatingEventsOnly: Bool { get { storage.lifeLogParticipatingEventsOnly } set { storage.lifeLogParticipatingEventsOnly = newValue; persist() } }
    public var lifeLogSummaryIntervalMinutes: Int { get { storage.lifeLogSummaryIntervalMinutes } set { storage.lifeLogSummaryIntervalMinutes = max(15, newValue); persist() } }
    public var lifeLogTodoPrompt: String { get { storage.lifeLogTodoPrompt } set { storage.lifeLogTodoPrompt = newValue; persist() } }
    public var lifeLogSummaryPrompt: String { get { storage.lifeLogSummaryPrompt } set { storage.lifeLogSummaryPrompt = newValue; persist() } }
    public var lifeLogMiniWindowAlwaysOnTop: Bool { get { storage.lifeLogMiniWindowAlwaysOnTop } set { storage.lifeLogMiniWindowAlwaysOnTop = newValue; persist() } }
    public var accentPalette: AccentPalette { get { storage.accentPalette } set { storage.accentPalette = newValue; persist() } }

    /// 「Koeの全データを削除」で設定も初期状態へ戻す。
    public func resetAll() {
        storage = Storage()
        persist()
    }

    /// CLI/MCPが同じ設定ドメインを書き換えた後、起動中のUIへ反映する。
    public func reload() {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return }
        do {
            storage = try JSONDecoder().decode(Storage.self, from: data)
        } catch {
            KoeLog.persistence.error("外部変更された設定を読み込めません: \(error.localizedDescription, privacy: .public)")
        }
    }
}
