import Foundation

/// 推論エンジンの識別子。DB とプロトコル境界の両方で使う。
public struct EngineIdentifier: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let speechAnalyzer = EngineIdentifier("speech_analyzer")
    public static let whisperKit = EngineIdentifier("whisper_kit")
    public static let foundationModels = EngineIdentifier("foundation_models")
    public static let mlx = EngineIdentifier("mlx")
    /// 整形なし(生テキストをそのまま使った)ことを表す。
    public static let none = EngineIdentifier("none")

    public var displayName: String {
        switch self {
        case .speechAnalyzer: "SpeechAnalyzer"
        case .whisperKit: "WhisperKit"
        case .foundationModels: "Foundation Models"
        case .mlx: "MLX"
        case .none: "整形なし"
        default: rawValue
        }
    }
}

/// 録音の起動きっかけ。履歴の説明可能性のために記録する。
public enum DictationTrigger: String, Codable, Sendable {
    case toggle
    case pushToTalk
    case manual

    public var displayName: String {
        switch self {
        case .toggle: "トグル"
        case .pushToTalk: "長押し"
        case .manual: "手動"
        }
    }
}

/// 履歴に残る終端ステータス。`interrupted` だけは非終端で、
/// 「STT 確定を永続化したが、そのあと最後まで進めなかった」ことを表す(クラッシュ復旧の手がかり)。
public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case interrupted
    case completed
    case cancelled
    case failed
    case fallback
    case clipboardOnly = "clipboard_only"

    public var displayName: String {
        switch self {
        case .interrupted: "中断"
        case .completed: "完了"
        case .cancelled: "キャンセル"
        case .failed: "失敗"
        case .fallback: "整形スキップ"
        case .clipboardOnly: "クリップボードのみ"
        }
    }

    public var isTerminal: Bool { self != .interrupted }
}

/// 適用したモードとプロンプトのスナップショット。
/// 設定を後から変えても過去の履歴の説明可能性が壊れないための記録(NFR-4)。
public struct ModeSnapshot: Codable, Sendable, Hashable {
    public var modeName: String
    public var modePrompt: String
    /// 語彙注入まで済んだ、実際に LLM へ渡した system プロンプト全文。
    public var systemPrompt: String
    public var vocabularyCount: Int
    public var trigger: DictationTrigger

    public init(
        modeName: String,
        modePrompt: String,
        systemPrompt: String,
        vocabularyCount: Int,
        trigger: DictationTrigger
    ) {
        self.modeName = modeName
        self.modePrompt = modePrompt
        self.systemPrompt = systemPrompt
        self.vocabularyCount = vocabularyCount
        self.trigger = trigger
    }
}

/// 録音開始の瞬間に確定するコンテキスト。処理中にユーザーがアプリを切り替えても影響しない。
public struct SessionContext: Sendable {
    public var appBundleID: String?
    public var appName: String?
    public var mode: Mode
    public var systemPrompt: String
    public var vocabularyCount: Int
    public var sttEngine: EngineIdentifier
    public var sttModel: String?
    public var llmEngine: EngineIdentifier?
    public var llmModel: String?
    public var trigger: DictationTrigger

    public init(
        appBundleID: String?,
        appName: String?,
        mode: Mode,
        systemPrompt: String,
        vocabularyCount: Int,
        sttEngine: EngineIdentifier,
        sttModel: String?,
        llmEngine: EngineIdentifier?,
        llmModel: String?,
        trigger: DictationTrigger
    ) {
        self.appBundleID = appBundleID
        self.appName = appName
        self.mode = mode
        self.systemPrompt = systemPrompt
        self.vocabularyCount = vocabularyCount
        self.sttEngine = sttEngine
        self.sttModel = sttModel
        self.llmEngine = llmEngine
        self.llmModel = llmModel
        self.trigger = trigger
    }

    public var modeSnapshot: ModeSnapshot {
        ModeSnapshot(
            modeName: mode.name,
            modePrompt: mode.prompt,
            systemPrompt: systemPrompt,
            vocabularyCount: vocabularyCount,
            trigger: trigger
        )
    }
}

/// 履歴 1 行。監査記録も兼ねる(設計 D-8)。
public struct SessionRecord: Identifiable, Sendable, Hashable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: SessionStatus
    public var appBundleID: String?
    public var appName: String?
    public var modeID: String?
    public var modeSnapshot: ModeSnapshot
    public var sttEngine: EngineIdentifier
    public var sttModel: String?
    public var llmEngine: EngineIdentifier?
    public var llmModel: String?
    public var language: RecognizedLanguage?
    /// ★ 発話を失わないための本体。STT 確定と同時に永続化される。
    public var rawTranscript: String
    public var formattedText: String?
    public var error: String?
    public var audioDurationMs: Int?
    public var sttLatencyMs: Int?
    public var llmLatencyMs: Int?
    public var insertLatencyMs: Int?

    public init(
        id: String,
        startedAt: Date,
        endedAt: Date? = nil,
        status: SessionStatus,
        appBundleID: String? = nil,
        appName: String? = nil,
        modeID: String? = nil,
        modeSnapshot: ModeSnapshot,
        sttEngine: EngineIdentifier,
        sttModel: String? = nil,
        llmEngine: EngineIdentifier? = nil,
        llmModel: String? = nil,
        language: RecognizedLanguage? = nil,
        rawTranscript: String,
        formattedText: String? = nil,
        error: String? = nil,
        audioDurationMs: Int? = nil,
        sttLatencyMs: Int? = nil,
        llmLatencyMs: Int? = nil,
        insertLatencyMs: Int? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.appBundleID = appBundleID
        self.appName = appName
        self.modeID = modeID
        self.modeSnapshot = modeSnapshot
        self.sttEngine = sttEngine
        self.sttModel = sttModel
        self.llmEngine = llmEngine
        self.llmModel = llmModel
        self.language = language
        self.rawTranscript = rawTranscript
        self.formattedText = formattedText
        self.error = error
        self.audioDurationMs = audioDurationMs
        self.sttLatencyMs = sttLatencyMs
        self.llmLatencyMs = llmLatencyMs
        self.insertLatencyMs = insertLatencyMs
    }

    /// 実際に挿入された(あるいは挿入されるはずだった)テキスト。
    public var resultText: String {
        if let formattedText, !formattedText.isEmpty { return formattedText }
        return rawTranscript
    }
}

// MARK: - 状態機械

/// UI に見せる進行状態。
public enum SessionPhase: Sendable, Equatable {
    case idle
    case recording
    case recognizing
    case formatting
    case inserting
    case finished(SessionOutcome)

    public var isActive: Bool {
        switch self {
        case .idle, .finished: false
        case .recording, .recognizing, .formatting, .inserting: true
        }
    }
}

public enum SessionOutcome: Sendable, Equatable {
    case completed
    case cancelled
    /// 整形に失敗したので生テキストを挿入した。
    case formattingSkipped(reason: String)
    /// 挿入に失敗したのでクリップボードに残した。
    case clipboardOnly(reason: String)
    case failed(String)
}

/// 進行中の口述セッション。
///
/// 「発話を失わない」不変条件を型で守る仕掛け:
/// `finalizeTranscript(_:)` を通るまで `SessionRecord` は存在しない。
/// つまり永続化・整形・挿入のいずれも、STT 確定より前には構造的に実行できない。
public struct SessionDraft: Sendable {
    public let id: String
    public let context: SessionContext
    public let startedAt: Date
    public private(set) var phase: SessionPhase
    /// STT 確定後にだけ値を持つ。
    public private(set) var record: SessionRecord?
    /// 録音中の暫定テキスト。キャンセル時の記録にも使う。
    public private(set) var partialTranscript: String = ""
    /// トグルか push-to-talk かは「離した瞬間」に確定するため、開始後に更新できる。
    public private(set) var trigger: DictationTrigger
    private var formattingSkipReason: String?

    public init(id: String = UUID().uuidString, context: SessionContext, startedAt: Date = Date()) {
        self.id = id
        self.context = context
        self.startedAt = startedAt
        self.trigger = context.trigger
        self.phase = .recording
    }

    public mutating func updatePartial(_ text: String) {
        partialTranscript = text
    }

    public mutating func setTrigger(_ trigger: DictationTrigger) {
        self.trigger = trigger
    }

    /// 記録に残すスナップショット。トリガー種別だけは確定後の値を使う。
    private var snapshot: ModeSnapshot {
        var snapshot = context.modeSnapshot
        snapshot.trigger = trigger
        return snapshot
    }

    public mutating func beginRecognizing() {
        phase = .recognizing
    }

    /// ★ STT 確定。ここで初めて永続化可能な記録が生まれる。
    public mutating func finalizeTranscript(
        _ text: String,
        language: RecognizedLanguage,
        sttLatencyMs: Int,
        audioDurationMs: Int
    ) -> SessionRecord {
        let record = SessionRecord(
            id: id,
            startedAt: startedAt,
            status: .interrupted,
            appBundleID: context.appBundleID,
            appName: context.appName,
            modeID: context.mode.id,
            modeSnapshot: snapshot,
            sttEngine: context.sttEngine,
            sttModel: context.sttModel,
            llmEngine: context.llmEngine,
            llmModel: context.llmModel,
            language: language,
            rawTranscript: text,
            audioDurationMs: audioDurationMs,
            sttLatencyMs: sttLatencyMs
        )
        self.record = record
        partialTranscript = text
        phase = .formatting
        return record
    }

    public mutating func markFormatted(_ text: String, llmLatencyMs: Int) -> SessionRecord? {
        guard var record else { return nil }
        record.formattedText = text
        record.llmLatencyMs = llmLatencyMs
        self.record = record
        phase = .inserting
        return record
    }

    /// 整形をスキップして生テキストを使う(FR-3.6 / FR-3.7)。
    ///
    /// - Parameter fallbackText: 語彙矯正だけを適用したテキスト。生テキストと違うときは、
    ///   実際に挿入した内容として記録する(`llm_engine = none` なので LLM 整形と混ざらない)。
    public mutating func markFormattingSkipped(
        reason: String,
        fallbackText: String? = nil,
        llmLatencyMs: Int?
    ) -> SessionRecord? {
        guard var record else { return nil }
        record.llmEngine = SessionRecord.formattingSkippedEngine
        record.llmModel = nil
        record.llmLatencyMs = llmLatencyMs
        record.error = reason
        if let fallbackText, fallbackText != record.rawTranscript {
            record.formattedText = fallbackText
        }
        formattingSkipReason = reason
        self.record = record
        phase = .inserting
        return record
    }

    public mutating func markInserted(insertLatencyMs: Int, at date: Date = Date()) -> SessionRecord? {
        guard var record else { return nil }
        record.insertLatencyMs = insertLatencyMs
        record.endedAt = date
        record.status = formattingSkipReason == nil ? .completed : .fallback
        self.record = record
        phase = .finished(
            formattingSkipReason.map { .formattingSkipped(reason: $0) } ?? .completed
        )
        return record
    }

    public mutating func markClipboardOnly(reason: String, at date: Date = Date()) -> SessionRecord? {
        guard var record else { return nil }
        record.status = .clipboardOnly
        record.error = [formattingSkipReason, reason].compactMap(\.self).joined(separator: " / ")
        record.endedAt = date
        self.record = record
        phase = .finished(.clipboardOnly(reason: reason))
        return record
    }

    /// キャンセル。確定テキストが無くても暫定テキストがあれば記録を作る(FR-1.4)。
    public mutating func markCancelled(at date: Date = Date()) -> SessionRecord? {
        phase = .finished(.cancelled)
        if var record {
            record.status = .cancelled
            record.endedAt = date
            self.record = record
            return record
        }
        let text = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var record = interruptedRecord(rawTranscript: text, status: .cancelled)
        record.endedAt = date
        self.record = record
        return record
    }

    public mutating func markFailed(_ message: String, at date: Date = Date()) -> SessionRecord? {
        phase = .finished(.failed(message))
        if var record {
            record.status = .failed
            record.error = message
            record.endedAt = date
            self.record = record
            return record
        }
        let text = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var record = interruptedRecord(rawTranscript: text, status: .failed)
        record.error = message
        record.endedAt = date
        self.record = record
        return record
    }

    private func interruptedRecord(rawTranscript: String, status: SessionStatus) -> SessionRecord {
        SessionRecord(
            id: id,
            startedAt: startedAt,
            status: status,
            appBundleID: context.appBundleID,
            appName: context.appName,
            modeID: context.mode.id,
            modeSnapshot: snapshot,
            sttEngine: context.sttEngine,
            sttModel: context.sttModel,
            llmEngine: nil,
            llmModel: nil,
            language: nil,
            rawTranscript: rawTranscript
        )
    }
}

extension SessionRecord {
    static let formattingSkippedEngine = EngineIdentifier.none
}
