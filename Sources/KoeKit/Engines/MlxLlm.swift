import Foundation
import MLXLLM
import MLXLMCommon

/// MLX でアプリ内にモデルをロードして整形する。品質の天井を上げるための選択肢(設計 D-5)。
public final class MlxLlm: LlmEngine {
    public let identifier = EngineIdentifier.mlx

    private let state = State()
    private let modelID: @Sendable () -> String

    public init(modelID: @escaping @Sendable () -> String) {
        self.modelID = modelID
    }

    public var modelName: String? {
        let id = modelID()
        return MlxModelCatalog.name(for: id) ?? id
    }

    /// MLX の Metal カーネル(default.metallib)がバンドルに入っているか。
    ///
    /// mlx-swift の Metal シェーダは SwiftPM の CLI ビルドではコンパイルできず、
    /// 欠けたまま MLX を呼ぶとプロセスが落ちる。呼ぶ前に必ずここで弾く。
    public static var isMetalLibraryBundled: Bool {
        if Bundle.main.url(
            forResource: "default",
            withExtension: "metallib",
            subdirectory: "mlx-swift_Cmlx.bundle"
        ) != nil {
            return true
        }
        return Bundle.main.url(forResource: "default", withExtension: "metallib") != nil
    }

    static let metalMissingMessage =
        "この Koe は Metal シェーダ無しでビルドされているため MLX を使えません(Metal ツールチェーンを入れて make app し直してください)"

    public func availability() async -> EngineAvailability {
        guard Self.isMetalLibraryBundled else {
            return .unavailable(Self.metalMissingMessage)
        }
        let id = modelID()
        guard ModelStore.isDownloaded(mlxModelID: id) else {
            return .needsDownload("モデル(\(modelName ?? id))の取得が必要です")
        }
        return .ready
    }

    public func complete(prompt: FormattingPrompt, timeout: Duration) async throws -> String {
        guard Self.isMetalLibraryBundled else {
            throw EngineError.notReady(Self.metalMissingMessage)
        }
        let id = modelID()
        guard ModelStore.isDownloaded(mlxModelID: id) else {
            throw EngineError.notReady("モデル(\(modelName ?? id))が取得されていません")
        }
        let container = try await state.container(for: id, progress: nil)
        let parameters = GenerateParameters(
            maxTokens: Self.tokenBudget(for: prompt.user),
            // 再現性(NFR-4)のため温度 0 固定。整形は創作ではない。
            temperature: 0
        )

        return try await withEngineTimeout(timeout) {
            let session = ChatSession(
                container,
                instructions: prompt.system,
                generateParameters: parameters
            )
            return try await session.respond(to: prompt.user)
        }
    }

    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard Self.isMetalLibraryBundled else {
            throw EngineError.notReady(Self.metalMissingMessage)
        }
        _ = try await state.container(for: modelID(), progress: progress)
        progress(1)
    }

    public func unload() async {
        await state.reset()
    }

    static func tokenBudget(for input: String) -> Int {
        min(4_096, max(256, input.count * 2))
    }

    /// ロード済みモデルを保持する。アイドル時は unload() で解放する(NFR-5)。
    private actor State {
        private var loaded: (id: String, container: ModelContainer)?

        func container(
            for id: String,
            progress: (@Sendable (Double) -> Void)?
        ) async throws -> ModelContainer {
            if let loaded, loaded.id == id { return loaded.container }
            let container = try await LLMModelFactory.shared.loadContainer(
                hub: ModelStore.mlxHub,
                configuration: ModelConfiguration(id: id)
            ) { fraction in
                progress?(fraction.fractionCompleted)
            }
            loaded = (id, container)
            return container
        }

        func reset() {
            loaded = nil
        }
    }
}
