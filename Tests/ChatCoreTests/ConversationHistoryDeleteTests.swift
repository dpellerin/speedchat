import Foundation
import Testing
@testable import ChatCore

@Test func deleteConversationRemovesOnlyLocalRecordWithoutCodexRPCsAndResetsActiveToBlankNewChat() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-delete-online-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let configURL = dir.appendingPathComponent("openrouter.json")

    let clock = HistoryTestClock(Date(timeIntervalSince1970: 1_765_000_000))
    let options = ChatClientOptions(
        openRouterConfigURL: configURL,
        stateURL: stateURL,
        env: [:],
        now: { clock.now() },
        historyRetention: .days30
    )

    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: options)

    // Create Conversation A
    let r1 = try await client.connect()
    try await client.send("Plan Lisbon weekend", userMessageId: "a-u1")
    completeHistoryCodexTurn(
        rpc: rpc, threadId: r1.threadId, turnId: "turn-1",
        userMessageId: "a-u1", userText: "Plan Lisbon weekend",
        replyId: "a-a1", replyText: "Start in Alfama."
    )
    let idA = try #require(client.conversationId)

    // Create Conversation B (becomes active)
    clock.advance(by: 60)
    let r2 = try await client.newChat()
    try await client.send("Sourdough hydration ratio", userMessageId: "b-u1")
    completeHistoryCodexTurn(
        rpc: rpc, threadId: r2.threadId, turnId: "turn-1",
        userMessageId: "b-u1", userText: "Sourdough hydration ratio",
        replyId: "b-a1", replyText: "Try 75% hydration."
    )
    let idB = try #require(client.conversationId)
    #expect(client.listHistory().map(\.id) == [idB, idA])

    // 1. Delete non-active Conversation A: local-only, ZERO Codex RPCs, active B stays untouched.
    let callsBeforeDeleteA = rpc.calls.count
    let deleteA = try client.deleteConversation(id: idA)
    #expect(rpc.calls.count == callsBeforeDeleteA)
    #expect(deleteA.removedCount == 1)
    #expect(!deleteA.clearedActiveConversation)
    #expect(deleteA.readyState == nil)
    #expect(client.conversationId == idB)
    #expect(client.listHistory().map(\.id) == [idB])
    #expect(StateStore.loadConversation(id: idA, stateURL: stateURL, env: [:]) == nil)
    #expect(StateStore.loadConversation(id: idB, stateURL: stateURL, env: [:]) != nil)

    // Deleting an already-deleted ID is a safe no-op with zero Codex RPCs.
    let deleteMissing = try client.deleteConversation(id: idA)
    #expect(rpc.calls.count == callsBeforeDeleteA)
    #expect(deleteMissing.removedCount == 0)
    #expect(!deleteMissing.clearedActiveConversation)
    #expect(deleteMissing.readyState == nil)

    // 2. Busy gating: deleting throws while an active turn is running and preserves B.
    rpc.holdTurnStart = true
    let sendTask = Task {
        try? await client.send("Follow-up question", userMessageId: "b-u2")
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while !rpc.calls.contains(where: { $0.method == "turn/start" && ($0.params["clientUserMessageId"] as? String) == "b-u2" }),
          ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(client.busy)
    #expect(throws: Error.self) {
        _ = try client.deleteConversation(id: idB)
    }
    #expect(client.listHistory().map(\.id) == [idB])
    rpc.releaseTurnStart(turnId: "turn-2")
    await sendTask.value
    completeHistoryCodexTurn(
        rpc: rpc, threadId: r2.threadId, turnId: "turn-2",
        userMessageId: "b-u2", userText: "Follow-up question",
        replyId: "b-a2", replyText: "Fold every 30 minutes."
    )
    #expect(!client.busy)

    // 3. Delete currently active Conversation B (the last saved conversation):
    // local-only, ZERO Codex RPCs, resets to blank New Chat, History becomes empty.
    let callsBeforeDeleteB = rpc.calls.count
    let deleteB = try client.deleteConversation(id: idB)
    #expect(rpc.calls.count == callsBeforeDeleteB)
    #expect(deleteB.removedCount == 1)
    #expect(deleteB.clearedActiveConversation)
    let blankReady = try #require(deleteB.readyState)
    #expect(blankReady.conversationId == nil)
    #expect(blankReady.messages.isEmpty)
    #expect(blankReady.model == r2.model)
    #expect(blankReady.offlineReason == nil)
    #expect(client.conversationId == nil)
    #expect(client.listHistory().isEmpty)
    #expect(StateStore.loadConversation(id: idB, stateURL: stateURL, env: [:]) == nil)

    // Relaunching after deleting the active conversation opens a blank New Chat, never resurrecting B.
    await client.close()
    let relaunchRPC = FakeCodexTransport()
    let relaunched = ChatClient(rpc: relaunchRPC, options: options)
    let relaunchReady = try await relaunched.connect()
    #expect(relaunchReady.conversationId == nil)
    #expect(relaunchReady.messages.isEmpty)
    #expect(relaunched.listHistory().isEmpty)

    // Sending after deleting the active conversation works cleanly on a fresh Codex thread.
    try await relaunched.send("Fresh topic after delete", userMessageId: "c-u1")
    let turnStart = try #require(relaunchRPC.calls.last { $0.method == "turn/start" })
    let freshThreadId = try #require(turnStart.params["threadId"] as? String)
    completeHistoryCodexTurn(
        rpc: relaunchRPC, threadId: freshThreadId, turnId: "turn-1",
        userMessageId: "c-u1", userText: "Fresh topic after delete",
        replyId: "c-a1", replyText: "Fresh reply."
    )
    let idC = try #require(relaunched.conversationId)
    #expect(idC != idA && idC != idB)
    #expect(relaunched.listHistory().map(\.id) == [idC])
    #expect(!rpc.calls.contains { $0.method.contains("delete") || $0.method.contains("archive") })
    #expect(!relaunchRPC.calls.contains { $0.method.contains("delete") || $0.method.contains("archive") })
    await relaunched.close()
}

@Test func deleteConversationWorksOfflineForBothNonActiveAndActiveConversations() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-delete-offline-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let configURL = dir.appendingPathComponent("openrouter.json")

    let clock = HistoryTestClock(Date(timeIntervalSince1970: 1_766_000_000))
    let older = SavedConversation(
        id: "offline-older",
        title: "Older offline chat",
        createdAt: StateStore.formatTimestamp(clock.now().addingTimeInterval(-3600)),
        updatedAt: StateStore.formatTimestamp(clock.now().addingTimeInterval(-3600)),
        model: "gpt-6-luna",
        threadId: "codex-offline-older",
        messages: [ChatMessage(id: "o1", role: "user", text: "Older offline question")]
    )
    let active = SavedConversation(
        id: "offline-active",
        title: "Active offline chat",
        createdAt: StateStore.formatTimestamp(clock.now().addingTimeInterval(-60)),
        updatedAt: StateStore.formatTimestamp(clock.now().addingTimeInterval(-60)),
        model: "gpt-6-luna",
        threadId: "codex-offline-active",
        messages: [ChatMessage(id: "o2", role: "user", text: "Active offline question")]
    )
    try StateStore.saveActiveConversation(older, to: stateURL)
    try StateStore.saveActiveConversation(active, to: stateURL)

    let rpc = FakeCodexTransport()
    rpc.failStart = true
    let client = ChatClient(
        rpc: rpc,
        options: ChatClientOptions(
            openRouterConfigURL: configURL,
            stateURL: stateURL,
            env: [:],
            now: { clock.now() },
            historyRetention: .days30
        )
    )

    let initial = try await client.connect()
    #expect(initial.offlineReason != nil)
    #expect(initial.conversationId == "offline-active")
    #expect(client.listHistory().map(\.id) == ["offline-active", "offline-older"])

    // Delete non-active offline conversation.
    let delOlder = try client.deleteConversation(id: "offline-older")
    #expect(delOlder.removedCount == 1)
    #expect(!delOlder.clearedActiveConversation)
    #expect(delOlder.readyState == nil)
    #expect(client.conversationId == "offline-active")
    #expect(client.listHistory().map(\.id) == ["offline-active"])

    // Delete active offline conversation (last remaining) -> blank offline state & empty History.
    let delActive = try client.deleteConversation(id: "offline-active")
    #expect(delActive.removedCount == 1)
    #expect(delActive.clearedActiveConversation)
    let blankOffline = try #require(delActive.readyState)
    #expect(blankOffline.conversationId == nil)
    #expect(blankOffline.messages.isEmpty)
    #expect(blankOffline.offlineReason != nil)
    #expect(blankOffline.models.isEmpty)
    #expect(client.conversationId == nil)
    #expect(client.listHistory().isEmpty)
    #expect(rpc.calls.isEmpty)

    await client.close()
}
