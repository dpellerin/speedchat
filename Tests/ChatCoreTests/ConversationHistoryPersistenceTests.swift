import Foundation
import Testing
@testable import ChatCore

private func posixPermissions(at url: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
}

private func completeCodexTurn(
    rpc: FakeCodexTransport,
    threadId: String,
    turnId: String = "turn-1",
    userMessageId: String,
    userText: String,
    replyId: String,
    replyText: String
) {
    rpc.onNotification?(CodexNotification(method: "item/started", params: [
        "threadId": threadId, "turnId": turnId,
        "item": [
            "id": "codex-user-\(userMessageId)", "type": "userMessage", "clientId": userMessageId,
            "content": [["type": "text", "text": userText]],
        ],
    ]))
    rpc.onNotification?(CodexNotification(method: "item/completed", params: [
        "threadId": threadId, "turnId": turnId,
        "item": ["id": replyId, "type": "agentMessage", "text": replyText],
    ]))
    rpc.onNotification?(CodexNotification(method: "turn/completed", params: [
        "threadId": threadId, "turn": ["id": turnId, "status": "completed"],
    ]))
}

@Test func newChatPreservesPriorConversationWithPrivatePermissionsAndSkipsBlankChats() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-persist-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let options = ChatClientOptions(
        openRouterConfigURL: dir.appendingPathComponent("openrouter.json"),
        stateURL: stateURL,
        env: [:]
    )
    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: options)

    let initial = try await client.connect()
    #expect(initial.conversationId == nil)
    #expect(client.savedConversations().isEmpty)

    // Blank New Chats must never become saved conversations.
    let blank1 = try await client.newChat()
    let blank2 = try await client.newChat()
    #expect(blank1.conversationId == nil)
    #expect(blank2.conversationId == nil)
    #expect(client.savedConversations().isEmpty)

    // First real conversation.
    try await client.send("Can you please help me plan a weekend trip to Lisbon?", userMessageId: "u1")
    completeCodexTurn(
        rpc: rpc, threadId: blank2.threadId,
        userMessageId: "u1", userText: "Can you please help me plan a weekend trip to Lisbon?",
        replyId: "a1", replyText: "Start in Alfama and ride Tram 28."
    )
    let id1 = try #require(client.conversationId)

    // Starting New Chat must preserve Conversation 1 and not persist the blank chat.
    let afterNewChat = try await client.newChat()
    #expect(afterNewChat.conversationId == nil)
    #expect(afterNewChat.messages.isEmpty)
    let savedAfterNewChat = client.savedConversations()
    #expect(savedAfterNewChat.count == 1)
    #expect(savedAfterNewChat[0].id == id1)
    #expect(savedAfterNewChat[0].title == "Plan a weekend trip to Lisbon")
    #expect(savedAfterNewChat[0].messages.map(\.text) == [
        "Can you please help me plan a weekend trip to Lisbon?",
        "Start in Alfama and ride Tram 28.",
    ])

    // Second real conversation persists individually alongside the first.
    try await client.send("Explain Swift structured concurrency", userMessageId: "u2")
    completeCodexTurn(
        rpc: rpc, threadId: afterNewChat.threadId,
        userMessageId: "u2", userText: "Explain Swift structured concurrency",
        replyId: "a2", replyText: "Task groups bind child task lifetimes to a lexical scope."
    )
    let id2 = try #require(client.conversationId)
    #expect(id2 != id1)

    let allSaved = client.savedConversations()
    #expect(allSaved.count == 2)
    let firstRecord = try #require(allSaved.first { $0.id == id1 })
    let secondRecord = try #require(allSaved.first { $0.id == id2 })
    #expect(firstRecord.title == "Plan a weekend trip to Lisbon")
    #expect(secondRecord.title == "Explain Swift structured concurrency")
    #expect(firstRecord.messages.count == 2)
    #expect(secondRecord.messages.count == 2)

    // Verify 0700 directories and 0600 files.
    let conversationsDir = StateStore.conversationsDirectory(stateURL: stateURL, env: [:])
    #expect(try posixPermissions(at: dir) == 0o700)
    #expect(try posixPermissions(at: stateURL) == 0o600)
    #expect(try posixPermissions(at: conversationsDir) == 0o700)
    #expect(try posixPermissions(at: conversationsDir.appendingPathComponent("\(id1).json")) == 0o600)
    #expect(try posixPermissions(at: conversationsDir.appendingPathComponent("\(id2).json")) == 0o600)

    await client.close()
}

@Test func legacyV3StateMigratesNonEmptyAndEmptyConversationsOnLoad() async throws {
    // Case 1: Non-empty legacy v3 state migrates to a saved conversation and reopens as active.
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-v3-nonempty-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stateURL = dir.appendingPathComponent("state.json")
        let configURL = dir.appendingPathComponent("openrouter.json")
        let routerModel = OpenRouterClient.defaultModels[0].model
        try OpenRouterClient.saveConfig(key: "test-or-key", to: configURL)

        let legacyPayload: [String: Any] = [
            "version": 3,
            "threadId": "legacy-codex-thread",
            "model": routerModel,
            "updatedAt": "2026-04-01T10:00:00Z",
            "codexSyncedCount": 1,
            "messages": [
                ["id": "u1", "role": "user", "text": "Please summarize the Odyssey", "reasoning": "should-be-dropped"],
                ["id": "a1", "role": "assistant", "text": "Odysseus journeys home to Ithaca.", "reasoning": "private beam thought"],
            ],
            "lastCodexSend": [
                "threadId": "legacy-codex-thread",
                "clientId": "u1",
                "userMessageId": "u1",
                "wireText": "Please summarize the Odyssey",
                "delivery": "unconfirmed",
            ],
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyPayload, options: [.prettyPrinted, .sortedKeys])
        try legacyData.write(to: stateURL)

        let options = ChatClientOptions(openRouterConfigURL: configURL, stateURL: stateURL, env: [:])
        let rpc = FakeCodexTransport()
        rpc.resumeResult = .failure(NSError(domain: "SpeedChat.Codex", code: -2))
        let client = ChatClient(rpc: rpc, options: options)
        let ready = try await client.connect()

        let migratedId = try #require(ready.conversationId)
        #expect(ready.model == routerModel)
        #expect(ready.threadId == "legacy-codex-thread")
        #expect(ready.codexRetry == CodexRetry(userMessageId: "u1", action: .checkDelivery))
        #expect(ready.messages == [
            ChatMessage(id: "u1", role: "user", text: "Please summarize the Odyssey", reasoning: nil),
            ChatMessage(id: "a1", role: "assistant", text: "Odysseus journeys home to Ithaca.", reasoning: "private beam thought"),
        ])

        let saved = client.savedConversations()
        #expect(saved.count == 1)
        #expect(saved[0].id == migratedId)
        #expect(saved[0].title == "Summarize the Odyssey")
        #expect(saved[0].createdAt == "2026-04-01T10:00:00Z")
        #expect(saved[0].updatedAt == "2026-04-01T10:00:00Z")
        #expect(saved[0].codexSyncedCount == 1)

        let conversationsDir = StateStore.conversationsDirectory(stateURL: stateURL, env: [:])
        #expect(try posixPermissions(at: stateURL) == 0o600)
        #expect(try posixPermissions(at: conversationsDir) == 0o700)
        #expect(try posixPermissions(at: conversationsDir.appendingPathComponent("\(migratedId).json")) == 0o600)
        await client.close()

        // Reconnecting does not duplicate the migrated conversation and preserves the same local ID.
        let reopened = ChatClient(rpc: FakeCodexTransport(), options: options)
        let secondReady = try await reopened.connect()
        #expect(secondReady.conversationId == migratedId)
        #expect(reopened.savedConversations().map(\.id) == [migratedId])
        await reopened.close()
    }

    // Case 2: Empty legacy v3 state preserves only its selected model as a blank active conversation.
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-v3-empty-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stateURL = dir.appendingPathComponent("state.json")
        let configURL = dir.appendingPathComponent("openrouter.json")
        let routerModel = OpenRouterClient.defaultModels[0].model
        try OpenRouterClient.saveConfig(key: "test-or-key", to: configURL)

        let emptyLegacy: [String: Any] = [
            "version": 3,
            "threadId": "stale-empty-thread",
            "model": routerModel,
            "updatedAt": "2026-04-01T10:00:00Z",
            "messages": [],
        ]
        try JSONSerialization.data(withJSONObject: emptyLegacy).write(to: stateURL)

        let options = ChatClientOptions(openRouterConfigURL: configURL, stateURL: stateURL, env: [:])
        let rpc = FakeCodexTransport()
        let client = ChatClient(rpc: rpc, options: options)
        let ready = try await client.connect()

        #expect(ready.conversationId == nil)
        #expect(ready.messages.isEmpty)
        #expect(ready.model == routerModel)
        #expect(ready.threadId != "stale-empty-thread")
        #expect(!rpc.calls.contains { $0.method == "thread/resume" })
        #expect(client.savedConversations().isEmpty)
        #expect(try posixPermissions(at: stateURL) == 0o600)
        await client.close()
    }
}

@Test func conversationKeepsStableLocalIdAcrossStandaloneOpenRouterCodexHandoffAndReplacementThread() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-stable-id-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let configURL = dir.appendingPathComponent("openrouter.json")
    let beamModel = "reflection/beam-1.0-501b-a23b"
    try OpenRouterClient.saveConfig(
        key: "test-or-key",
        models: [ChatModel(model: beamModel, displayName: "Beam", provider: "openrouter")],
        to: configURL
    )

    let fetch: OpenRouterFetch = { _ in
        OpenRouterHTTPResponse(statusCode: 200, lines: AsyncThrowingStream { sink in
            sink.yield(#"data: {"choices":[{"delta":{"reasoning":"private beam note"}}]}"#)
            sink.yield(#"data: {"choices":[{"delta":{"content":"Lighthouse remembered."}}]}"#)
            sink.yield("data: [DONE]")
            sink.finish()
        })
    }
    let options = ChatClientOptions(
        openRouterFetch: fetch,
        openRouterConfigURL: configURL,
        stateURL: stateURL,
        env: [:]
    )

    // 1. Standalone OpenRouter turn creates the saved conversation with a local ID.
    let offlineCodex = FakeCodexTransport()
    offlineCodex.failStart = true
    let standalone = ChatClient(rpc: offlineCodex, options: options)
    let standaloneReady = try await standalone.connect()
    #expect(standaloneReady.conversationId == nil)
    #expect(standaloneReady.threadId.hasPrefix("openrouter-"))

    let (orDone, orContinuation) = AsyncStream<Void>.makeStream()
    standalone.onDone = { orContinuation.yield() }
    try await standalone.send("Remember the lighthouse.", userMessageId: "u1")
    for await _ in orDone { break }

    let localId = try #require(standalone.conversationId)
    let afterStandalone = try #require(standalone.savedConversations().first)
    #expect(standalone.savedConversations().count == 1)
    #expect(afterStandalone.id == localId)
    #expect(afterStandalone.title == "Remember the lighthouse")
    #expect(afterStandalone.threadId.hasPrefix("openrouter-"))
    #expect(afterStandalone.codexSyncedCount == 0)
    #expect(afterStandalone.messages.last?.reasoning == "private beam note")
    let originalCreatedAt = afterStandalone.createdAt
    await standalone.close()

    // 2. Reconnect with Codex available and hand off to an OpenAI model -> new Codex thread, SAME local ID.
    let codexRPC = FakeCodexTransport()
    let handoffClient = ChatClient(rpc: codexRPC, options: options)
    let handoffReady = try await handoffClient.connect()
    #expect(handoffReady.conversationId == localId)
    _ = try await handoffClient.selectModel("gpt-6-luna")
    try await handoffClient.send("What did I ask you to remember?", userMessageId: "u2")
    let handoffTurn = try #require(codexRPC.calls.last { $0.method == "turn/start" })
    let handoffThreadId = try #require(handoffTurn.params["threadId"] as? String)
    let handoffWireText = try #require((handoffTurn.params["input"] as? [[String: Any]])?.first?["text"] as? String)
    completeCodexTurn(
        rpc: codexRPC, threadId: handoffThreadId,
        userMessageId: "u2", userText: handoffWireText,
        replyId: "a2", replyText: "You asked me to remember the lighthouse."
    )

    #expect(handoffClient.conversationId == localId)
    let afterHandoffList = handoffClient.savedConversations()
    #expect(afterHandoffList.count == 1)
    let afterHandoff = try #require(afterHandoffList.first)
    #expect(afterHandoff.id == localId)
    #expect(afterHandoff.createdAt == originalCreatedAt)
    #expect(afterHandoff.title == "Remember the lighthouse")
    #expect(afterHandoff.threadId == handoffThreadId)
    #expect(!afterHandoff.threadId.hasPrefix("openrouter-"))
    #expect(afterHandoff.codexSyncedCount == 4)
    await handoffClient.close()

    // 3. Confirmed Codex thread loss creates an ADR 0001 replacement thread -> STILL the same local ID.
    codexRPC.resumeResult = .failure(CodexRPCError(
        code: -32600,
        message: "no rollout found for thread id \(handoffThreadId)"
    ))
    let replacementClient = ChatClient(rpc: codexRPC, options: options)
    let replacementReady = try await replacementClient.connect()
    #expect(replacementReady.conversationId == localId)

    try await replacementClient.send("Add harbor too.", userMessageId: "u3")
    let replacementTurn = try #require(codexRPC.calls.last { $0.method == "turn/start" })
    let replacementThreadId = try #require(replacementTurn.params["threadId"] as? String)
    #expect(replacementThreadId != handoffThreadId)
    let replacementWireText = try #require((replacementTurn.params["input"] as? [[String: Any]])?.first?["text"] as? String)
    #expect(replacementWireText.contains("Remember the lighthouse."))
    #expect(!replacementWireText.contains("private beam note"))
    completeCodexTurn(
        rpc: codexRPC, threadId: replacementThreadId,
        userMessageId: "u3", userText: replacementWireText,
        replyId: "a3", replyText: "Lighthouse and harbor remembered."
    )

    #expect(replacementClient.conversationId == localId)
    let afterReplacementList = replacementClient.savedConversations()
    #expect(afterReplacementList.count == 1)
    let afterReplacement = try #require(afterReplacementList.first)
    #expect(afterReplacement.id == localId)
    #expect(afterReplacement.createdAt == originalCreatedAt)
    #expect(afterReplacement.title == "Remember the lighthouse")
    #expect(afterReplacement.threadId == replacementThreadId)
    #expect(afterReplacement.messages.count == 6)
    #expect(afterReplacement.codexSyncedCount == 6)
    await replacementClient.close()
}

@Test func codexSyncCountAndUnconfirmedDeliveryStayIsolatedPerConversation() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-codex-isolation-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let options = ChatClientOptions(
        openRouterConfigURL: dir.appendingPathComponent("openrouter.json"),
        stateURL: stateURL,
        env: [:]
    )
    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: options)

    // Conversation 1: one completed exchange (codexSyncedCount = 2), then an unconfirmed send.
    let firstReady = try await client.connect()
    try await client.send("First conversation prompt", userMessageId: "c1-u1")
    completeCodexTurn(
        rpc: rpc, threadId: firstReady.threadId,
        userMessageId: "c1-u1", userText: "First conversation prompt",
        replyId: "c1-a1", replyText: "First reply"
    )
    rpc.turnStartError = NSError(domain: "SpeedChat.Test", code: -2, userInfo: [
        NSLocalizedDescriptionKey: "request timed out",
    ])
    await #expect(throws: (any Error).self) {
        try await client.send("Unconfirmed follow-up", userMessageId: "c1-u2")
    }
    #expect(client.codexRetry == CodexRetry(userMessageId: "c1-u2", action: .checkDelivery))
    let id1 = try #require(client.conversationId)

    // Start Conversation 2 and complete a normal send.
    rpc.turnStartError = nil
    let secondReady = try await client.newChat()
    #expect(secondReady.conversationId == nil)
    #expect(secondReady.codexRetry == nil)
    try await client.send("Second conversation prompt", userMessageId: "c2-u1")
    completeCodexTurn(
        rpc: rpc, threadId: secondReady.threadId,
        userMessageId: "c2-u1", userText: "Second conversation prompt",
        replyId: "c2-a1", replyText: "Second reply"
    )
    let id2 = try #require(client.conversationId)
    #expect(id2 != id1)
    #expect(client.codexRetry == nil)

    // Verify each saved conversation retains its own isolated Codex sync count & delivery record.
    let record1 = try #require(StateStore.loadConversation(id: id1, stateURL: stateURL, env: [:]))
    let record2 = try #require(StateStore.loadConversation(id: id2, stateURL: stateURL, env: [:]))
    #expect(record1.threadId == firstReady.threadId)
    #expect(record1.codexSyncedCount == 2)
    #expect(record1.lastCodexSend?.threadId == firstReady.threadId)
    #expect(record1.lastCodexSend?.userMessageId == "c1-u2")
    #expect(record1.lastCodexSend?.delivery == .unconfirmed)

    #expect(record2.threadId == secondReady.threadId)
    #expect(record2.codexSyncedCount == 2)
    #expect(record2.lastCodexSend?.threadId == secondReady.threadId)
    #expect(record2.lastCodexSend?.userMessageId == "c2-u1")
    #expect(record2.lastCodexSend?.delivery == .confirmed)

    await client.close()
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        self.current = start
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

@Test func updatedAtChangesOnlyOnMessageActivityAndNotOnReopenOrModelSelection() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-updated-at-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let configURL = dir.appendingPathComponent("openrouter.json")
    let routerModel = OpenRouterClient.defaultModels[0].model
    try OpenRouterClient.saveConfig(key: "test-or-key", to: configURL)

    let baseDate = Date(timeIntervalSince1970: 1_777_629_600) // 2026-05-01T10:00:00Z
    let clock = TestClock(baseDate)
    let (heldReply, heldSink) = AsyncThrowingStream<String, Error>.makeStream()
    defer { heldSink.finish() }

    let options = ChatClientOptions(
        openRouterFetch: { _ in OpenRouterHTTPResponse(statusCode: 200, lines: heldReply) },
        openRouterConfigURL: configURL,
        stateURL: stateURL,
        env: [:],
        now: { clock.now() }
    )

    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: options)
    let ready = try await client.connect()
    try await client.send("Initial question", userMessageId: "u1")
    completeCodexTurn(
        rpc: rpc, threadId: ready.threadId,
        userMessageId: "u1", userText: "Initial question",
        replyId: "a1", replyText: "Initial answer"
    )
    let id = try #require(client.conversationId)
    let t0 = StateStore.formatTimestamp(baseDate)
    let initialSaved = try #require(StateStore.loadConversation(id: id, stateURL: stateURL, env: [:]))
    #expect(initialSaved.createdAt == t0)
    #expect(initialSaved.updatedAt == t0)

    // 1. Selecting a different model must NOT bump updatedAt.
    clock.advance(by: 3600)
    _ = try await client.selectModel(routerModel)
    let afterModelSwitch = try #require(StateStore.loadConversation(id: id, stateURL: stateURL, env: [:]))
    #expect(afterModelSwitch.model == routerModel)
    #expect(afterModelSwitch.updatedAt == t0)
    #expect(afterModelSwitch.createdAt == t0)

    // 2. Listing/reading saved conversations must NOT bump updatedAt.
    clock.advance(by: 3600)
    _ = client.savedConversations()
    #expect(StateStore.loadConversation(id: id, stateURL: stateURL, env: [:])?.updatedAt == t0)
    await client.close()

    // 3. Reopening/reconnecting with no recovered messages must NOT bump updatedAt.
    clock.advance(by: 3600)
    let reopenRPC = FakeCodexTransport()
    reopenRPC.resumeResult = .success(CodexPayload(["thread": ["id": ready.threadId, "turns": []]]))
    let reopened = ChatClient(rpc: reopenRPC, options: options)
    let reopenedReady = try await reopened.connect()
    #expect(reopenedReady.conversationId == id)
    #expect(StateStore.loadConversation(id: id, stateURL: stateURL, env: [:])?.updatedAt == t0)

    // 4. Model catalog fallback on reloadOpenRouter must NOT bump updatedAt.
    clock.advance(by: 3600)
    try OpenRouterClient.saveConfig(key: "", to: configURL)
    _ = await reopened.reloadOpenRouter()
    #expect(StateStore.loadConversation(id: id, stateURL: stateURL, env: [:])?.updatedAt == t0)

    // 5. Stopping an OpenRouter turn IS message activity and DOES bump updatedAt.
    try OpenRouterClient.saveConfig(key: "test-or-key", to: configURL)
    _ = await reopened.reloadOpenRouter()
    _ = try await reopened.selectModel(routerModel)
    clock.advance(by: 3600)
    let stoppedTimestamp = StateStore.formatTimestamp(clock.now())
    let executionID = UUID()
    try reopened.acceptSend("Stop me", userMessageId: "u2", executionID: executionID)
    reopened.requestStop(executionID: executionID)
    let afterStop = try #require(StateStore.loadConversation(id: id, stateURL: stateURL, env: [:]))
    #expect(afterStop.createdAt == t0)
    #expect(afterStop.updatedAt == stoppedTimestamp)
    await reopened.close()

    // 6. Recovering a missing Codex reply on reconnect IS message activity and DOES bump updatedAt.
    clock.advance(by: 3600)
    let recoveredTimestamp = StateStore.formatTimestamp(clock.now())
    let recoveryRPC = FakeCodexTransport()
    recoveryRPC.resumeResult = .success(CodexPayload(["thread": ["id": ready.threadId, "turns": [
        ["id": "turn-1", "items": [
            ["id": "wire-u1", "type": "userMessage", "clientId": "u1",
             "content": [["type": "text", "text": "Initial question"]]],
            ["id": "a1", "type": "agentMessage", "text": "Initial answer"],
            ["id": "a1-extra", "type": "agentMessage", "text": "Recovered addendum"],
        ]],
    ]]]))
    let recoveredClient = ChatClient(rpc: recoveryRPC, options: options)
    let recoveredReady = try await recoveredClient.connect()
    #expect(recoveredReady.messages.contains { $0.id == "a1-extra" })
    let afterRecovery = try #require(StateStore.loadConversation(id: id, stateURL: stateURL, env: [:]))
    #expect(afterRecovery.createdAt == t0)
    #expect(afterRecovery.updatedAt == recoveredTimestamp)
    await recoveredClient.close()
}

@Test func restartReopensLastActiveOrBlankNewChatWithoutImportingExternalCodexThreads() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-restart-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let configURL = dir.appendingPathComponent("openrouter.json")
    let routerModel = OpenRouterClient.defaultModels[0].model
    try OpenRouterClient.saveConfig(key: "test-or-key", to: configURL)

    let clock = TestClock(Date(timeIntervalSince1970: 1_777_629_600))
    let options = ChatClientOptions(
        openRouterConfigURL: configURL,
        stateURL: stateURL,
        env: [:],
        now: { clock.now() }
    )

    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: options)
    let firstReady = try await client.connect()
    try await client.send("First topic about sourdough", userMessageId: "c1-u1")
    completeCodexTurn(
        rpc: rpc, threadId: firstReady.threadId,
        userMessageId: "c1-u1", userText: "First topic about sourdough",
        replyId: "c1-a1", replyText: "Feed your starter twice daily."
    )
    let id1 = try #require(client.conversationId)

    clock.advance(by: 60)
    let secondReady = try await client.newChat()
    try await client.send("Second topic about hiking boots", userMessageId: "c2-u1")
    completeCodexTurn(
        rpc: rpc, threadId: secondReady.threadId,
        userMessageId: "c2-u1", userText: "Second topic about hiking boots",
        replyId: "c2-a1", replyText: "Break them in on short trails first."
    )
    let id2 = try #require(client.conversationId)
    await client.close()

    // 1. Restarting reopens the last-active saved conversation (Conversation 2) and never imports external Codex threads.
    let restartRPC = FakeCodexTransport()
    restartRPC.resumeResult = .success(CodexPayload(["thread": [
        "id": secondReady.threadId,
        "turns": [
            ["id": "external-turn", "items": [
                ["id": "ext-u", "type": "userMessage", "content": [["type": "text", "text": "External CLI prompt"]]],
                ["id": "ext-a", "type": "agentMessage", "text": "External CLI answer"],
            ]],
        ],
    ]]))
    let restarted = ChatClient(rpc: restartRPC, options: options)
    let restoredActive = try await restarted.connect()
    #expect(restoredActive.conversationId == id2)
    #expect(restoredActive.messages.map(\.text) == [
        "Second topic about hiking boots",
        "Break them in on short trails first.",
    ])
    #expect(restarted.savedConversations().map(\.id) == [id2, id1])
    #expect(!restartRPC.calls.contains { $0.method == "thread/list" })

    // 2. Leaving the panel on a blank New Chat reopens as a blank New Chat while preserving saved conversations.
    _ = try await restarted.selectModel(routerModel)
    let blank = try await restarted.newChat()
    #expect(blank.conversationId == nil)
    #expect(blank.messages.isEmpty)
    await restarted.close()

    let afterBlankRPC = FakeCodexTransport()
    let afterBlank = ChatClient(rpc: afterBlankRPC, options: options)
    let restoredBlank = try await afterBlank.connect()
    #expect(restoredBlank.conversationId == nil)
    #expect(restoredBlank.messages.isEmpty)
    #expect(restoredBlank.model == routerModel)
    #expect(restoredBlank.threadId == blank.threadId)
    #expect(afterBlank.savedConversations().map(\.id) == [id2, id1])
    #expect(!afterBlankRPC.calls.contains { $0.method == "thread/list" })
    await afterBlank.close()

    // 3. Reconnecting completely offline while left on a blank New Chat still exposes saved conversations locally.
    try OpenRouterClient.saveConfig(key: "", to: configURL)
    let offlineRPC = FakeCodexTransport()
    offlineRPC.failStart = true
    let offlineClient = ChatClient(rpc: offlineRPC, options: options)
    let offlineReady = try await offlineClient.connect()
    #expect(offlineReady.conversationId == nil)
    #expect(offlineReady.messages.isEmpty)
    #expect(offlineReady.offlineReason != nil)
    #expect(offlineClient.savedConversations().map(\.id) == [id2, id1])
    await offlineClient.close()
}
