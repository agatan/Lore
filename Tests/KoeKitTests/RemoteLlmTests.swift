import Foundation
import Testing

@testable import KoeKit

@Suite(.serialized)
struct RemoteLlmTests {
    @Test("OpenAIはResponses APIを使い保存を無効にする")
    func openAIRequest() async throws {
        RemoteStub.respond { request in
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
            let body = try #require(request.bodyData)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["model"] as? String == "gpt-test")
            #expect(json["instructions"] as? String == "指示")
            #expect(json["input"] as? String == "本文")
            #expect(json["store"] as? Bool == false)
            return (200, Data(#"{"output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"結果"}]}]}"#.utf8))
        }
        let engine = RemoteLlm(identifier: .openAI, providerName: "OpenAI", api: .openAI, model: "gpt-test", session: RemoteStub.session(), apiKeySource: { "secret" })
        #expect(try await engine.complete(prompt: .init(system: "指示", user: "本文"), timeout: .seconds(2)) == "結果")
    }

    @Test("ClaudeはMessages APIの認証とsystemを使う")
    func anthropicRequest() async throws {
        RemoteStub.respond { request in
            #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            let body = try #require(request.bodyData)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["system"] as? String == "指示")
            #expect(json["max_tokens"] as? Int == 4_096)
            return (200, Data(#"{"content":[{"type":"text","text":"結果"}]}"#.utf8))
        }
        let engine = RemoteLlm(identifier: .anthropic, providerName: "Claude", api: .anthropic, model: "claude-test", session: RemoteStub.session(), apiKeySource: { "secret" })
        #expect(try await engine.complete(prompt: .init(system: "指示", user: "本文"), timeout: .seconds(2)) == "結果")
    }

    @Test("GeminiはgenerateContentへsystem instructionを渡す")
    func geminiRequest() async throws {
        RemoteStub.respond { request in
            #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent")
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "secret")
            let body = try #require(request.bodyData)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let system = try #require(json["systemInstruction"] as? [String: Any])
            let parts = try #require(system["parts"] as? [[String: String]])
            #expect(parts.first?["text"] == "指示")
            return (200, Data(#"{"candidates":[{"content":{"parts":[{"text":"結果"}]}}]}"#.utf8))
        }
        let engine = RemoteLlm(identifier: .gemini, providerName: "Gemini", api: .gemini, model: "gemini-test", session: RemoteStub.session(), apiKeySource: { "secret" })
        #expect(try await engine.complete(prompt: .init(system: "指示", user: "本文"), timeout: .seconds(2)) == "結果")
    }

    @Test("Ollama互換APIはローカルにだけ送る")
    func ollamaRequest() async throws {
        RemoteStub.respond { request in
            #expect(request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (200, Data(#"{"choices":[{"message":{"content":"結果"}}]}"#.utf8))
        }
        let engine = RemoteLlm(identifier: .ollama, providerName: "Ollama", api: .openAICompatible(baseURL: URL(string: "http://localhost:11434/v1")!, authorizationValue: nil), model: "local-test", session: RemoteStub.session())
        #expect(try await engine.complete(prompt: .init(system: "指示", user: "本文"), timeout: .seconds(2)) == "結果")
    }
}

private final class RemoteStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var handler: ((URLRequest) throws -> (Int, Data))?
    static func respond(_ handler: @escaping (URLRequest) throws -> (Int, Data)) { Self.handler = handler }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemoteStub.self]
        return URLSession(configuration: config)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let handler = Self.handler else { return }
        do {
            let (status, data) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

private extension URLRequest {
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
