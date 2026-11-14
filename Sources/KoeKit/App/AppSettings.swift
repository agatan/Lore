import Foundation
import Observation

/// 音声入力とライフログで個別に選ぶSTT。
public enum SttBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    case speechAnalyzer
    /// Raw value is retained because it is persisted in released user settings.
    case whisperCpp = "whisperKit"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .speechAnalyzer: "Apple SpeechAnalyzer"
        case .whisperCpp: "whisper.cpp"
        }
    }
}

public enum WhisperModel: String, Codable, Sendable, CaseIterable, Identifiable {
    case small = "small"
    case largeV3 = "large-v3-v20240930_626MB"
    case largeV3Turbo = "large-v3-v20240930_turbo_632MB"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .small: "Whisper Small Q5_1 (190 MB)"
        case .largeV3: "Whisper Large v3 Q5_0 (1.08 GB)"
        case .largeV3Turbo: "Whisper Large v3 Turbo Q5_0 (574 MB)"
        }
    }
}

public enum LifeLogAudioRetentionPolicy: Hashable, Sendable {
    case processedOnly
    case days(Int)
    case unlimited

    public init(storedDays: Int) {
        switch storedDays {
        case -1: self = .processedOnly
        case 0: self = .unlimited
        default: self = .days(max(1, storedDays))
        }
    }

    public var storedDays: Int {
        switch self {
        case .processedOnly: -1
        case .days(let days): max(1, days)
        case .unlimited: 0
        }
    }
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
        public var applicationLanguage: ApplicationLanguage = .system
        /// 初回案内を完了するまで、権限と保存範囲を説明する。
        public var onboardingCompleted: Bool = false
        /// 文章の仕上げをどこで動かすか。既定はオンデバイス(外に出さない)。
        public var formattingBackend: FormattingBackend = .onDevice
        /// ライフログの要約・TODO生成は音声入力の整形と独立して選ぶ。
        public var openAIModel: String = "gpt-5.4-mini"
        public var anthropicModel: String = "claude-sonnet-5"
        public var geminiModel: String = "gemini-3.6-flash"
        /// Groq を選んだときに叩くモデル ID。API キーは Keychain(`SecretStore`)に置く。
        public var groqModel: String = GroqLlm.defaultModel
        public var ollamaModel: String = "gpt-oss:20b"
        public var lmStudioModel: String = "openai/gpt-oss-20b"
        public var lifeLogCaptureEnabled: Bool = false
        public var dictationSttBackend: SttBackend = .speechAnalyzer
        public var lifeLogSttBackend: SttBackend = .speechAnalyzer
        public var lifeLogTranscriptionLanguage: LifeLogTranscriptionLanguage = .applicationLanguage
        /// 音声入力とライフログで共有するmodel。保存keyは共有化前の名前を維持する。
        public var lifeLogWhisperModel: WhisperModel = .largeV3Turbo
        public var lifeLogInputDeviceUID: String?
        /// -1 = 処理後削除、0 = 旧版の無期限、正数 = 保持日数。
        public var lifeLogAudioRetentionDays: Int = -1
        /// ライフログが音声ファイルを保存することへの明示同意。
        public var lifeLogAudioStorageConfirmed: Bool = false
        public var lifeLogCalendarTitles: [String] = []
        public var lifeLogParticipatingEventsOnly: Bool = true
        public var lifeLogSchedule: LifeLogSchedule = .default

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
            applicationLanguage = (try? container.decodeIfPresent(ApplicationLanguage.self, forKey: .applicationLanguage))
                .flatMap { $0 } ?? fallback.applicationLanguage
            onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
            // 選択肢が消えた版へ戻したときに、**設定ファイル全体が捨てられない**ようにする。
            // ここで throw すると `AppSettings.init` の `try?` が丸ごと初期値へ倒し、
            // API キー以外の設定(ホットキー・モード・タイムアウト)が全部消える。
            formattingBackend = (try? container.decodeIfPresent(FormattingBackend.self, forKey: .formattingBackend))
                .flatMap { $0 } ?? fallback.formattingBackend
            openAIModel = try container.decodeIfPresent(String.self, forKey: .openAIModel) ?? fallback.openAIModel
            anthropicModel = try container.decodeIfPresent(String.self, forKey: .anthropicModel) ?? fallback.anthropicModel
            geminiModel = try container.decodeIfPresent(String.self, forKey: .geminiModel) ?? fallback.geminiModel
            groqModel = try container.decodeIfPresent(String.self, forKey: .groqModel) ?? fallback.groqModel
            ollamaModel = try container.decodeIfPresent(String.self, forKey: .ollamaModel) ?? fallback.ollamaModel
            lmStudioModel = try container.decodeIfPresent(String.self, forKey: .lmStudioModel) ?? fallback.lmStudioModel
            lifeLogCaptureEnabled = try container.decodeIfPresent(Bool.self, forKey: .lifeLogCaptureEnabled) ?? false
            dictationSttBackend = (try? container.decodeIfPresent(SttBackend.self, forKey: .dictationSttBackend))
                .flatMap { $0 } ?? .speechAnalyzer
            lifeLogSttBackend = (try? container.decodeIfPresent(SttBackend.self, forKey: .lifeLogSttBackend))
                .flatMap { $0 } ?? .speechAnalyzer
            lifeLogTranscriptionLanguage = (try? container.decodeIfPresent(LifeLogTranscriptionLanguage.self, forKey: .lifeLogTranscriptionLanguage))
                .flatMap { $0 } ?? .applicationLanguage
            lifeLogWhisperModel = (try? container.decodeIfPresent(WhisperModel.self, forKey: .lifeLogWhisperModel))
                .flatMap { $0 } ?? .largeV3Turbo
            lifeLogInputDeviceUID = try container.decodeIfPresent(String.self, forKey: .lifeLogInputDeviceUID)
            lifeLogAudioRetentionDays = try container.decodeIfPresent(Int.self, forKey: .lifeLogAudioRetentionDays) ?? fallback.lifeLogAudioRetentionDays
            lifeLogAudioStorageConfirmed = try container.decodeIfPresent(Bool.self, forKey: .lifeLogAudioStorageConfirmed) ?? false
            lifeLogCalendarTitles = try container.decodeIfPresent([String].self, forKey: .lifeLogCalendarTitles) ?? []
            lifeLogParticipatingEventsOnly = try container.decodeIfPresent(Bool.self, forKey: .lifeLogParticipatingEventsOnly) ?? true
            lifeLogSchedule = (try? container.decodeIfPresent(LifeLogSchedule.self, forKey: .lifeLogSchedule))
                .flatMap { $0 } ?? .default
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

    public var applicationLanguage: ApplicationLanguage {
        get { storage.applicationLanguage }
        set { storage.applicationLanguage = newValue; persist() }
    }

    public var onboardingCompleted: Bool {
        get { storage.onboardingCompleted }
        set { storage.onboardingCompleted = newValue; persist() }
    }

    public var formattingBackend: FormattingBackend {
        get { storage.formattingBackend }
        set { storage.formattingBackend = newValue; persist() }
    }

    public func model(for backend: FormattingBackend) -> String {
        switch backend {
        case .onDevice: "Apple Foundation Models"
        case .openAI: storage.openAIModel
        case .anthropic: storage.anthropicModel
        case .gemini: storage.geminiModel
        case .groq: storage.groqModel
        case .ollama: storage.ollamaModel
        case .lmStudio: storage.lmStudioModel
        }
    }

    public func setModel(_ value: String, for backend: FormattingBackend) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
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
    public var lifeLogSttBackend: SttBackend { get { storage.lifeLogSttBackend } set { storage.lifeLogSttBackend = newValue; persist() } }
    public var lifeLogTranscriptionLanguage: LifeLogTranscriptionLanguage { get { storage.lifeLogTranscriptionLanguage } set { storage.lifeLogTranscriptionLanguage = newValue; persist() } }
    public var dictationSttBackend: SttBackend { get { storage.dictationSttBackend } set { storage.dictationSttBackend = newValue; persist() } }
    public var whisperModel: WhisperModel { get { storage.lifeLogWhisperModel } set { storage.lifeLogWhisperModel = newValue; persist() } }
    public var lifeLogInputDeviceUID: String? { get { storage.lifeLogInputDeviceUID } set { storage.lifeLogInputDeviceUID = newValue; persist() } }
    public var lifeLogAudioRetentionPolicy: LifeLogAudioRetentionPolicy {
        get { LifeLogAudioRetentionPolicy(storedDays: storage.lifeLogAudioRetentionDays) }
        set { storage.lifeLogAudioRetentionDays = newValue.storedDays; persist() }
    }
    public var lifeLogAudioRetentionDays: Int {
        get { storage.lifeLogAudioRetentionDays }
        set { lifeLogAudioRetentionPolicy = LifeLogAudioRetentionPolicy(storedDays: newValue) }
    }
    public var lifeLogAudioStorageConfirmed: Bool { get { storage.lifeLogAudioStorageConfirmed } set { storage.lifeLogAudioStorageConfirmed = newValue; persist() } }
    public var lifeLogSchedule: LifeLogSchedule { get { storage.lifeLogSchedule } set { storage.lifeLogSchedule = newValue; persist() } }
    public var lifeLogCalendarTitles: [String] { get { storage.lifeLogCalendarTitles } set { storage.lifeLogCalendarTitles = newValue; persist() } }
    public var lifeLogParticipatingEventsOnly: Bool { get { storage.lifeLogParticipatingEventsOnly } set { storage.lifeLogParticipatingEventsOnly = newValue; persist() } }
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
