import Foundation
import Synchronization

/// Groq の Chat Completions API による整形。
///
/// **このエンジンが動くとき、文字起こしと指示文は Groq に送られる**
/// (`FormattingBackend.groq`)。既定はオンデバイスのままで、ユーザーが設定で
/// 明示的に選んだときだけこちらに切り替わる。
///
/// 失敗の扱いは他のエンジンと同じ: throw して呼び出し側のフォールバックに委ねる。
/// 整形できなければ生テキストがそのまま挿入される(C-43)ので、
/// ネットワークが不調でも発話は失われない。
public final class GroqLlm: LlmEngine {
    public let identifier = EngineIdentifier.groq

    /// 既定のモデル。設定画面から Groq に問い合わせて選び直せる。
    public static let defaultModel = "openai/gpt-oss-120b"
    static let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    static let modelsEndpoint = URL(string: "https://api.groq.com/openai/v1/models")!

    /// モデル ID は設定から流し込まれ、`modelName`(同期プロパティ)から読まれる。
    private let model: Mutex<String>
    private let session: URLSession
    /// キーの取り出し方。既定は Keychain だが、テストが本物の Keychain を
    /// 触らずに済むよう注入できるようにしてある。
    private let apiKeySource: @Sendable () throws -> String?

    public init(
        model: String = GroqLlm.defaultModel,
        session: URLSession = .shared,
        apiKeySource: @escaping @Sendable () throws -> String? = { try SecretStore.read(.groqApiKey) }
    ) {
        self.model = Mutex(model)
        self.session = session
        self.apiKeySource = apiKeySource
    }

    /// 履歴には「どのモデルで整形したか」がそのまま残る(監査性)。
    public var modelName: String? { model.withLock { $0 } }

    public func apply(model newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        model.withLock { $0 = trimmed.isEmpty ? Self.defaultModel : trimmed }
    }

    /// クラウドのモデルはコンテキスト窓が桁違いに広いが、
    /// 1 回のリクエストを無制限に大きくする理由も無いので控えめに宣言する。
    public var inputCharacterBudget: Int { 24_000 }

    public func availability() async -> EngineAvailability {
        do {
            guard let key = try apiKeySource(), !key.isEmpty else {
                return .unavailable(String(lore: "Groq の API キーが未設定です"))
            }
            return .ready
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    public func complete(prompt: FormattingPrompt, timeout: Duration) async throws -> String {
        let key = try apiKey()
        let model = modelName ?? Self.defaultModel

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: model,
                // 再現性(NFR-4)のため温度は 0 固定。整形は生成ではなく変換なので、
                // 同じ入力からは同じ結果が出てほしい。
                temperature: 0,
                messages: [
                    .init(role: "system", content: prompt.system),
                    .init(role: "user", content: prompt.user),
                ]
            )
        )

        let sending = request
        let (data, response) = try await withEngineTimeout(timeout) { [session] in
            try await session.data(for: sending)
        }
        try Self.checkStatus(response, data: data)

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw EngineError.failed(String(lore: "Groq が空の応答を返しました"))
        }
        return Self.strippingReasoning(content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 設定画面のモデル選択用。キーが正しいかの確認も兼ねる。
    public func availableModels() async throws -> [String] {
        var request = URLRequest(url: Self.modelsEndpoint)
        request.setValue("Bearer \(try apiKey())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data: data)
        return try JSONDecoder().decode(ModelList.self, from: data).data.map(\.id).sorted()
    }

    public func unload() async {
        // 保持しているモデルが無いので解放するものもない。
    }

    private func apiKey() throws -> String {
        guard let key = try apiKeySource(), !key.isEmpty else {
            throw EngineError.notReady(String(lore: "Groq の API キーが未設定です。設定 > AIプロバイダ で登録してください"))
        }
        return key
    }

    private static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw EngineError.failed(String(lore: "Groq から想定外の応答を受け取りました"))
        }
        guard (200..<300).contains(http.statusCode) else {
            // API 側のメッセージをそのまま見せる。モデル ID の間違いやキーの失効は
            // ここで理由が分からないと直しようがない。
            let detail = (try? JSONDecoder().decode(ApiError.self, from: data))?.error.message
                ?? String(data: data, encoding: .utf8)
                ?? ""
            throw EngineError.failed(String(lore: "Groq が \(http.statusCode) を返しました\(detail.isEmpty ? "" : ": \(detail)")"))
        }
    }

    /// 推論を出すモデルは `<think>…</think>` を本文の前に付けてくることがある。
    /// そのまま挿入すると事故になるので落とす。
    static func strippingReasoning(_ text: String) -> String {
        guard let close = text.range(of: "</think>") else { return text }
        return String(text[close.upperBound...])
    }

    // MARK: JSON

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let temperature: Double
        let messages: [Message]
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct ModelList: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
    }

    private struct ApiError: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }
}
