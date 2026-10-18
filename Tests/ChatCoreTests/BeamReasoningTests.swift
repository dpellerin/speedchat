import Foundation
import Testing
@testable import ChatCore

private func beamResponse() -> OpenRouterHTTPResponse {
    OpenRouterHTTPResponse(statusCode: 200, lines: AsyncThrowingStream { continuation in
        continuation.yield(#"data: {"choices":[{"delta":{"reasoning":"private diagnostic reasoning"}}]}"#)
        continuation.yield(#"data: {"choices":[{"delta":{"content":"Visible reply"}}]}"#)
        continuation.yield("data: [DONE]")
        continuation.finish()
    })
}

@Test func beamRequestsReplaySavedReasoning() async throws {
    let messages = try JSONDecoder().decode([ChatMessage].self, from: Data(#"[{"id":"u1","role":"user","text":"Hello"},{"id":"a1","role":"assistant","text":"Hello back","reasoning":"prior private reasoning"},{"id":"u2","role":"user","text":"Continue"}]"#.utf8))
    let fetch: OpenRouterFetch = { request in
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((body["reasoning"] as? [String: Any])?["exclude"] as? Bool == false)
        let sent = try #require(body["messages"] as? [[String: Any]])
        let assistant = try #require(sent.first { $0["role"] as? String == "assistant" })
        #expect(assistant["reasoning"] as? String == "prior private reasoning")
        return beamResponse()
    }
    let reply = try await OpenRouterClient.streamTurn(OpenRouterStreamOptions(
        key: "test-key", model: "reflection/beam-1.0-501b-a23b", instructions: "Test",
        messages: messages, onDelta: { _ in }, onSearching: {}, fetch: fetch
    ))
    #expect(reply == "Visible reply")
}

@Test func beamKeepsLegacyConversationAsContextWithoutFabricatingReasoning() async throws {
    let messages = try JSONDecoder().decode([ChatMessage].self, from: Data(#"[{"id":"u1","role":"user","text":"Remember the word orchard"},{"id":"a1","role":"assistant","text":"I will remember orchard"},{"id":"u2","role":"user","text":"Which word?"},{"id":"a2","role":"assistant","text":"Orchard","reasoning":"prior private reasoning"},{"id":"u3","role":"user","text":"Repeat it"}]"#.utf8))
    let fetch: OpenRouterFetch = { request in
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sent = try #require(body["messages"] as? [[String: Any]])
        let assistants = sent.filter { $0["role"] as? String == "assistant" }
        #expect(assistants.count == 1)
        #expect(assistants.first?["reasoning"] as? String == "prior private reasoning")
        let context = try #require(sent.first { $0["role"] as? String == "user" }?["content"] as? String)
        #expect(context.contains("Remember the word orchard"))
        #expect(context.contains("I will remember orchard"))
        #expect(context.contains("Which word?"))
        #expect(sent.last?["content"] as? String == "Repeat it")
        #expect(body["chat_template_kwargs"] == nil)
        return beamResponse()
    }
    _ = try await OpenRouterClient.streamTurn(OpenRouterStreamOptions(
        key: "test-key", model: "reflection/beam-1.0-501b-a23b", instructions: "Test",
        messages: messages, onDelta: { _ in }, onSearching: {}, fetch: fetch
    ))
}

@Test func beamReasoningSurvivesRestartWithoutAppearingInChatOrOtherProviders() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("beam-replay-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configURL = root.appendingPathComponent("openrouter.json")
    let stateURL = root.appendingPathComponent("state.json")
    try OpenRouterClient.saveConfig(key: "test-key", models: [
        ChatModel(model: "reflection/beam-1.0-501b-a23b", displayName: "Beam", provider: "openrouter"),
        ChatModel(model: "qwen/qwen3.8-flash", displayName: "Qwen", provider: "openrouter")
    ], to: configURL)
    final class Recorder: @unchecked Sendable { var visible = "" }
    let recorder = Recorder()
    let fetch: OpenRouterFetch = { request in
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        for message in messages where message["role"] as? String == "assistant" {
            if body["model"] as? String == "reflection/beam-1.0-501b-a23b" {
                #expect(message["reasoning"] as? String == "private diagnostic reasoning")
            } else {
                #expect(message["reasoning"] == nil)
            }
        }
        return beamResponse()
    }
    let options = ChatClientOptions(openRouterFetch: fetch, openRouterConfigURL: configURL, stateURL: stateURL, env: ["SPEEDCHAT_STATE_DIR": root.path])
    let rpc = FakeCodexTransport(); rpc.failStart = true
    let client = ChatClient(rpc: rpc, options: options)
    _ = try await client.connect()
    let (done, continuation) = AsyncStream<Void>.makeStream()
    client.onDone = { continuation.yield() }
    client.onDelta = { delta, _ in recorder.visible += delta }
    client.onMessage = { _, text in recorder.visible += text }
    try await client.send("Hello")
    for await _ in done { break }
    #expect(!recorder.visible.contains("private diagnostic reasoning"))
    let saved = try #require(StateStore.load(from: stateURL))
    #expect(saved.messages?.last?.reasoning == "private diagnostic reasoning")
    await client.close()

    let restartRPC = FakeCodexTransport(); restartRPC.failStart = true
    let restarted = ChatClient(rpc: restartRPC, options: options)
    let ready = try await restarted.connect()
    #expect(ready.messages.last?.reasoning == "private diagnostic reasoning")
    let (restartedDone, restartedContinuation) = AsyncStream<Void>.makeStream()
    restarted.onDone = { restartedContinuation.yield() }
    try await restarted.send("Continue")
    for await _ in restartedDone { break }
    _ = try await restarted.selectModel("qwen/qwen3.8-flash")
    try await restarted.send("Continue with Qwen")
    for await _ in restartedDone { break }
    await restarted.close()
}
