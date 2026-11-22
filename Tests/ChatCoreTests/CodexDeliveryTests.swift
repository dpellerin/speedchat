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
    if evidence != "matching" {
        let checked = try #require(try await reopened.retryCodexSend())
        #expect(checked.codexRetry?.action == .resend)
        #expect(!reopenedRPC.calls.contains { $0.method == "turn/start" })
        _ = try await reopened.retryCodexSend(resend: true)
        let resent = try #require(reopenedRPC.calls.last { $0.method == "turn/start" })
        let resentPayload = try #require(resent.params["input"] as? [[String: Any]])
        #expect(resentPayload.first?["text"] as? String == payload.first?["text"] as? String)
        #expect(resent.params["clientUserMessageId"] as? String != clientId)
        reopenedRPC.onNotification?(CodexNotification(method: "item/started", params: [
            "threadId": "dedicated", "turnId": "turn-1",
            "item": ["id": "resent-input", "type": "userMessage",
                     "clientId": resent.params["clientUserMessageId"] as? String ?? "", "content": resentPayload],
        ]))
        reopenedRPC.onNotification?(CodexNotification(method: "item/completed", params: [
            "threadId": "dedicated", "turnId": "turn-1",
            "item": ["id": "resent-reply", "type": "agentMessage", "text": "It is two miles away."],
        ]))
        reopenedRPC.onNotification?(CodexNotification(method: "turn/completed", params: [
            "threadId": "dedicated", "turn": ["id": "turn-1", "status": "completed"],
        ]))
        let updated = try await reopened.selectModel("gpt-6-luna")
        #expect(updated.messages.map(\.text) == [
            "See the orchard.", "Tell me more.", "It is two miles away.", "What is nearby?", "I see the grove.",
        ])
        #expect(updated.messages[1].id == clientId)
    }
    try await reopened.send("Continue.")
    let followUp = try #require(reopenedRPC.calls.last { $0.method == "turn/start" })
    let followUpText = (followUp.params["input"] as? [[String: Any]])?.first?["text"] as? String
    #expect(followUpText == """
        [Earlier turns in this conversation from another model:
        User: What is nearby?

        Assistant: I see the grove.]

        Continue.
        """)
    await reopened.close()
}

@Test func lostAcknowledgementRestoresRecordedPromptAndReply() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-recovery-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let options = ChatClientOptions(
        openRouterConfigURL: dir.appendingPathComponent("openrouter.json"), stateURL: stateURL, env: [:]
    )
    let history = [ChatMessage(id: "old-reply", role: "assistant", text: "The orchard is nearby.")]
    try StateStore.save(threadId: "original-thread", model: "gpt-6-luna", to: stateURL,
                        messages: history, codexSyncedCount: 0)
    let rpc = FakeCodexTransport()
    rpc.resumeResult = .success(CodexPayload(["thread": ["id": "original-thread", "turns": []]]))
    rpc.turnStartError = NSError(domain: "test", code: -2)
    let client = ChatClient(rpc: rpc, options: options)
    _ = try await client.connect()
    await #expect(throws: (any Error).self) { try await client.send("How far away?") }
    let submitted = try #require(rpc.calls.first { $0.method == "turn/start" })
    let id = try #require(submitted.params["clientUserMessageId"] as? String)
    let input = try #require(submitted.params["input"] as? [[String: Any]])
    await client.close()

    let newRPC = FakeCodexTransport()
    newRPC.resumeResult = .success(CodexPayload(["thread": ["id": "original-thread", "turns": [
        ["id": "recorded-turn", "items": [
            ["id": "recorded-input", "type": "userMessage", "clientId": id, "content": input],
            ["id": "recorded-reply", "type": "agentMessage", "text": "Two miles."],
        ]],
    ]]]))
    let reopened = ChatClient(rpc: newRPC, options: options)
    let ready = try await reopened.connect()
    #expect(ready.messages == history + [
        ChatMessage(id: id, role: "user", text: "How far away?"),
        ChatMessage(id: "recorded-reply", role: "assistant", text: "Two miles."),
    ])
    #expect(!newRPC.calls.contains { $0.method == "turn/start" })
    try await reopened.send("Is there parking?")
    let next = try #require(newRPC.calls.first { $0.method == "turn/start" })
    #expect((next.params["input"] as? [[String: Any]])?.first?["text"] as? String == "Is there parking?")
    await reopened.close()
}

@Test(arguments: [false, true])
func retryFindsAcceptedPromptOnItsOriginalThread(relaunch: Bool) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-recovery-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let options = ChatClientOptions(
        openRouterConfigURL: dir.appendingPathComponent("openrouter.json"),
        stateURL: dir.appendingPathComponent("state.json"), env: [:]
    )
    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: options)
    let original = try await client.connect()
    rpc.turnStartError = NSError(domain: "test", code: -2)
    await #expect(throws: (any Error).self) { try await client.send("When does it open?") }
    let submitted = try #require(rpc.calls.first { $0.method == "turn/start" })
    let id = try #require(submitted.params["clientUserMessageId"] as? String)
    let input = try #require(submitted.params["input"] as? [[String: Any]])

    let retryRPC = relaunch ? FakeCodexTransport() : rpc
    let retryClient = relaunch ? ChatClient(rpc: retryRPC, options: options) : client
    if relaunch {
        await client.close()
        retryRPC.resumeResult = .failure(CodexRPCError(
            code: -32600, message: "no rollout found for thread id \(original.threadId)"
        ))
        let reopened = try await retryClient.connect()
        #expect(reopened.messages == [ChatMessage(id: id, role: "user", text: "When does it open?")])
        #expect(reopened.codexRetry?.action == .checkDelivery)
    }
    retryRPC.readResult = .success(CodexPayload(["thread": ["id": original.threadId, "turns": [
        ["id": "recorded-turn", "items": [
            ["id": "recorded-input", "type": "userMessage", "clientId": id, "content": input],
            ["id": "recorded-reply", "type": "agentMessage", "text": "Seven o’clock."],
        ]],
    ]]]))

    let checked = try #require(try await retryClient.retryCodexSend())
    #expect(checked.messages == [
        ChatMessage(id: id, role: "user", text: "When does it open?"),
        ChatMessage(id: "recorded-reply", role: "assistant", text: "Seven o’clock."),
    ])
    #expect(checked.codexRetry == nil)
    #expect(retryRPC.calls.last { $0.method == "thread/read" }?.params["threadId"] as? String == original.threadId)
    #expect(retryRPC.calls.filter { $0.method == "turn/start" }.count == (relaunch ? 0 : 1))
    #expect(retryRPC.calls.filter { $0.method == "thread/start" }.count == (relaunch ? 0 : 1))
    await retryClient.close()
}

@Test(arguments: [false, true])
func rejectedCodexSendRetriesTheSameMessageAfterReattaching(relaunch: Bool) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-recovery-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let options = ChatClientOptions(
        openRouterConfigURL: dir.appendingPathComponent("openrouter.json"),
        stateURL: dir.appendingPathComponent("state.json"), env: [:]
    )
    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: options)
    let original = try await client.connect()
    rpc.turnStartError = CodexRPCError(code: -32600, message: "thread not found: \(original.threadId)")
    await #expect(throws: (any Error).self) { try await client.send("When does it open?") }
    let first = try #require(rpc.calls.first { $0.method == "turn/start" })
    let id = try #require(first.params["clientUserMessageId"] as? String)

    let retryRPC = relaunch ? FakeCodexTransport() : rpc
    let retryClient = relaunch ? ChatClient(rpc: retryRPC, options: options) : client
    retryRPC.turnStartError = nil
    retryRPC.resumeResult = .success(CodexPayload(["thread": ["id": original.threadId, "turns": []]]))
    if relaunch {
        await client.close()
        let reopened = try await retryClient.connect()
        #expect(reopened.messages == [ChatMessage(id: id, role: "user", text: "When does it open?")])
    }
    #expect(retryClient.codexRetry?.action == .retry)
    _ = try await retryClient.retryCodexSend()
    let retried = try #require(retryRPC.calls.last { $0.method == "turn/start" })
    #expect(retryRPC.calls.filter { $0.method == "turn/start" }.count == (relaunch ? 1 : 2))
    #expect(retryRPC.calls.contains { $0.method == "thread/resume" && $0.params["threadId"] as? String == original.threadId })
    #expect(retried.params["threadId"] as? String == original.threadId)
    #expect((retried.params["input"] as? [[String: Any]])?.first?["text"] as? String == "When does it open?")
    await retryClient.close()

    let reopened = ChatClient(rpc: FakeCodexTransport(), options: options)
    let restored = try await reopened.connect()
    #expect(restored.messages == [ChatMessage(id: id, role: "user", text: "When does it open?")])
    await reopened.close()
}

@Test(arguments: [false, true])
func uncertainCodexSendWaitsForExplicitResend(relaunch: Bool) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-recovery-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let options = ChatClientOptions(
        openRouterConfigURL: dir.appendingPathComponent("openrouter.json"),
        stateURL: dir.appendingPathComponent("state.json"), env: [:]
    )
    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: options)
    let original = try await client.connect()
    rpc.turnStartError = NSError(domain: "test", code: -2)
    let prompt = ChatMessage(id: "panel-user-id", role: "user", text: "When does it open?")
    await #expect(throws: (any Error).self) { try await client.send(prompt.text, userMessageId: prompt.id) }

    let retryRPC = relaunch ? FakeCodexTransport() : rpc
    let retryClient = relaunch ? ChatClient(rpc: retryRPC, options: options) : client
    retryRPC.turnStartError = nil
    if relaunch {
        await client.close()
        retryRPC.resumeResult = .success(CodexPayload(["thread": ["id": original.threadId, "turns": []]]))
        let reopened = try await retryClient.connect()
        #expect(reopened.messages == [prompt])
    }
    await #expect(throws: (any Error).self) { _ = try await retryClient.retryCodexSend(resend: true) }
    retryRPC.readResult = .success(CodexPayload(["thread": ["id": original.threadId, "turns": [
        ["id": "unrelated-turn", "items": [
            ["id": "other-input", "type": "userMessage", "clientId": "other-user",
             "content": [["type": "text", "text": prompt.text]]],
            ["id": "other-reply", "type": "agentMessage", "text": "This reply belongs to another prompt."],
        ]],
    ]]]))
    let checked = try #require(try await retryClient.retryCodexSend())
    #expect(checked.codexRetry?.action == .resend)
    #expect(checked.codexRetry?.notice?.contains("could duplicate") == true)
    #expect(checked.messages == [prompt])
    await #expect(throws: (any Error).self) { try await retryClient.send("A different question") }
    #expect(retryRPC.calls.filter { $0.method == "turn/start" }.count == (relaunch ? 0 : 1))

    _ = try await retryClient.retryCodexSend(resend: true)
    let resent = try #require(retryRPC.calls.last { $0.method == "turn/start" })
    #expect(retryRPC.calls.filter { $0.method == "turn/start" }.count == (relaunch ? 1 : 2))
    #expect(resent.params["clientUserMessageId"] as? String != prompt.id)
    #expect((resent.params["input"] as? [[String: Any]])?.first?["text"] as? String == prompt.text)
    await retryClient.close()

    let reopened = ChatClient(rpc: FakeCodexTransport(), options: options)
    let restored = try await reopened.connect()
    #expect(restored.messages == [prompt])
    #expect(restored.codexRetry?.userMessageId == prompt.id)
    await reopened.close()
}

@Test func newChatDoesNotRetryOrRestoreThePreviousUnconfirmedPrompt() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-recovery-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let options = ChatClientOptions(
        openRouterConfigURL: dir.appendingPathComponent("openrouter.json"),
        stateURL: dir.appendingPathComponent("state.json"), env: [:]
    )
    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: options)
    let original = try await client.connect()
    rpc.turnStartError = NSError(domain: "test", code: -2)
    await #expect(throws: (any Error).self) { try await client.send("Previous prompt") }
    let submitted = try #require(rpc.calls.last { $0.method == "turn/start" })
    let clientId = try #require(submitted.params["clientUserMessageId"] as? String)
    let input = try #require(submitted.params["input"] as? [[String: Any]])
    let checked = try #require(try await client.retryCodexSend())
    #expect(checked.codexRetry?.action == .resend)

    let new = try await client.newChat()
    #expect(new.threadId != original.threadId)
    #expect(new.messages.isEmpty)
    #expect(new.codexRetry == nil)
    rpc.onNotification?(CodexNotification(method: "item/started", params: [
        "threadId": original.threadId, "turnId": "old-turn",
        "item": ["id": "recorded-input", "type": "userMessage", "clientId": clientId, "content": input],
    ]))
    await #expect(throws: (any Error).self) { _ = try await client.retryCodexSend(userMessageId: clientId, resend: true) }
    await client.close()

    let reopened = ChatClient(rpc: FakeCodexTransport(), options: options)
    let restored = try await reopened.connect()
    #expect(restored.threadId == new.threadId)
    #expect(restored.messages.isEmpty)
    #expect(restored.codexRetry == nil)
    await reopened.close()
}

@Test func disconnectedCodexTurnCanBeCheckedWhileOpenRouterIsConfigured() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-recovery-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let configURL = dir.appendingPathComponent("openrouter.json")
    try OpenRouterClient.saveConfig(key: "test-key", to: configURL)
    let options = ChatClientOptions(
        openRouterConfigURL: configURL, stateURL: dir.appendingPathComponent("state.json"), env: [:]
    )
    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: options)
    let original = try await client.connect()
    try await client.send("Previous prompt")
    let submitted = try #require(rpc.calls.last { $0.method == "turn/start" })
    let clientId = try #require(submitted.params["clientUserMessageId"] as? String)
    let input = try #require(submitted.params["input"] as? [[String: Any]])

    rpc.onExit?()
    #expect(!client.busy)
    #expect(client.codexRetry?.action == .checkDelivery)
    rpc.readResult = .success(CodexPayload(["thread": ["id": original.threadId, "turns": [
        ["id": "turn-1", "items": [
            ["id": "recorded-input", "type": "userMessage", "clientId": clientId, "content": input],
        ]],
    ]]]))
    let checked = try #require(try await client.retryCodexSend())
    #expect(checked.codexRetry == nil)
    #expect(checked.messages == [ChatMessage(id: clientId, role: "user", text: "Previous prompt")])
    #expect(rpc.calls.filter { $0.method == "turn/start" }.count == 1)
    await client.close()
}
