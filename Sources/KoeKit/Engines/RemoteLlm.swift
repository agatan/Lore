import Foundation
import Synchronization

/// クラウド各社とローカルサーバーのAPI差を、`LlmEngine` の内側に閉じ込める。
public final class RemoteLlm: LlmEngine {
    public enum API: Sendable {
        case openAI
        case anthropic
        case gemini
        case openAICompatible(baseURL: URL, authorizationValue: String?)
    }

    public let identifier: EngineIdentifier
    public let providerName: String
    private let api: API
    private let model: Mutex<String>
    private let defaultModel: String
    private let session: URLSession
    private let apiKeySource: @Sendable () throws -> String?
    private let usageSink = Mutex<LlmUsageSink?>(nil)

    public init(
        identifier: EngineIdentifier,
        providerName: String,
        api: API,
        model: String,
        session: URLSession = .shared,
        apiKeySource: @escaping @Sendable () throws -> String? = { nil }
    ) {
        self.identifier = identifier
        self.providerName = providerName
        self.api = api
        self.model = Mutex(model)
        self.defaultModel = model
        self.session = session
        self.apiKeySource = apiKeySource
    }

    public var modelName: String? { model.withLock { $0 } }
    public var inputCharacterBudget: Int { 24_000 }

    public func apply(model newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        model.withLock { $0 = trimmed.isEmpty ? defaultModel : trimmed }
    }

    public func setUsageSink(_ sink: LlmUsageSink?) {
        usageSink.withLock { $0 = sink }
    }

    public func availability() async -> EngineAvailability {
        guard requiresApiKey else { return .ready }
        do {
            guard try apiKeySource()?.isEmpty == false else {
                return .unavailable("\(providerName) のAPIキーが未設定です")
            }
            return .ready
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    public func complete(prompt: FormattingPrompt, timeout: Duration) async throws -> String {
        let request = try makeCompletionRequest(prompt: prompt)
        let (data, response) = try await withEngineTimeout(timeout) { [session] in
            try await session.data(for: request)
        }
        try checkStatus(response, data: data)
        let output: String
        let usage: LlmTokenUsage?
        switch api {
        case .openAI:
            let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            output = response.output.flatMap { $0.content ?? [] }.compactMap(\.text).joined(separator: "\n")
            usage = response.usage.map { .init(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, totalTokens: $0.totalTokens) }
        case .anthropic:
            let response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
            output = response.content.compactMap(\.text).joined(separator: "\n")
            usage = response.usage.map { .init(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, totalTokens: $0.inputTokens + $0.outputTokens) }
        case .gemini:
            let response = try JSONDecoder().decode(GeminiResponse.self, from: data)
            output = response.candidates.flatMap(\.content.parts).compactMap(\.text).joined(separator: "\n")
            usage = response.usageMetadata.map {
                let input = $0.promptTokenCount ?? 0
                let output = $0.candidatesTokenCount ?? 0
                return .init(
                    inputTokens: input,
                    outputTokens: output,
                    totalTokens: $0.totalTokenCount ?? input + output
                )
            }
        case .openAICompatible:
            let response = try JSONDecoder().decode(ChatResponse.self, from: data)
            output = response.choices.first?.message.content ?? ""
            usage = response.usage.map { .init(inputTokens: $0.promptTokens, outputTokens: $0.completionTokens, totalTokens: $0.totalTokens) }
        }
        let cleaned = Self.strippingReasoning(output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw EngineError.failed("\(providerName) が空の応答を返しました") }
        if let usage { usageSink.withLock { $0 }?(identifier, modelName, usage) }
        return cleaned
    }

    public func availableModels() async throws -> [String] {
        let request = try makeModelsRequest()
        let (data, response) = try await session.data(for: request)
        try checkStatus(response, data: data)
        switch api {
        case .gemini:
            return try JSONDecoder().decode(GeminiModels.self, from: data).models
                .filter { $0.supportedGenerationMethods?.contains("generateContent") != false }
                .map { $0.name.replacingOccurrences(of: "models/", with: "") }.sorted()
        default:
            return try JSONDecoder().decode(ModelList.self, from: data).data.map(\.id).sorted()
        }
    }

    public func unload() async {}

    private var requiresApiKey: Bool {
        switch api {
        case .openAI, .anthropic, .gemini: true
        case .openAICompatible: false
        }
    }

    private func makeCompletionRequest(prompt: FormattingPrompt) throws -> URLRequest {
        let selectedModel = modelName ?? defaultModel
        var request: URLRequest
        switch api {
        case .openAI:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            request.httpBody = try JSONEncoder().encode(OpenAIRequest(model: selectedModel, instructions: prompt.system, input: prompt.user, store: false))
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONEncoder().encode(AnthropicRequest(model: selectedModel, maxTokens: 4_096, system: prompt.system, messages: [.init(role: "user", content: prompt.user)]))
        case .gemini:
            let escaped = selectedModel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? selectedModel
            request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(escaped):generateContent")!)
            request.httpBody = try JSONEncoder().encode(GeminiRequest(systemInstruction: .init(parts: [.init(text: prompt.system)]), contents: [.init(parts: [.init(text: prompt.user)])], generationConfig: .init(temperature: 0)))
        case .openAICompatible(let baseURL, let authorizationValue):
            request = URLRequest(url: baseURL.appending(path: "chat/completions"))
            if let authorizationValue { request.setValue(authorizationValue, forHTTPHeaderField: "Authorization") }
            request.httpBody = try JSONEncoder().encode(ChatRequest(model: selectedModel, temperature: 0, messages: [.init(role: "system", content: prompt.system), .init(role: "user", content: prompt.user)]))
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try applyCredential(to: &request)
        return request
    }

    private func makeModelsRequest() throws -> URLRequest {
        let url: URL
        switch api {
        case .openAI: url = URL(string: "https://api.openai.com/v1/models")!
        case .anthropic: url = URL(string: "https://api.anthropic.com/v1/models")!
        case .gemini: url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        case .openAICompatible(let baseURL, let authorizationValue):
            url = baseURL.appending(path: "models")
            var request = URLRequest(url: url)
            if let authorizationValue { request.setValue(authorizationValue, forHTTPHeaderField: "Authorization") }
            return request
        }
        var request = URLRequest(url: url)
        if case .anthropic = api { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        try applyCredential(to: &request)
        return request
    }

    private func applyCredential(to request: inout URLRequest) throws {
        guard requiresApiKey else { return }
        guard let key = try apiKeySource(), !key.isEmpty else {
            throw EngineError.notReady("\(providerName) のAPIキーが未設定です。利用するAI設定で登録してください")
        }
        switch api {
        case .anthropic: request.setValue(key, forHTTPHeaderField: "x-api-key")
        case .gemini: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        default: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw EngineError.failed("\(providerName) から想定外の応答を受け取りました")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = Self.apiErrorMessage(data) ?? String(data: data, encoding: .utf8) ?? ""
            throw EngineError.failed("\(providerName) が \(http.statusCode) を返しました\(detail.isEmpty ? "" : ": \(detail)")")
        }
    }

    private static func apiErrorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }

    static func strippingReasoning(_ text: String) -> String {
        guard let close = text.range(of: "</think>") else { return text }
        return String(text[close.upperBound...])
    }

    private struct OpenAIRequest: Encodable { let model: String; let instructions: String; let input: String; let store: Bool }
    private struct OpenAIResponse: Decodable {
        struct Output: Decodable { let content: [Content]? }
        struct Content: Decodable { let text: String? }
        let output: [Output]
        let usage: Usage?
        struct Usage: Decodable {
            let inputTokens: Int
            let outputTokens: Int
            let totalTokens: Int
            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case totalTokens = "total_tokens"
            }
        }
    }
    private struct AnthropicRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Message]
        enum CodingKeys: String, CodingKey { case model; case maxTokens = "max_tokens"; case system; case messages }
    }
    private struct AnthropicResponse: Decodable {
        struct Content: Decodable { let text: String? }
        struct Usage: Decodable {
            let inputTokens: Int
            let outputTokens: Int
            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }
        let content: [Content]
        let usage: Usage?
    }
    private struct GeminiRequest: Encodable {
        struct Content: Encodable { let parts: [Part] }
        struct Part: Encodable { let text: String }
        struct Config: Encodable { let temperature: Double }
        let systemInstruction: Content
        let contents: [Content]
        let generationConfig: Config
    }
    private struct GeminiResponse: Decodable {
        struct Candidate: Decodable { let content: Content }
        struct Content: Decodable { let parts: [Part] }
        struct Part: Decodable { let text: String? }
        let candidates: [Candidate]
        let usageMetadata: Usage?
        struct Usage: Decodable {
            let promptTokenCount: Int?
            let candidatesTokenCount: Int?
            let totalTokenCount: Int?
        }
    }
    private struct GeminiModels: Decodable {
        struct Model: Decodable { let name: String; let supportedGenerationMethods: [String]? }
        let models: [Model]
    }
    private struct ChatRequest: Encodable { struct Message: Encodable { let role: String; let content: String }; let model: String; let temperature: Double; let messages: [Message] }
    private struct ChatResponse: Decodable {
        struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }
        struct Usage: Decodable {
            let promptTokens: Int
            let completionTokens: Int
            let totalTokens: Int
            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case totalTokens = "total_tokens"
            }
        }
        let choices: [Choice]
        let usage: Usage?
    }
    private struct ModelList: Decodable { struct Entry: Decodable { let id: String }; let data: [Entry] }
}
