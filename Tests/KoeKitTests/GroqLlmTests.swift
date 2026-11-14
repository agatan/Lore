import Foundation
import Testing

@testable import KoeKit

/// ネットワークに出ずに、組み立てるリクエストと読み取る応答だけを確かめる。
///
/// 本物のキーが要る疎通確認は設定画面の「接続を確認」に任せる。
@Suite(.serialized)
struct GroqLlmTests {
    @Test("Chat Completions の形でリクエストを組む")
    func buildsChatCompletionRequest() async throws {
        StubProtocol.respond { request in
            #expect(request.url?.absoluteString == "https://api.groq.com/openai/v1/chat/completions")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

            let body = try #require(request.bodyData)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["model"] as? String == "test-model")
            // 再現性のため温度は 0 固定(NFR-4)。
            #expect(json["temperature"] as? Double == 0)
            #expect(json["reasoning_effort"] == nil)
            #expect(json["include_reasoning"] == nil)
            #expect(json["response_format"] == nil)

            let messages = try #require(json["messages"] as? [[String: String]])
            #expect(messages.map(\.["role"]) == ["system", "user"])
            #expect(messages[0]["content"] == "指示")
            #expect(messages[1]["content"] == "本文")

            return (200, Self.chatBody("整えた文章"))
        }

        let engine = GroqLlm(model: "test-model", session: StubProtocol.session(), apiKeySource: { "test-key" })
        let output = try await engine.complete(
            prompt: FormattingPrompt(system: "指示", user: "本文"),
            timeout: .seconds(5)
        )
        #expect(output == "整えた文章")
    }

    @Test("API のエラーメッセージをそのまま理由にする")
    func surfacesApiErrorMessage() async throws {
        StubProtocol.respond { _ in
            (404, Data(#"{"error":{"message":"model not found"}}"#.utf8))
        }

        let engine = GroqLlm(model: "no-such-model", session: StubProtocol.session(), apiKeySource: { "test-key" })

        await #expect(throws: EngineError.self) {
            _ = try await engine.complete(
                prompt: FormattingPrompt(system: "指示", user: "本文"),
                timeout: .seconds(5)
            )
        }

        do {
            _ = try await engine.complete(
                prompt: FormattingPrompt(system: "指示", user: "本文"),
                timeout: .seconds(5)
            )
        } catch {
            #expect(error.localizedDescription.contains("model not found"))
            #expect(error.localizedDescription.contains("404"))
        }
    }

    @Test("キーが無ければ通信せずに失敗する")
    func withoutKeyFailsBeforeNetwork() async throws {
        StubProtocol.respond { _ in
            Issue.record("キーが無いのに通信した")
            return (200, Self.chatBody(""))
        }

        let engine = GroqLlm(session: StubProtocol.session(), apiKeySource: { nil })
        #expect(await engine.availability().isReady == false)

        await #expect(throws: EngineError.self) {
            _ = try await engine.complete(
                prompt: FormattingPrompt(system: "指示", user: "本文"),
                timeout: .seconds(5)
            )
        }
    }

    private static func chatBody(_ content: String) -> Data {
        let payload: [String: Any] = [
            "choices": [["message": ["content": content]]],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }
}

/// 応答を差し替えるための `URLProtocol`。
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var handler: ((URLRequest) throws -> (Int, Data))?

    static func respond(_ handler: @escaping (URLRequest) throws -> (Int, Data)) {
        Self.handler = handler
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

private extension URLRequest {
    /// `URLProtocol` に渡る時点で `httpBody` は stream 化されていることがある。
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
