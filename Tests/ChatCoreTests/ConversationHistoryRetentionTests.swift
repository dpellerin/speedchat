import Foundation
import Testing
@testable import ChatCore

@Test func historyRetentionPresetsAndOrderingMatchSpec() {
    #expect(HistoryRetention.defaultPolicy == .days30)
    #expect(HistoryRetention.allCases == [.days7, .days30, .days90, .year1, .forever])
    #expect(HistoryRetention.allCases.map(\.displayName) == ["7 days", "30 days", "90 days", "1 year", "Forever"])
    #expect(HistoryRetention.allCases.map(\.days) == [7, 30, 90, 365, nil])

    #expect(HistoryRetention.days7.isShorter(than: .days30))
    #expect(HistoryRetention.days30.isShorter(than: .days90))
    #expect(HistoryRetention.days90.isShorter(than: .year1))
    #expect(HistoryRetention.year1.isShorter(than: .forever))
    #expect(!HistoryRetention.forever.isShorter(than: .days7))
    #expect(!HistoryRetention.days30.isShorter(than: .days30))
    #expect(!HistoryRetention.days90.isShorter(than: .days30))
}

@Test func connectAutomaticallyPrunesExpiredConversationsByUpdatedAtAndFallsBackToBlankNewChat() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-retention-launch-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let configURL = dir.appendingPathComponent("openrouter.json")

    let clock = HistoryTestClock(Date(timeIntervalSince1970: 1_760_000_000))
    func makeOptions(retention: HistoryRetention = .days30) -> ChatClientOptions {
        ChatClientOptions(
            openRouterConfigURL: configURL,
            stateURL: stateURL,
            env: [:],
            now: { clock.now() },
            historyRetention: retention
        )
    }

    // Day 0: create Conversation 1.
    let rpc1 = FakeCodexTransport()
    let client1 = ChatClient(rpc: rpc1, options: makeOptions())
    let firstReady = try await client1.connect()
    try await client1.send("Old topic from day zero", userMessageId: "c1-u1")
    completeHistoryCodexTurn(
        rpc: rpc1, threadId: firstReady.threadId,
        userMessageId: "c1-u1", userText: "Old topic from day zero",
        replyId: "c1-a1", replyText: "Day zero reply."
    )
    let idOld = try #require(client1.conversationId)

    // Day 20: create Conversation 2.
    clock.advance(days: 20)
    let secondReady = try await client1.newChat()
    try await client1.send("Recent topic from day twenty", userMessageId: "c2-u1")
    completeHistoryCodexTurn(
        rpc: rpc1, threadId: secondReady.threadId,
        userMessageId: "c2-u1", userText: "Recent topic from day twenty",
        replyId: "c2-a1", replyText: "Day twenty reply."
    )
    let idRecent = try #require(client1.conversationId)

    // Day 29: merely viewing Conversation 1 (active) must NOT reset its retention age.
    clock.advance(days: 9)
    _ = try client1.openConversation(id: idOld)
    await client1.close()

    // Day 31: Conversation 1 is 31 days old (> 30d) even though it was viewed on Day 29!
    // Conversation 2 is 11 days old (<= 30d) and must survive.
    clock.advance(days: 2)
    let relaunchRPC = FakeCodexTransport()
    let relaunched = ChatClient(rpc: relaunchRPC, options: makeOptions(retention: .days30))
    let relaunchReady = try await relaunched.connect()

    // Last-active conversation (idOld) expired -> opens a blank New Chat.
    #expect(relaunchReady.conversationId == nil)
    #expect(relaunchReady.messages.isEmpty)
    #expect(!relaunchReady.resumed)
    // Only idRecent survives on disk.
    #expect(relaunched.listHistory().map(\.id) == [idRecent])
    #expect(StateStore.loadConversation(id: idOld, stateURL: stateURL, env: [:]) == nil)
    // Never sends Codex delete/archive RPCs.
    #expect(!relaunchRPC.calls.contains { $0.method.contains("delete") || $0.method.contains("archive") })
    await relaunched.close()

    // Day 1000 with `.forever`: idRecent still survives and is never pruned.
    clock.advance(days: 969)
    let foreverClient = ChatClient(rpc: FakeCodexTransport(), options: makeOptions(retention: .forever))
    _ = try await foreverClient.connect()
    #expect(foreverClient.listHistory().map(\.id) == [idRecent])
    await foreverClient.close()
}

@Test func applyHistoryRetentionDryRunsPrunesAndResetsActiveOnlyWhenExpiredWithoutCodexRPCs() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-retention-apply-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let configURL = dir.appendingPathComponent("openrouter.json")

    let clock = HistoryTestClock(Date(timeIntervalSince1970: 1_761_000_000))
    let options = ChatClientOptions(
        openRouterConfigURL: configURL,
        stateURL: stateURL,
        env: [:],
        now: { clock.now() },
        historyRetention: .forever
    )

    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: options)

    // Day 0: Conversation A (100 days old by Day 100)
    let r1 = try await client.connect()
    try await client.send("Hundred day old topic", userMessageId: "a-u1")
    completeHistoryCodexTurn(
        rpc: rpc, threadId: r1.threadId,
        userMessageId: "a-u1", userText: "Hundred day old topic",
        replyId: "a-a1", replyText: "Reply A."
    )
    let idA = try #require(client.conversationId)

    // Day 80: Conversation B (20 days old by Day 100)
    clock.advance(days: 80)
    let r2 = try await client.newChat()
    try await client.send("Twenty day old topic", userMessageId: "b-u1")
    completeHistoryCodexTurn(
        rpc: rpc, threadId: r2.threadId,
        userMessageId: "b-u1", userText: "Twenty day old topic",
        replyId: "b-a1", replyText: "Reply B."
    )
    let idB = try #require(client.conversationId)

    // Day 98: Conversation C (2 days old by Day 100)
    clock.advance(days: 18)
    let r3 = try await client.newChat()
    try await client.send("Two day old topic", userMessageId: "c-u1")
    completeHistoryCodexTurn(
        rpc: rpc, threadId: r3.threadId,
        userMessageId: "c-u1", userText: "Two day old topic",
        replyId: "c-a1", replyText: "Reply C."
    )
    let idC = try #require(client.conversationId)

    // Advance to Day 100.
    clock.advance(days: 2)
    #expect(client.countSavedConversations() == 3)
    #expect(client.countExpiredConversations(for: .forever) == 0)
    #expect(client.countExpiredConversations(for: .year1) == 0)
    #expect(client.countExpiredConversations(for: .days90) == 1)
    #expect(client.countExpiredConversations(for: .days30) == 1)
    #expect(client.countExpiredConversations(for: .days7) == 2)

    // Dry-run counting must not delete anything.
    #expect(client.listHistory().map(\.id) == [idC, idB, idA])

    // Shortening to 30 days while active conversation C (2 days old) is fresh:
    // removes only A, preserves active conversation C, makes zero Codex RPCs.
    let callsBeforeFirstPrune = rpc.calls.count
    let prune30 = try client.applyHistoryRetention(.days30)
    #expect(rpc.calls.count == callsBeforeFirstPrune)
    #expect(prune30.removedCount == 1)
    #expect(!prune30.clearedActiveConversation)
    #expect(prune30.readyState == nil)
    #expect(client.conversationId == idC)
    #expect(client.listHistory().map(\.id) == [idC, idB])

    // Switch to Conversation B (20 days old), then shorten to 7 days:
    // removes active conversation B, resets to blank New Chat, keeps C, makes zero Codex RPCs.
    _ = try client.openConversation(id: idB)
    let callsBeforeSecondPrune = rpc.calls.count
    let prune7 = try client.applyHistoryRetention(.days7)
    #expect(rpc.calls.count == callsBeforeSecondPrune)
    #expect(prune7.removedCount == 1)
    #expect(prune7.clearedActiveConversation)
    let resetReady = try #require(prune7.readyState)
    #expect(resetReady.conversationId == nil)
    #expect(resetReady.messages.isEmpty)
    #expect(resetReady.model == r3.model)
    #expect(resetReady.offlineReason == nil)
    #expect(client.conversationId == nil)
    #expect(client.listHistory().map(\.id) == [idC])

    // Sending on OpenAI after active reset starts a fresh Codex thread cleanly.
    try await client.send("Fresh prompt after prune", userMessageId: "fresh-u1")
    let turnStart = try #require(rpc.calls.last { $0.method == "turn/start" })
    let newThreadId = try #require(turnStart.params["threadId"] as? String)
    completeHistoryCodexTurn(
        rpc: rpc, threadId: newThreadId, turnId: "turn-fresh",
        userMessageId: "fresh-u1", userText: "Fresh prompt after prune",
        replyId: "fresh-a1", replyText: "Fresh reply."
    )
    let idFresh = try #require(client.conversationId)
    #expect(idFresh != idB && idFresh != idC)
    #expect(client.listHistory().map(\.id) == [idFresh, idC])

    await client.close()
}

@Test func clearHistoryDeletesOnlyLocalRecordsWorksOfflineAndGatesWhileBusy() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-clear-all-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let configURL = dir.appendingPathComponent("openrouter.json")

    let clock = HistoryTestClock(Date(timeIntervalSince1970: 1_762_000_000))
    let options = ChatClientOptions(
        openRouterConfigURL: configURL,
        stateURL: stateURL,
        env: [:],
        now: { clock.now() },
        historyRetention: .days30
    )

    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: options)
    let firstReady = try await client.connect()
    try await client.send("First saved chat", userMessageId: "u1")
    completeHistoryCodexTurn(
        rpc: rpc, threadId: firstReady.threadId,
        userMessageId: "u1", userText: "First saved chat",
        replyId: "a1", replyText: "First reply."
    )

    clock.advance(by: 60)
    let secondReady = try await client.newChat()
    try await client.send("Second saved chat", userMessageId: "u2")
    completeHistoryCodexTurn(
        rpc: rpc, threadId: secondReady.threadId,
        userMessageId: "u2", userText: "Second saved chat",
        replyId: "a2", replyText: "Second reply."
    )
    #expect(client.countSavedConversations() == 2)

    // Busy gating: clearHistory throws while an active turn is running and deletes nothing.
    rpc.holdTurnStart = true
    let sendTask = Task {
        try? await client.send("In flight prompt", userMessageId: "u3")
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while !client.busy, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(client.busy)
    #expect(throws: Error.self) {
        _ = try client.clearHistory()
    }
    #expect(client.countSavedConversations() == 2)
    rpc.releaseTurnStart()
    completeHistoryCodexTurn(
        rpc: rpc, threadId: secondReady.threadId, turnId: "turn-2",
        userMessageId: "u3", userText: "In flight prompt",
        replyId: "a3", replyText: "Finished."
    )
    await sendTask.value

    // Clear All online: removes all local records, resets active to blank New Chat, ZERO Codex RPCs.
    let callsBeforeClear = rpc.calls.count
    let cleared = try client.clearHistory()
    #expect(rpc.calls.count == callsBeforeClear)
    #expect(cleared.removedCount == 2)
    #expect(cleared.clearedActiveConversation)
    let clearedReady = try #require(cleared.readyState)
    #expect(clearedReady.conversationId == nil)
    #expect(clearedReady.messages.isEmpty)
    #expect(clearedReady.offlineReason == nil)
    #expect(client.conversationId == nil)
    #expect(client.listHistory().isEmpty)
    await client.close()

    // Save one conversation on disk and test Clear All while completely offline.
    let offlineConv = SavedConversation(
        id: "offline-conv-1",
        title: "Offline chat",
        createdAt: StateStore.formatTimestamp(clock.now()),
        updatedAt: StateStore.formatTimestamp(clock.now()),
        model: "gpt-6-luna",
        threadId: "codex-offline-1",
        messages: [ChatMessage(id: "ou1", role: "user", text: "Offline question")]
    )
    try StateStore.saveActiveConversation(offlineConv, to: stateURL)

    let offlineRPC = FakeCodexTransport()
    offlineRPC.failStart = true
    let offlineClient = ChatClient(rpc: offlineRPC, options: options)
    let offlineInitial = try await offlineClient.connect()
    #expect(offlineInitial.offlineReason != nil)
    #expect(offlineInitial.conversationId == "offline-conv-1")

    let offlineCleared = try offlineClient.clearHistory()
    #expect(offlineCleared.removedCount == 1)
    #expect(offlineCleared.clearedActiveConversation)
    let offlineReset = try #require(offlineCleared.readyState)
    #expect(offlineReset.conversationId == nil)
    #expect(offlineReset.messages.isEmpty)
    #expect(offlineReset.offlineReason != nil)
    #expect(offlineReset.models.isEmpty)
    #expect(offlineClient.listHistory().isEmpty)
    await offlineClient.close()
}

