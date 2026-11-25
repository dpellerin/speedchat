@testable import ChatCore
import Foundation
import Testing
@testable import SpeedChat

@Test func bridgeDeletesIndividualSavedConversationsOnlineAndOfflinePreservingSearchQueryWithoutCodexRPCs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-history-delete-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let stateURL = root.appendingPathComponent("state.json")
    let fixtureNow = try #require(StateStore.parseTimestamp("2026-05-15T10:00:00.000Z"))
    let convLisbon = SavedConversation(
        id: "conv-lisbon",
        title: "Lisbon tram route",
        createdAt: "2026-05-12T10:00:00.000Z",
        updatedAt: "2026-05-12T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-lisbon",
        messages: [ChatMessage(id: "m1", role: "user", text: "Ride Tram 28 in Lisbon")]
    )
    let convPorto = SavedConversation(
        id: "conv-porto",
        title: "Porto tram museums",
        createdAt: "2026-05-13T10:00:00.000Z",
        updatedAt: "2026-05-13T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-porto",
        messages: [ChatMessage(id: "m2", role: "user", text: "Vintage tram line in Porto")]
    )
    let convCoffee = SavedConversation(
        id: "conv-coffee",
        title: "Pour over ratio",
        createdAt: "2026-05-14T10:00:00.000Z",
        updatedAt: "2026-05-14T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-coffee",
        messages: [ChatMessage(id: "m3", role: "user", text: "Best V60 recipe")]
    )
    try StateStore.saveActiveConversation(convLisbon, to: stateURL)
    try StateStore.saveActiveConversation(convPorto, to: stateURL)
    try StateStore.saveActiveConversation(convCoffee, to: stateURL)

    // 1. Online bridge: delete a non-active search match while query is active, then delete active conversation.
    let rpcLog = root.appendingPathComponent("rpc.log")
    let codex = root.appendingPathComponent("fake-codex")
    let script = """
    #!/usr/bin/env python3
    import json, sys
    log_path = \(String(reflecting: rpcLog.path))
    for raw in sys.stdin:
        msg = json.loads(raw)
        if "id" not in msg:
            continue
        method, mid = msg["method"], msg["id"]
        with open(log_path, "a") as f:
            f.write(method + "\\n")
        if method == "initialize" or method == "thread/name/set":
            print(json.dumps({"id": mid, "result": {}}), flush=True)
        elif method == "model/list":
            print(json.dumps({"id": mid, "result": {"data": [{"model": "gpt-6-luna", "displayName": "GPT-6 Luna", "supportedReasoningEfforts": [{"reasoningEffort": "low"}]}]}}), flush=True)
        elif method == "thread/resume":
            tid = msg["params"]["threadId"]
            print(json.dumps({"id": mid, "result": {"thread": {"id": tid, "name": "Resumed", "turns": []}}}), flush=True)
    """
    try script.write(to: codex, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)

    let onlineBridge = BridgeProcess()
    let (onlineEvents, onlineSink) = AsyncStream<BridgeEvent>.makeStream()
    let onlineTimeout = Task {
        try? await Task.sleep(for: .seconds(5))
        onlineSink.finish()
    }
    defer { onlineTimeout.cancel() }

    onlineBridge.start(codexOverride: codex.path, options: ChatClientOptions(
        openRouterConfigURL: root.appendingPathComponent("openrouter.json"),
        stateURL: stateURL,
        env: [:],
        now: { fixtureNow }
    )) { onlineSink.yield($0) }

    var onlineIter = onlineEvents.makeAsyncIterator()
    let initialOnline = try #require(await onlineIter.next())
    #expect(initialOnline.type == "ready")
    #expect(initialOnline.conversationId == "conv-coffee")

    // Clear RPC log after startup, then delete non-active conv-porto while filtering by "tram".
    try "".write(to: rpcLog, atomically: true, encoding: .utf8)
    onlineBridge.send(["type": "deleteConversation", "conversationId": "conv-porto", "query": "tram"])
    let filteredAfterDelete = try #require(await onlineIter.next())
    #expect(filteredAfterDelete.type == "history")
    #expect(filteredAfterDelete.query == "tram")
    #expect(filteredAfterDelete.clearedActiveConversation == false)
    #expect(filteredAfterDelete.history?.map(\.id) == ["conv-lisbon"])
    #expect(StateStore.loadConversation(id: "conv-porto", stateURL: stateURL, env: [:]) == nil)

    // Delete currently active conv-coffee -> emits blank ready reset + updated history, ZERO Codex RPCs.
    onlineBridge.send(["type": "deleteConversation", "conversationId": "conv-coffee"])
    let resetOnline = try #require(await onlineIter.next())
    #expect(resetOnline.type == "ready")
    #expect(resetOnline.conversationId == nil)
    #expect(resetOnline.messages == [])
    #expect(resetOnline.clearedActiveConversation == true)

    let historyAfterActiveDelete = try #require(await onlineIter.next())
    #expect(historyAfterActiveDelete.type == "history")
    #expect(historyAfterActiveDelete.clearedActiveConversation == true)
    #expect(historyAfterActiveDelete.history?.map(\.id) == ["conv-lisbon"])

    let rpcsDuringDelete = try String(contentsOf: rpcLog, encoding: .utf8)
    #expect(rpcsDuringDelete.isEmpty)

    await withCheckedContinuation { cont in
        onlineBridge.close { cont.resume() }
    }

    // 2. Offline bridge: open conv-lisbon as active, then delete it offline -> blank offline state + empty History.
    try StateStore.saveActiveConversation(convLisbon, to: stateURL)
    let failingCodex = root.appendingPathComponent("failing-codex")
    try "#!/bin/sh\nexit 17\n".write(to: failingCodex, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failingCodex.path)

    let offlineBridge = BridgeProcess()
    let (offlineEvents, offlineSink) = AsyncStream<BridgeEvent>.makeStream()
    let offlineTimeout = Task {
        try? await Task.sleep(for: .seconds(5))
        offlineSink.finish()
    }
    defer { offlineTimeout.cancel() }

    offlineBridge.start(codexOverride: failingCodex.path, options: ChatClientOptions(
        openRouterConfigURL: root.appendingPathComponent("openrouter.json"),
        stateURL: stateURL,
        env: [:],
        now: { fixtureNow }
    )) { offlineSink.yield($0) }

    var offlineIter = offlineEvents.makeAsyncIterator()
    let initialOffline = try #require(await offlineIter.next())
    #expect(initialOffline.type == "offlineConversation")
    #expect(initialOffline.conversationId == "conv-lisbon")

    offlineBridge.send(["type": "deleteConversation", "conversationId": "conv-lisbon"])
    let resetOffline = try #require(await offlineIter.next())
    #expect(resetOffline.type == "offlineConversation")
    #expect(resetOffline.conversationId == nil)
    #expect(resetOffline.messages == [])
    #expect(resetOffline.models == [])
    #expect(resetOffline.clearedActiveConversation == true)

    let emptyOfflineHistory = try #require(await offlineIter.next())
    #expect(emptyOfflineHistory.type == "history")
    #expect(emptyOfflineHistory.history == [])
    #expect(emptyOfflineHistory.clearedActiveConversation == true)

    await withCheckedContinuation { cont in
        offlineBridge.close { cont.resume() }
    }
}

@MainActor
@Test func chatStoreConfirmsCancelsDeletesPreservesSearchAndTransitionsDeletedActiveToBlankNewChat() async throws {
    let backend = RecordingHistoryBackend()
    let store = ChatStore { backend }
    store.shouldFocusComposer = { true }
    var historyChangedCount = 0
    store.onHistoryChanged = { historyChangedCount += 1 }

    store.connect()
    let models = [ChatModel(model: "gpt-6-luna", displayName: "GPT-6 Luna", provider: "openai")]
    let entryA = HistoryEntry(id: "conv-a", title: "Lisbon tram plan", updatedAt: "2026-05-14T10:00:00.000Z", preview: "Ride Tram 28.", model: "gpt-6-luna", messageCount: 2)
    let entryB = HistoryEntry(id: "conv-b", title: "Porto tram guide", updatedAt: "2026-05-13T10:00:00.000Z", preview: "Vintage trams.", model: "gpt-6-luna", messageCount: 2)

    backend.emit(BridgeEvent(
        type: "ready",
        conversationId: "conv-b",
        messages: [ChatMessage(id: "b-u1", role: "user", text: "Porto trams")],
        models: models,
        model: "gpt-6-luna"
    ))
    try await waitForHistoryCondition { store.session.conversationId == "conv-b" }
    store.draft = "Draft for B"

    // Switch to conv-a so conv-b has an in-memory draft saved.
    store.openHistory()
    backend.emit(BridgeEvent(type: "history", history: [entryA, entryB]))
    try await waitForHistoryCondition { store.historyEntries.count == 2 }
    store.openSelectedHistoryConversation()
    backend.emit(BridgeEvent(
        type: "ready",
        conversationId: "conv-a",
        messages: [ChatMessage(id: "a-u1", role: "user", text: "Lisbon trams")],
        models: models,
        model: "gpt-6-luna"
    ))
    try await waitForHistoryCondition { store.session.conversationId == "conv-a" }
    store.draft = "Draft for A"

    // Requesting delete when History is closed does nothing.
    #expect(!store.requestDeleteSelectedHistoryConversation())
    #expect(store.pendingDeleteEntry == nil)

    // Open History, search "tram", highlight row 1 (conv-b), press ⌘⌫ -> prompts confirmation, does NOT delete yet.
    store.openHistory()
    store.updateHistoryQuery("tram")
    backend.emit(BridgeEvent(type: "history", history: [entryA, entryB], query: "tram"))
    try await waitForHistoryCondition { store.historyEntries.count == 2 }
    store.moveHistorySelection(1)

    let commandsBeforePrompt = backend.commands.count
    #expect(store.requestDeleteSelectedHistoryConversation())
    #expect(store.pendingDeleteEntry == entryB)
    #expect(backend.commands.count == commandsBeforePrompt)

    // Cancelling leaves History list, active conversation, and Draft untouched, and refocuses History search.
    let historyFocusBeforeCancel = store.historyFocusToken
    store.cancelDeleteHistoryConversation()
    #expect(store.pendingDeleteEntry == nil)
    #expect(store.historyEntries == [entryA, entryB])
    #expect(store.session.conversationId == "conv-a")
    #expect(store.draft == "Draft for A")
    #expect(backend.commands.count == commandsBeforePrompt)
    #expect(store.historyFocusToken == historyFocusBeforeCancel + 1)

    // Confirming deletion of non-active conv-b while searching "tram":
    // forwards active query, updates list immediately, refreshes onHistoryChanged, keeps active conv-a & Draft for A.
    let changedBeforeDeleteB = historyChangedCount
    store.requestDeleteHistoryConversation(entryB)
    #expect(store.pendingDeleteEntry == entryB)
    let historyFocusBeforeConfirm = store.historyFocusToken
    store.confirmDeleteHistoryConversation()
    #expect(store.pendingDeleteEntry == nil)
    #expect(store.historyFocusToken == historyFocusBeforeConfirm + 1)
    #expect(backend.commands.last == ["type": "deleteConversation", "conversationId": "conv-b", "query": "tram"])

    backend.emit(BridgeEvent(type: "history", history: [entryA], clearedActiveConversation: false, query: "tram"))
    try await waitForHistoryCondition { store.historyEntries == [entryA] }
    #expect(store.selectedHistoryIndex == 0)
    #expect(store.historyQuery == "tram")
    #expect(store.session.conversationId == "conv-a")
    #expect(store.draft == "Draft for A")
    #expect(historyChangedCount > changedBeforeDeleteB)

    // Clear search, then delete the CURRENTLY ACTIVE conversation (conv-a, the last remaining saved conversation).
    store.clearHistoryQuery()
    backend.emit(BridgeEvent(type: "history", history: [entryA], query: ""))
    try await waitForHistoryCondition { store.historyQuery.isEmpty && store.historyEntries == [entryA] }

    let changedBeforeDeleteA = historyChangedCount
    #expect(store.requestDeleteSelectedHistoryConversation())
    #expect(store.pendingDeleteEntry == entryA)
    store.confirmDeleteHistoryConversation()
    #expect(backend.commands.last == ["type": "deleteConversation", "conversationId": "conv-a"])
    #expect(store.draft.isEmpty)

    backend.emit(BridgeEvent(
        type: "ready",
        conversationId: nil,
        messages: [],
        models: models,
        model: "gpt-6-luna",
        notice: "New chat",
        clearedActiveConversation: true
    ))
    backend.emit(BridgeEvent(type: "history", history: [], clearedActiveConversation: true, query: ""))
    try await waitForHistoryCondition { store.historyEntries.isEmpty && store.session.conversationId == nil }
    #expect(!store.hasActiveHistoryQuery)
    #expect(historyChangedCount > changedBeforeDeleteA)
    // Pressing ⌘⌫ when History is empty does nothing and returns false.
    #expect(!store.requestDeleteSelectedHistoryConversation())
    #expect(store.pendingDeleteEntry == nil)

    // Abandoning History (Esc / ⌘K / Back) lands cleanly on a fresh blank New Chat with empty Draft & composer focus.
    let focusBeforeClose = store.focusToken
    store.closeHistory()
    #expect(!store.showingHistory)
    #expect(store.session.conversationId == nil)
    #expect(store.session.messages.isEmpty)
    #expect(store.draft.isEmpty)
    #expect(store.focusToken == focusBeforeClose + 1)

    // Panel hide() after deleting active conversation (even before backend ready event arrives) also lands on blank New Chat!
    backend.emit(BridgeEvent(
        type: "ready",
        conversationId: "conv-c",
        messages: [ChatMessage(id: "c-u1", role: "user", text: "Active chat C")],
        models: models,
        model: "gpt-6-luna"
    ))
    try await waitForHistoryCondition { store.session.conversationId == "conv-c" }
    store.draft = "Unsent draft C"
    let entryC = HistoryEntry(id: "conv-c", title: "Active chat C", updatedAt: "2026-05-15T10:00:00.000Z", preview: "Active chat C", model: "gpt-6-luna", messageCount: 1)
    store.openHistory()
    backend.emit(BridgeEvent(type: "history", history: [entryC]))
    try await waitForHistoryCondition { store.historyEntries == [entryC] }
    store.requestDeleteHistoryConversation(entryC)
    store.confirmDeleteHistoryConversation()
    // Immediately hide Panel before backend emits ready -> must transition cleanly to blank New Chat!
    store.hide()
    #expect(!store.showingHistory)
    #expect(store.pendingDeleteEntry == nil)
    #expect(store.session.conversationId == nil)
    #expect(store.session.messages.isEmpty)
    #expect(store.draft.isEmpty)

    store.stop()
}

@MainActor
@Test func chatStoreDeletesConversationLocallyWhenBridgeIsStoppedOffline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("store-delete-offline-stopped-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let stateURL = root.appendingPathComponent("state.json")
    let fixtureNow = try #require(StateStore.parseTimestamp("2026-05-15T10:00:00.000Z"))
    let conv = SavedConversation(
        id: "conv-offline-only",
        title: "Offline note",
        createdAt: "2026-05-14T10:00:00.000Z",
        updatedAt: "2026-05-14T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-offline-only",
        messages: [ChatMessage(id: "u1", role: "user", text: "Remember offline note")]
    )
    try StateStore.saveActiveConversation(conv, to: stateURL)

    let store = ChatStore()
    store.stateURL = stateURL
    store.environment = [:]
    store.now = { fixtureNow }
    var historyChangedCount = 0
    store.onHistoryChanged = { historyChangedCount += 1 }

    // Simulate an idle-stopped offline session holding conv-offline-only.
    store.receive(BridgeEvent(
        type: "offlineConversation",
        conversationId: conv.id,
        messages: conv.messages,
        models: [],
        model: conv.model,
        notice: "Resting · reopen to reconnect"
    ))
    store.draft = "Offline unsent draft"

    store.openHistory()
    store.receive(BridgeEvent(type: "history", history: [ConversationHistory.entry(from: conv)]))
    #expect(store.historyEntries.count == 1)

    let changedBefore = historyChangedCount
    #expect(store.requestDeleteSelectedHistoryConversation())
    store.confirmDeleteHistoryConversation()

    #expect(store.historyEntries.isEmpty)
    #expect(store.session.conversationId == nil)
    #expect(store.session.messages.isEmpty)
    #expect(store.session.phase == .offline)
    #expect(store.draft.isEmpty)
    #expect(StateStore.loadConversation(id: conv.id, stateURL: stateURL, env: [:]) == nil)
    #expect(historyChangedCount > changedBefore)

    // Abandoning History lands on blank offline state (not deleted conversation).
    store.closeHistory()
    #expect(!store.showingHistory)
    #expect(store.session.conversationId == nil)
    #expect(store.session.messages.isEmpty)
    #expect(store.draft.isEmpty)
}
