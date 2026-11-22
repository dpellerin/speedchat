import Foundation
import Testing
@testable import ChatCore

@Test func confirmedCodexDeliverySurvivesFailedReply() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-delivery-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let options = ChatClientOptions(
        openRouterConfigURL: dir.appendingPathComponent("openrouter.json"), stateURL: stateURL, env: [:]
    )
    let history = [
        ChatMessage(id: "earlier-user", role: "user", text: "Remember the orchard."),
        ChatMessage(id: "earlier-assistant", role: "assistant", text: "Orchard remembered."),
    ]
    try StateStore.save(threadId: "openrouter-history", model: "gpt-6-luna", to: stateURL,
                        messages: history, codexSyncedCount: 0)
    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: options)
    _ = try await client.connect()
    try await client.send("Which place did I mention?")

    let delivery = try #require(rpc.calls.last { $0.method == "turn/start" })
    let payload = try #require(delivery.params["input"] as? [[String: Any]])
    #expect(payload.first?["text"] as? String == """
        [Earlier turns in this conversation from another model:
        User: Remember the orchard.

        Assistant: Orchard remembered.]

        Which place did I mention?
        """)
    let clientId = try #require(delivery.params["clientUserMessageId"] as? String)
    rpc.onNotification?(CodexNotification(method: "item/started", params: [
        "threadId": "dedicated", "turnId": "turn-1",
        "item": ["id": "recorded-input", "type": "userMessage", "clientId": clientId, "content": payload],
    ]))
    let recordedHistory = history + [ChatMessage(id: clientId, role: "user", text: "Which place did I mention?")]
    let beforeFailure = ChatClient(rpc: FakeCodexTransport(), options: options)
    let recorded = try await beforeFailure.connect()
    #expect(recorded.messages == recordedHistory)
    await beforeFailure.close()

    rpc.onNotification?(CodexNotification(method: "turn/completed", params: [
        "threadId": "dedicated", "turn": ["id": "turn-1", "status": "failed"],
    ]))
    await client.close()

    let reopenedRPC = FakeCodexTransport()
    reopenedRPC.resumeResult = .success(CodexPayload(["thread": ["id": "dedicated", "turns": []]]))
    let reopened = ChatClient(rpc: reopenedRPC, options: options)
    let ready = try await reopened.connect()
    #expect(ready.messages == recordedHistory)
    try await reopened.send("Please continue.")
    let followUp = try #require(reopenedRPC.calls.last { $0.method == "turn/start" })
    #expect(followUp.params["threadId"] as? String == "dedicated")
    #expect((followUp.params["input"] as? [[String: Any]])?.first?["text"] as? String == "Please continue.")
    await reopened.close()
}

@Test(arguments: ["matching", "wrong thread", "wrong turn", "wrong client ID", "wrong wire text", "no item"])
func stoppedCodexReplyOnlyPreservesProvenDelivery(evidence: String) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-delivery-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let configURL = dir.appendingPathComponent("openrouter.json")
    try OpenRouterClient.saveConfig(key: "test-key", to: configURL)
    let options = ChatClientOptions(
        openRouterFetch: { _ in
            OpenRouterHTTPResponse(statusCode: 200, lines: AsyncThrowingStream { stream in
                stream.yield(#"data: {"choices":[{"delta":{"content":"I see the grove."}}]}"#)
                stream.yield("data: [DONE]")
                stream.finish()
            })
        },
        openRouterConfigURL: configURL, stateURL: stateURL, env: [:]
    )
    let history = [ChatMessage(id: "earlier-message", role: "assistant", text: "See the orchard.")]
    try StateStore.save(threadId: "openrouter-history", model: "gpt-6-luna", to: stateURL,
                        messages: history, codexSyncedCount: 0)
    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: options)
    _ = try await client.connect()
    try await client.send("Tell me more.")

    let delivery = try #require(rpc.calls.last { $0.method == "turn/start" })
    let clientId = try #require(delivery.params["clientUserMessageId"] as? String)
    let payload = try #require(delivery.params["input"] as? [[String: Any]])
    if evidence != "no item" {
        rpc.onNotification?(CodexNotification(method: "item/completed", params: [
            "threadId": evidence == "wrong thread" ? "another-thread" : "dedicated",
            "turnId": evidence == "wrong turn" ? "earlier-turn" : "turn-1",
            "item": [
                "id": "codex-user", "type": "userMessage",
                "clientId": evidence == "wrong client ID" ? "earlier-attempt" : clientId,
                "content": evidence == "wrong wire text" ? [["type": "text", "text": "Tell me more."]] : payload,
            ],
        ]))
    }
    rpc.onNotification?(CodexNotification(method: "turn/completed", params: [
        "threadId": "dedicated", "turn": ["id": "earlier-turn", "status": "completed"],
    ]))
    #expect(client.busy)

    await client.interrupt()
    let interrupt = try #require(rpc.calls.last { $0.method == "turn/interrupt" })
    #expect(interrupt.params["threadId"] as? String == "dedicated")
    #expect(interrupt.params["turnId"] as? String == "turn-1")
    rpc.onNotification?(CodexNotification(method: "turn/completed", params: [
        "threadId": "dedicated", "turn": ["id": "turn-1", "status": "interrupted"],
    ]))
    await client.close()

    let reopenedRPC = FakeCodexTransport()
    reopenedRPC.resumeResult = .success(CodexPayload(["thread": ["id": "dedicated", "turns": []]]))
    let reopened = ChatClient(rpc: reopenedRPC, options: options)
    let ready = try await reopened.connect()
    #expect(ready.messages == history + [ChatMessage(id: clientId, role: "user", text: "Tell me more.")])

    _ = try await reopened.selectModel("deepseek/deepseek-v4.1-flash")
    let (results, result) = AsyncStream<Bool>.makeStream()
    reopened.onDone = { result.yield(true) }
    reopened.onError = { _ in result.yield(false) }
    try await reopened.send("What is nearby?")
    var completion = results.makeAsyncIterator()
    try #require(await completion.next() == true)
    _ = try await reopened.selectModel("gpt-6-luna")
    try await reopened.send("Continue.")
    let followUp = try #require(reopenedRPC.calls.last { $0.method == "turn/start" })
    let followUpText = (followUp.params["input"] as? [[String: Any]])?.first?["text"] as? String
    let earlierHistory = """
        Assistant: See the orchard.

        User: Tell me more.
        """ + "\n\n"
    let quotedHistory = """
        [Earlier turns in this conversation from another model:
        \(evidence == "matching" ? "" : earlierHistory)User: What is nearby?

        Assistant: I see the grove.]

        Continue.
        """
    #expect(followUpText == quotedHistory)
    await reopened.close()
}
