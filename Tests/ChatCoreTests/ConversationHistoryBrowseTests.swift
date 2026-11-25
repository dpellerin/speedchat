import Foundation
import Testing
@testable import ChatCore

private func browseSSEStream(_ events: [[String: Any]]) -> OpenRouterHTTPResponse {
    let lines = AsyncThrowingStream<String, Error> { continuation in
        for event in events {
            if let data = try? JSONSerialization.data(withJSONObject: event),
               let text = String(data: data, encoding: .utf8) {
                continuation.yield("data: \(text)")
            }
        }
        continuation.yield("data: [DONE]")
        continuation.finish()
    }
    return OpenRouterHTTPResponse(statusCode: 200, lines: lines)
}

@Test func listHistoryReturnsRecentEntriesWithLatestPreviewExcludingBeamReasoning() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-list-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let configURL = dir.appendingPathComponent("openrouter.json")
    let beamModel = "openrouter/beam-test"
    try OpenRouterClient.saveConfig(
        key: "sk-or-test",
        models: [ChatModel(model: beamModel, displayName: "Beam Test", provider: "openrouter")],
        to: configURL
    )
    let clock = HistoryTestClock(Date(timeIntervalSince1970: 1_750_000_000))
    let fetch: OpenRouterFetch = { _ in
        browseSSEStream([
            ["choices": [["delta": ["reasoning": "SECRET BEAM CHAIN OF THOUGHT"]]]],
            ["choices": [["delta": ["content": "Visible final\n  answer from Beam."]]]],
            ["choices": [["finish_reason": "stop"]]],
        ])
    }
    let options = ChatClientOptions(
        openRouterFetch: fetch,
        openRouterConfigURL: configURL,
        stateURL: stateURL,
        env: [:],
        now: { clock.now() }
    )

    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: options)
    let firstReady = try await client.connect()
    try await client.send("Please compare espresso grinders", userMessageId: "c1-u1")
    completeHistoryCodexTurn(
        rpc: rpc, threadId: firstReady.threadId,
        userMessageId: "c1-u1", userText: "Please compare espresso grinders",
        replyId: "c1-a1", replyText: "Flat burrs highlight clarity.\nConical burrs add body."
    )
    let id1 = try #require(client.conversationId)

    clock.advance(by: 120)
    _ = try await client.newChat()
    _ = try await client.selectModel(beamModel)
    let done = AsyncStream<Void>.makeStream()
    client.onDone = { done.continuation.yield() }
    try await client.send("Explain quicksort stability", userMessageId: "c2-u1")
    for await _ in done.stream { break }
    let id2 = try #require(client.conversationId)

    // Blank new chat should not appear in History.
    _ = try await client.newChat()

    let entries = client.listHistory()
    #expect(entries.map(\.id) == [id2, id1])
    #expect(entries[0].title == "Explain quicksort stability")
    #expect(entries[0].preview == "Visible final answer from Beam.")
    #expect(!entries[0].preview.contains("SECRET BEAM"))
    #expect(entries[0].model == beamModel)
    #expect(entries[0].messageCount == 2)

    #expect(entries[1].title == "Compare espresso grinders")
    #expect(entries[1].preview == "Flat burrs highlight clarity. Conical burrs add body.")
    #expect(entries[1].model == firstReady.model)
    #expect(entries[1].messageCount == 2)

    await client.close()
}

@Test func openConversationResumesLocallyWithoutCodexRPCAndRestoresModelWithFallback() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-open-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let configURL = dir.appendingPathComponent("openrouter.json")
    let routerA = "openrouter/alpha"
    let routerB = "openrouter/beta"
    try OpenRouterClient.saveConfig(
        key: "sk-or-test",
        models: [
            ChatModel(model: routerA, displayName: "Alpha", provider: "openrouter"),
            ChatModel(model: routerB, displayName: "Beta", provider: "openrouter"),
        ],
        to: configURL
    )
    let clock = HistoryTestClock(Date(timeIntervalSince1970: 1_750_100_000))
    let fetch: OpenRouterFetch = { _ in
        browseSSEStream([
            ["choices": [["delta": ["content": "Router reply."]]]],
            ["choices": [["finish_reason": "stop"]]],
        ])
    }
    let options = ChatClientOptions(
        openRouterFetch: fetch,
        openRouterConfigURL: configURL,
        stateURL: stateURL,
        env: [:],
        now: { clock.now() }
    )

    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: options)
    let firstReady = try await client.connect()
    try await client.send("First Codex question", userMessageId: "c1-u1")
    completeHistoryCodexTurn(
        rpc: rpc, threadId: firstReady.threadId,
        userMessageId: "c1-u1", userText: "First Codex question",
        replyId: "c1-a1", replyText: "First Codex answer."
    )
    let id1 = try #require(client.conversationId)
    let initialUpdatedAt1 = try #require(client.listHistory().first { $0.id == id1 }?.updatedAt)

    clock.advance(by: 300)
    _ = try await client.newChat()
    _ = try await client.selectModel(routerA)
    let done = AsyncStream<Void>.makeStream()
    client.onDone = { done.continuation.yield() }
    try await client.send("Second router question", userMessageId: "c2-u1")
    for await _ in done.stream { break }
    let id2 = try #require(client.conversationId)

    // Switch back to Conversation 1: must NOT call thread/resume or thread/start,
    // must restore Conversation 1's model, and must NOT bump updatedAt.
    clock.advance(by: 600)
    let callCountBeforeOpen = rpc.calls.count
    let opened1 = try client.openConversation(id: id1)
    #expect(rpc.calls.count == callCountBeforeOpen)
    #expect(opened1.conversationId == id1)
    #expect(opened1.messages.map(\.text) == ["First Codex question", "First Codex answer."])
    #expect(opened1.model == firstReady.model)
    #expect(opened1.offlineReason == nil)

    let afterOpenHistory = client.listHistory()
    #expect(afterOpenHistory.map(\.id) == [id2, id1])
    #expect(afterOpenHistory.first { $0.id == id1 }?.updatedAt == initialUpdatedAt1)

    // Remove routerA from OpenRouter config and reload, then switch to Conversation 2 from a blank chat on routerB:
    // unavailable saved model falls back to the currently selected valid model.
    try OpenRouterClient.saveConfig(
        key: "sk-or-test",
        models: [ChatModel(model: routerB, displayName: "Beta", provider: "openrouter")],
        to: configURL
    )
    _ = await client.reloadOpenRouter()
    _ = try await client.newChat()
    _ = try await client.selectModel(routerB)
    let opened2 = try client.openConversation(id: id2)
    #expect(opened2.conversationId == id2)
    #expect(opened2.model == routerB)
    #expect(opened2.messages.map(\.text) == ["Second router question", "Router reply."])

    // Deferred Codex resume: switch back to Conversation 1 and send on OpenAI.
    _ = try client.openConversation(id: id1)
    #expect(!rpc.calls.contains { $0.method == "thread/resume" })
    rpc.resumeResult = .success(CodexPayload([
        "thread": ["id": firstReady.threadId, "name": "First Codex question", "turns": []],
        "model": firstReady.model,
    ]))
    clock.advance(by: 60)
    try await client.send("Follow-up on Codex", userMessageId: "c1-u2")
    completeHistoryCodexTurn(
        rpc: rpc, threadId: firstReady.threadId, turnId: "turn-2",
        userMessageId: "c1-u2", userText: "Follow-up on Codex",
        replyId: "c1-a2", replyText: "Deferred resume worked."
    )
    #expect(rpc.calls.contains { $0.method == "thread/resume" && ($0.params["threadId"] as? String) == firstReady.threadId })
    // Activity on Conversation 1 now bumps updatedAt ahead of Conversation 2.
    #expect(client.listHistory().map(\.id) == [id1, id2])

    await client.close()
}

@Test func openConversationPreservesPerConversationCodexRetryIsolationAndSupportsOfflineAndBusyGating() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-isolation-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let configURL = dir.appendingPathComponent("openrouter.json")
    let clock = HistoryTestClock(Date(timeIntervalSince1970: 1_750_200_000))
    let options = ChatClientOptions(
        openRouterConfigURL: configURL,
        stateURL: stateURL,
        env: [:],
        now: { clock.now() }
    )

    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: options)
    _ = try await client.connect()

    // Conversation 1 has an unconfirmed Codex send (turn/start times out).
    rpc.turnStartError = NSError(domain: "SpeedChat.Test", code: -1, userInfo: [
        NSLocalizedDescriptionKey: "Codex request timed out.",
    ])
    await #expect(throws: Error.self) {
        try await client.send("Did Codex receive this?", userMessageId: "c1-u1")
    }
    let id1 = try #require(client.conversationId)
    #expect(client.codexRetry == CodexRetry(userMessageId: "c1-u1", action: .checkDelivery))

    // Conversation 2 completes normally with no retry state.
    clock.advance(by: 60)
    rpc.turnStartError = nil
    let secondReady = try await client.newChat()
    try await client.send("Clean conversation", userMessageId: "c2-u1")
    completeHistoryCodexTurn(
        rpc: rpc, threadId: secondReady.threadId,
        userMessageId: "c2-u1", userText: "Clean conversation",
        replyId: "c2-a1", replyText: "All good."
    )
    let id2 = try #require(client.conversationId)
    #expect(client.codexRetry == nil)

    // Opening Conversation 1 restores its pending checkDelivery state.
    let reopened1 = try client.openConversation(id: id1)
    #expect(reopened1.codexRetry == CodexRetry(userMessageId: "c1-u1", action: .checkDelivery))

    // Opening Conversation 2 clears Conversation 1's retry state.
    let reopened2 = try client.openConversation(id: id2)
    #expect(reopened2.codexRetry == nil)

    // Busy gating: openConversation throws while an active turn is running.
    rpc.resumeResult = .success(CodexPayload([
        "thread": ["id": secondReady.threadId, "name": "Clean conversation", "turns": []],
        "model": secondReady.model,
    ]))
    rpc.holdTurnStart = true
    let sendTask = Task {
        try? await client.send("In flight prompt", userMessageId: "c2-u2")
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while !client.busy, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(client.busy)
    #expect(throws: Error.self) {
        _ = try client.openConversation(id: id1)
    }
    rpc.releaseTurnStart()
    completeHistoryCodexTurn(
        rpc: rpc, threadId: secondReady.threadId, turnId: "turn-2",
        userMessageId: "c2-u2", userText: "In flight prompt",
        replyId: "c2-a2", replyText: "Finished."
    )
    await sendTask.value
    await client.close()

    // Offline browsing and opening works locally without Codex or OpenRouter.
    let offlineRPC = FakeCodexTransport()
    offlineRPC.failStart = true
    let offlineClient = ChatClient(rpc: offlineRPC, options: options)
    let offlineInitial = try await offlineClient.connect()
    #expect(offlineInitial.offlineReason != nil)
    #expect(offlineClient.listHistory().map(\.id) == [id2, id1])

    let offlineOpened1 = try offlineClient.openConversation(id: id1)
    #expect(offlineOpened1.conversationId == id1)
    #expect(offlineOpened1.messages.map(\.text) == ["Did Codex receive this?"])
    #expect(offlineOpened1.offlineReason != nil)
    #expect(offlineOpened1.models.isEmpty)
    await offlineClient.close()
}

@Test func openConversationFallsBackToReplacementCodexThreadWhenOriginalIsMissingAndKeepsStableId() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-fallback-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let options = ChatClientOptions(
        openRouterConfigURL: dir.appendingPathComponent("openrouter.json"),
        stateURL: stateURL,
        env: [:]
    )

    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: options)
    let firstReady = try await client.connect()
    try await client.send("Original topic", userMessageId: "c1-u1")
    completeHistoryCodexTurn(
        rpc: rpc, threadId: firstReady.threadId,
        userMessageId: "c1-u1", userText: "Original topic",
        replyId: "c1-a1", replyText: "Original reply."
    )
    let id1 = try #require(client.conversationId)

    _ = try await client.newChat()
    _ = try client.openConversation(id: id1)

    // Original thread is confirmed missing when the user sends a follow-up.
    rpc.resumeResult = .failure(CodexRPCError(
        code: -32600,
        message: "no rollout found for thread id \(firstReady.threadId)"
    ))
    try await client.send("Continue after missing thread", userMessageId: "c1-u2")
    let turnStart = try #require(rpc.calls.last { $0.method == "turn/start" })
    let replacementThreadId = try #require(turnStart.params["threadId"] as? String)
    #expect(replacementThreadId != firstReady.threadId)
    let input = (turnStart.params["input"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    #expect(input.contains("Original topic"))
    #expect(input.contains("Original reply."))
    #expect(input.contains("Continue after missing thread"))
    completeHistoryCodexTurn(
        rpc: rpc, threadId: replacementThreadId, turnId: "turn-replacement",
        userMessageId: "c1-u2", userText: input,
        replyId: "c1-a2", replyText: "Continued on replacement thread."
    )
    #expect(client.conversationId == id1)
    #expect(client.listHistory().map(\.id) == [id1])
    await client.close()
}
