import Foundation

/// 選べるモデルを 1 段のリストとして定義する。
///
/// 「エンジンを選んでからモデルを選ぶ」二段構えは実装の都合であってユーザーの関心ではない。
/// 「Apple 標準」「Whisper large-v3-turbo」…と並べて、正確さと速さで選べるようにする。
public struct ModelChoice: Identifiable, Sendable, Hashable {
    /// 正確さ・速さの目安(1...5)。
    public struct Rating: Sendable, Hashable {
        public var accuracy: Int
        public var speed: Int

        public init(accuracy: Int, speed: Int) {
            self.accuracy = accuracy
            self.speed = speed
        }
    }

    public var id: String
    public var engine: EngineIdentifier
    /// エンジンが複数モデルを持つ場合のモデル ID。標準エンジンは nil。
    public var modelID: String?
    public var name: String
    /// ユーザー向けの一行説明。
    public var summary: String
    public var rating: Rating
    /// 追加ダウンロードのサイズ。nil = ダウンロード不要。
    public var downloadBytes: Int64?

    public init(
        engine: EngineIdentifier,
        modelID: String? = nil,
        name: String,
        summary: String,
        rating: Rating,
        downloadBytes: Int64? = nil
    ) {
        self.id = modelID.map { "\(engine.rawValue)/\($0)" } ?? engine.rawValue
        self.engine = engine
        self.modelID = modelID
        self.name = name
        self.summary = summary
        self.rating = rating
        self.downloadBytes = downloadBytes
    }

    public var requiresDownload: Bool { downloadBytes != nil }

    public var downloadSizeText: String? {
        downloadBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    /// 実測レイテンシを引くためのキー。履歴の記録と対応させる。
    public func latencyKey(modelName: String?) -> String {
        HistoryStore.key(engine.rawValue, modelName)
    }
}

/// 聞き取り(音声 → 文字)の選択肢。
public enum TranscriptionCatalog {
    public static let all: [ModelChoice] = [
        ModelChoice(
            engine: .speechAnalyzer,
            name: "Apple 標準",
            summary: "話しながら文字になり、話し終わるとすぐ挿入されます。追加ダウンロードなしで使えます。",
            rating: .init(accuracy: 3, speed: 5)
        ),
        ModelChoice(
            engine: .whisperKit,
            modelID: "openai_whisper-large-v3-v20240930_turbo_632MB",
            name: "Whisper large-v3-turbo",
            summary: "専門用語や英語混じりの聞き取りに強い。話し終わってからまとめて聞き取るため少し待ちます。",
            rating: .init(accuracy: 4, speed: 3),
            downloadBytes: 632 * 1_000_000
        ),
        ModelChoice(
            engine: .whisperKit,
            modelID: "openai_whisper-large-v3-v20240930_626MB",
            name: "Whisper large-v3",
            summary: "いちばん正確に聞き取ります。turbo より待ち時間が長くなります。",
            rating: .init(accuracy: 5, speed: 2),
            downloadBytes: 626 * 1_000_000
        ),
        ModelChoice(
            engine: .whisperKit,
            modelID: "openai_whisper-base",
            name: "Whisper base",
            summary: "軽くて速いぶん聞き間違いが増えます。動作確認向け。",
            rating: .init(accuracy: 2, speed: 4),
            downloadBytes: 145 * 1_000_000
        ),
    ]

    public static func choice(engine: EngineIdentifier, modelID: String?) -> ModelChoice? {
        all.first { $0.engine == engine && ($0.modelID == modelID || $0.modelID == nil) }
    }
}

/// 文章の仕上げ(文字 → 整った文)の選択肢。
public enum FormattingCatalog {
    public static let all: [ModelChoice] = [
        ModelChoice(
            engine: .foundationModels,
            name: "Apple 標準",
            summary: "追加ダウンロードなしで使えます。フィラー除去や句読点は十分ですが、細かい指示には従いきれないことがあります。",
            rating: .init(accuracy: 3, speed: 5)
        ),
        ModelChoice(
            engine: .mlx,
            modelID: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            name: "Qwen3 4B",
            summary: "モードの指示や語彙の指定に従いやすく、箇条書きや文体の指定が効きます。",
            rating: .init(accuracy: 4, speed: 3),
            downloadBytes: 2_400_000_000
        ),
        ModelChoice(
            engine: .mlx,
            modelID: "mlx-community/Qwen3-8B-4bit",
            name: "Qwen3 8B",
            summary: "いちばん丁寧に仕上がります。メモリ使用量と待ち時間が増えます。",
            rating: .init(accuracy: 5, speed: 2),
            downloadBytes: 4_600_000_000
        ),
        ModelChoice(
            engine: .mlx,
            modelID: "mlx-community/Qwen3-1.7B-4bit",
            name: "Qwen3 1.7B",
            summary: "いちばん速い。短い文の仕上げ向け。",
            rating: .init(accuracy: 2, speed: 4),
            downloadBytes: 1_000_000_000
        ),
    ]

    public static func choice(engine: EngineIdentifier, modelID: String?) -> ModelChoice? {
        all.first { $0.engine == engine && ($0.modelID == modelID || $0.modelID == nil) }
    }
}

// MARK: - エンジン内部で使うモデル ID

public enum WhisperModelCatalog {
    public static let defaultModelID = "openai_whisper-large-v3-v20240930_turbo_632MB"
}

public enum MlxModelCatalog {
    public static let defaultModelID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

    public static func name(for id: String) -> String? {
        FormattingCatalog.all.first { $0.modelID == id }?.name
    }
}
