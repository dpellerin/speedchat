@testable import ChatCore
import Foundation
import Testing
@testable import SpeedChat

@Test func bridgeListsAndOpensSavedConversationsOnlineWithoutCodexResumeUntilNextSend() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-history-online-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let stateURL = root.appendingPathComponent("state.json")
    let conv1 = SavedConversation(
        id: "conv-older",
        title: "Older trip",
        createdAt: "2026-04-01T10:00:00.000Z",
        updatedAt: "2026-04-01T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-older",
        messages: [
            ChatMessage(id: "u1", role: "user", text: "Plan Lisbon"),
            ChatMessage(id: "a1", role: "assistant", text: "Visit Alfama."),
        ],
        codexSyncedCount: 2
    )
    let conv2 = SavedConversation(
        id: "conv-newer",
        title: "Newer recipe",
        createdAt: "2026-04-02T10:00:00.000Z",
        updatedAt: "2026-04-02T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-newer",
        messages: [
            ChatMessage(id: "u2", role: "user", text: "Sourdough tips"),
            ChatMessage(id: "a2", role: "assistant", text: "Use warm water."),
        ],
        codexSyncedCount: 2
    )
    try StateStore.saveActiveConversation(conv1, to: stateURL)
    try StateStore.saveActiveConversation(conv2, to: stateURL)

    let resumeLog = root.appendingPathComponent("resumes.log")
    let codex = root.appendingPathComponent("fake-codex")
    let script = """
    #!/usr/bin/env python3
    import json, sys
    log_path = \(String(reflecting: resumeLog.path))
    for raw in sys.stdin:
        msg = json.loads(raw)
        if "id" not in msg:
            continue
        method, mid = msg["method"], msg["id"]
        if method == "initialize" or method == "thread/name/set":
            print(json.dumps({"id": mid, "result": {}}), flush=True)
        elif method == "model/list":
            print(json.dumps({"id": mid, "result": {"data": [{"model": "gpt-6-luna", "displayName": "GPT-6 Luna", "supportedReasoningEfforts": [{"reasoningEffort": "low"}]}]}}), flush=True)
        elif method == "thread/resume":
            tid = msg["params"]["threadId"]
            with open(log_path, "a") as f:
                f.write(tid + "\\n")
            print(json.dumps({"id": mid, "result": {"thread": {"id": tid, "name": "Resumed", "turns": []}}}), flush=True)
        elif method == "turn/start":
            tid = msg["params"]["threadId"]
            cid = msg["params"]["clientUserMessageId"]
            print(json.dumps({"id": mid, "result": {"turn": {"id": "turn-1"}}}), flush=True)
            print(json.dumps({"method": "item/started", "params": {"threadId": tid, "turnId": "turn-1", "item": {"id": "ru", "type": "userMessage", "clientId": cid, "content": msg["params"]["input"]}}}), flush=True)
            print(json.dumps({"method": "item/completed", "params": {"threadId": tid, "turnId": "turn-1", "item": {"id": "ra", "type": "agentMessage", "text": "Continued!"}}}), flush=True)
            print(json.dumps({"method": "turn/completed", "params": {"threadId": tid, "turn": {"id": "turn-1", "status": "completed"}}}), flush=True)
    """
    try script.write(to: codex, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)

    let bridge = BridgeProcess()
    let (events, sink) = AsyncStream<BridgeEvent>.makeStream()
    let timeout = Task {
        try? await Task.sleep(for: .seconds(5))
        sink.finish()
    }
    defer { timeout.cancel() }

    bridge.start(codexOverride: codex.path, options: ChatClientOptions(
        openRouterConfigURL: root.appendingPathComponent("openrouter.json"),
        stateURL: stateURL,
        env: [:]
    )) { sink.yield($0) }

    var iter = events.makeAsyncIterator()
    let initial = try #require(await iter.next())
    #expect(initial.type == "ready")
    #expect(initial.conversationId == "conv-newer")

    // List History returns newest first.
    bridge.send(["type": "listHistory"])
    let historyEvent = try #require(await iter.next())
    #expect(historyEvent.type == "history")
    #expect(historyEvent.history?.map(\.id) == ["conv-newer", "conv-older"])

    // Clear resume log after initial connect, then open conv-older: ZERO thread/resume calls!
    try "".write(to: resumeLog, atomically: true, encoding: .utf8)
    bridge.send(["type": "openConversation", "conversationId": "conv-older"])
    let opened = try #require(await iter.next())
    #expect(opened.type == "ready")
    #expect(opened.conversationId == "conv-older")
    #expect(opened.messages?.map(\.text) == ["Plan Lisbon", "Visit Alfama."])
    let resumesAfterOpen = try String(contentsOf: resumeLog, encoding: .utf8)
    #expect(resumesAfterOpen.isEmpty)

    // Next OpenAI send lazily resumes codex-older.
    let execId = UUID()
    bridge.send(["type": "send", "text": "And Sintra?", "itemId": "u-follow", "executionID": execId.uuidString])
    var sawDone = false
    while let ev = await iter.next() {
        if ev.type == "done" {
            #expect(ev.conversationId == "conv-older")
            sawDone = true
            break
        }
    }
    #expect(sawDone)
    let resumesAfterSend = try String(contentsOf: resumeLog, encoding: .utf8)
    #expect(resumesAfterSend.contains("codex-older"))

    await withCheckedContinuation { cont in
        bridge.close { cont.resume() }
    }
}

@Test func bridgeListsAndOpensSavedConversationsWhileOffline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-history-offline-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let stateURL = root.appendingPathComponent("state.json")
    let conv1 = SavedConversation(
        id: "conv-1",
        title: "First offline chat",
        createdAt: "2026-04-01T10:00:00.000Z",
        updatedAt: "2026-04-01T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-1",
        messages: [ChatMessage(id: "u1", role: "user", text: "Hello offline 1")]
    )
    let conv2 = SavedConversation(
        id: "conv-2",
        title: "Second offline chat",
        createdAt: "2026-04-02T10:00:00.000Z",
        updatedAt: "2026-04-02T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-2",
        messages: [ChatMessage(id: "u2", role: "user", text: "Hello offline 2")]
    )
    try StateStore.saveActiveConversation(conv1, to: stateURL)
    try StateStore.saveActiveConversation(conv2, to: stateURL)

    let failingCodex = root.appendingPathComponent("failing-codex")
    try "#!/bin/sh\nexit 17\n".write(to: failingCodex, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failingCodex.path)

    let bridge = BridgeProcess()
    let (events, sink) = AsyncStream<BridgeEvent>.makeStream()
    let timeout = Task {
        try? await Task.sleep(for: .seconds(5))
        sink.finish()
    }
    defer { timeout.cancel() }

    bridge.start(codexOverride: failingCodex.path, options: ChatClientOptions(
        openRouterConfigURL: root.appendingPathComponent("openrouter.json"),
        stateURL: stateURL,
        env: [:]
    )) { sink.yield($0) }

    var iter = events.makeAsyncIterator()
    let initial = try #require(await iter.next())
    #expect(initial.type == "offlineConversation")
    #expect(initial.conversationId == "conv-2")

    bridge.send(["type": "listHistory"])
    let historyEvent = try #require(await iter.next())
    #expect(historyEvent.type == "history")
    #expect(historyEvent.history?.map(\.id) == ["conv-2", "conv-1"])

    bridge.send(["type": "openConversation", "conversationId": "conv-1"])
    let opened = try #require(await iter.next())
    #expect(opened.type == "offlineConversation")
    #expect(opened.conversationId == "conv-1")
    #expect(opened.messages?.map(\.text) == ["Hello offline 1"])
    #expect(opened.models == [])
    #expect(opened.notice?.hasPrefix("Offline · ") == true)

    await withCheckedContinuation { cont in
        bridge.close { cont.resume() }
    }
}

@MainActor
@Test func chatStoreGatesHistoryNavigatesPreservesPerConversationDraftsAndResetsOnHideOrNewChat() async throws {
    let backend = RecordingHistoryBackend()
    let store = ChatStore { backend }
    store.shouldFocusComposer = { true }

    // Connecting blocks History.
    store.connect()
    #expect(store.session.phase == .connecting)
    store.openHistory()
    #expect(!store.showingHistory)

    // Ready allows History and preserves active conversation's draft across switches.
    let models = [ChatModel(model: "gpt-6-luna", displayName: "GPT-6 Luna", provider: "openai")]
    let entryA = HistoryEntry(id: "conv-a", title: "Trip to Lisbon", updatedAt: "2026-04-02T10:00:00.000Z", preview: "Visit Alfama.", model: "gpt-6-luna", messageCount: 2)
    let entryB = HistoryEntry(id: "conv-b", title: "Sourdough starter", updatedAt: "2026-04-01T10:00:00.000Z", preview: "Feed twice daily.", model: "gpt-6-luna", messageCount: 2)
    backend.emit(BridgeEvent(
        type: "ready",
        conversationId: "conv-a",
        messages: [ChatMessage(id: "a-u1", role: "user", text: "Plan Lisbon")],
        models: models,
        model: "gpt-6-luna"
    ))
    try await waitForCondition { store.session.phase == .ready }
    #expect(store.session.conversationId == "conv-a")

    store.draft = "Unsent Lisbon follow-up"

    // Active turn blocks History.
    store.send()
    #expect(store.session.streaming)
    store.openHistory()
    #expect(!store.showingHistory)
    backend.emit(BridgeEvent(type: "done", conversationId: "conv-a", executionID: store.session.executionID))
    try await waitForCondition { store.session.phase == .ready }

    // Draft cleared on send; write new unsent draft for Conversation A.
    #expect(store.draft.isEmpty)
    store.draft = "Draft for A"

    // Open History -> requests listHistory, highlights first entry.
    store.toggleHistory()
    #expect(store.showingHistory)
    #expect(backend.commands.last == ["type": "listHistory"])
    backend.emit(BridgeEvent(type: "history", history: [entryA, entryB]))
    try await waitForCondition { store.historyEntries.count == 2 }
    #expect(store.selectedHistoryIndex == 0)

    // Keyboard navigation clamps within bounds.
    store.moveHistorySelection(-1)
    #expect(store.selectedHistoryIndex == 0)
    store.moveHistorySelection(1)
    #expect(store.selectedHistoryIndex == 1)
    store.moveHistorySelection(1)
    #expect(store.selectedHistoryIndex == 1)

    // Abandoning via closeHistory leaves Conversation A and its Draft untouched.
    let focusBeforeAbandon = store.focusToken
    store.closeHistory()
    #expect(!store.showingHistory)
    #expect(store.session.conversationId == "conv-a")
    #expect(store.draft == "Draft for A")
    #expect(store.focusToken == focusBeforeAbandon + 1)

    // Reopen History, select Conversation B with ↓ + ↵ -> saves Draft for A, loads empty Draft for B.
    store.openHistory()
    backend.emit(BridgeEvent(type: "history", history: [entryA, entryB]))
    try await waitForCondition { store.historyEntries.count == 2 }
    store.moveHistorySelection(1)
    store.openSelectedHistoryConversation()
    #expect(!store.showingHistory)
    #expect(store.draft.isEmpty)
    #expect(backend.commands.last == ["type": "openConversation", "conversationId": "conv-b"])
    backend.emit(BridgeEvent(
        type: "ready",
        conversationId: "conv-b",
        messages: [ChatMessage(id: "b-u1", role: "user", text: "Sourdough tips")],
        models: models,
        model: "gpt-6-luna"
    ))
    try await waitForCondition { store.session.conversationId == "conv-b" }

    // Write Draft for B, switch back to A -> restores Draft for A!
    store.draft = "Draft for B"
    store.openHistory()
    backend.emit(BridgeEvent(type: "history", history: [entryA, entryB]))
    try await waitForCondition { store.historyEntries.count == 2 }
    store.openSelectedHistoryConversation()
    #expect(store.draft == "Draft for A")
    backend.emit(BridgeEvent(
        type: "ready",
        conversationId: "conv-a",
        messages: [ChatMessage(id: "a-u1", role: "user", text: "Plan Lisbon")],
        models: models,
        model: "gpt-6-luna"
    ))
    try await waitForCondition { store.session.conversationId == "conv-a" }

    // Hiding the Panel while History is open abandons History and preserves active conversation & Draft.
    store.openHistory()
    #expect(store.showingHistory)
    store.hide()
    #expect(!store.showingHistory)
    #expect(store.session.conversationId == "conv-a")
    #expect(store.draft == "Draft for A")

    // Pressing ⌘N / New Chat while inside History closes History, starts a fresh empty Draft,
    // and preserves Conversation A's draft for later return.
    store.openHistory()
    #expect(store.showingHistory)
    store.newChat()
    #expect(!store.showingHistory)
    #expect(store.draft.isEmpty)
    #expect(backend.commands.last == ["type": "newChat"])
    backend.emit(BridgeEvent(type: "ready", conversationId: nil, messages: [], models: models, model: "gpt-6-luna"))
    try await waitForCondition { store.session.conversationId == nil && store.session.phase == .ready }

    // Switching back to Conversation B still has Draft for B intact.
    store.openHistory()
    backend.emit(BridgeEvent(type: "history", history: [entryA, entryB]))
    try await waitForCondition { store.historyEntries.count == 2 }
    store.moveHistorySelection(1)
    store.openSelectedHistoryConversation()
    #expect(store.draft == "Draft for B")
    backend.emit(BridgeEvent(
        type: "ready",
        conversationId: "conv-b",
        messages: [ChatMessage(id: "b-u1", role: "user", text: "Sourdough tips")],
        models: models,
        model: "gpt-6-luna"
    ))
    try await waitForCondition { store.session.conversationId == "conv-b" }

    // History stays usable after a fatal offline disconnect (stream does not finish on fatal).
    backend.emit(BridgeEvent(type: "fatal", message: "Codex stopped."))
    try await waitForCondition { store.session.phase == .offline }
    store.openHistory()
    #expect(store.showingHistory)
    backend.emit(BridgeEvent(type: "history", history: [entryA]))
    try await waitForCondition { store.historyEntries == [entryA] }
    store.openSelectedHistoryConversation()
    #expect(!store.showingHistory)
    #expect(store.draft == "Draft for A")
    backend.emit(BridgeEvent(
        type: "offlineConversation",
        conversationId: "conv-a",
        messages: [ChatMessage(id: "a-u1", role: "user", text: "Plan Lisbon")],
        models: [],
        model: "gpt-6-luna",
        notice: "Offline · Codex stopped."
    ))
    try await waitForCondition { store.session.conversationId == "conv-a" && store.session.phase == .offline }

    store.stop()
}

@MainActor
@Test func windowCoordinatorShowHistoryFromMenuShowsPanelAndInvokesHistoryCallback() {
    let workspace = MinimalWindowWorkspace()
    var showCount = 0
    var historyCount = 0
    var visibleWhenHistoryOpened = false
    let coordinator = WindowCoordinator(
        workspace: workspace,
        onShow: { showCount += 1 },
        onHide: {},
        onNewChat: {},
        onShowHistory: {
            historyCount += 1
            visibleWhenHistoryOpened = workspace.isPanelVisible
        }
    )

    coordinator.showHistoryFromMenu()
    #expect(workspace.isPanelVisible)
    #expect(workspace.isPanelKey)
    #expect(showCount == 1)
    #expect(historyCount == 1)
    #expect(visibleWhenHistoryOpened)

    // Calling again while already open keeps panel visible and triggers History again without hiding.
    coordinator.showHistoryFromMenu()
    #expect(workspace.isPanelVisible)
    #expect(showCount == 2)
    #expect(historyCount == 2)
}

@Test func bridgeSearchesHistoryAndForwardsScrollToMessageIdOnlineAndOffline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-history-search-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let stateURL = root.appendingPathComponent("state.json")
    let convLisbon = SavedConversation(
        id: "conv-lisbon",
        title: "Portugal coastal itinerary",
        createdAt: "2026-04-01T10:00:00.000Z",
        updatedAt: "2026-04-01T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-lisbon",
        messages: [
            ChatMessage(id: "m1", role: "user", text: "Plan a coastal trip."),
            ChatMessage(id: "m2", role: "assistant", text: "Start in Porto."),
            ChatMessage(id: "m3", role: "assistant", text: "Ride Tram 28 through Alfama at sunrise."),
        ],
        codexSyncedCount: 3
    )
    let convBeam = SavedConversation(
        id: "conv-beam",
        title: "Roasting coffee",
        createdAt: "2026-04-02T10:00:00.000Z",
        updatedAt: "2026-04-02T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-beam",
        messages: [
            ChatMessage(id: "b1", role: "user", text: "Medium roast advice"),
            ChatMessage(id: "b2", role: "assistant", text: "Watch first crack.", reasoning: "SECRET ALFAMA TRAM REASONING"),
        ],
        codexSyncedCount: 2
    )
    try StateStore.saveActiveConversation(convLisbon, to: stateURL)
    try StateStore.saveActiveConversation(convBeam, to: stateURL)

    // 1. Online bridge search and open with scrollToMessageId.
    let codex = root.appendingPathComponent("fake-codex")
    let script = """
    #!/usr/bin/env python3
    import json, sys
    for raw in sys.stdin:
        msg = json.loads(raw)
        if "id" not in msg:
            continue
        method, mid = msg["method"], msg["id"]
        if method == "initialize":
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
        env: [:]
    )) { onlineSink.yield($0) }

    var onlineIter = onlineEvents.makeAsyncIterator()
    let initialOnline = try #require(await onlineIter.next())
    #expect(initialOnline.type == "ready")

    onlineBridge.send(["type": "listHistory", "query": "alfama tram"])
    let searchEvent = try #require(await onlineIter.next())
    #expect(searchEvent.type == "history")
    #expect(searchEvent.query == "alfama tram")
    #expect(searchEvent.history?.map(\.id) == ["conv-lisbon"])
    #expect(searchEvent.history?.first?.firstMatchingMessageId == "m3")
    #expect(searchEvent.history?.first?.previewMatchRanges.isEmpty == false)

    onlineBridge.send(["type": "openConversation", "conversationId": "conv-lisbon", "scrollToMessageId": "m3"])
    let openedOnline = try #require(await onlineIter.next())
    #expect(openedOnline.type == "ready")
    #expect(openedOnline.conversationId == "conv-lisbon")
    #expect(openedOnline.scrollToMessageId == "m3")

    await withCheckedContinuation { cont in
        onlineBridge.close { cont.resume() }
    }

    // 2. Offline bridge search and open with scrollToMessageId.
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
        env: [:]
    )) { offlineSink.yield($0) }

    var offlineIter = offlineEvents.makeAsyncIterator()
    let initialOffline = try #require(await offlineIter.next())
    #expect(initialOffline.type == "offlineConversation")

    offlineBridge.send(["type": "listHistory", "query": "alfama"])
    let offlineSearch = try #require(await offlineIter.next())
    #expect(offlineSearch.type == "history")
    #expect(offlineSearch.query == "alfama")
    #expect(offlineSearch.history?.map(\.id) == ["conv-lisbon"])

    offlineBridge.send(["type": "openConversation", "conversationId": "conv-lisbon", "scrollToMessageId": "m3"])
    let openedOffline = try #require(await offlineIter.next())
    #expect(openedOffline.type == "offlineConversation")
    #expect(openedOffline.conversationId == "conv-lisbon")
    #expect(openedOffline.scrollToMessageId == "m3")

    await withCheckedContinuation { cont in
        offlineBridge.close { cont.resume() }
    }
}

@MainActor
@Test func chatStoreSearchesClearsClosesWithEscAndScrollsToMatchIncludingActiveConversation() async throws {
    let backend = RecordingHistoryBackend()
    let store = ChatStore { backend }
    store.shouldFocusComposer = { true }

    store.connect()
    let models = [ChatModel(model: "gpt-6-luna", displayName: "GPT-6 Luna", provider: "openai")]
    let activeMessages = [
        ChatMessage(id: "a-m1", role: "user", text: "Plan Lisbon"),
        ChatMessage(id: "a-m2", role: "assistant", text: "Ride Tram 28 through Alfama."),
        ChatMessage(id: "a-m3", role: "assistant", text: "Enjoy coastal seafood."),
    ]
    backend.emit(BridgeEvent(
        type: "ready",
        conversationId: "conv-a",
        messages: activeMessages,
        models: models,
        model: "gpt-6-luna"
    ))
    try await waitForCondition { store.session.phase == .ready }
    store.draft = "Unsent draft for active chat"

    // Opening History bumps historyFocusToken and clears any prior query.
    let initialHistoryFocus = store.historyFocusToken
    store.openHistory()
    #expect(store.showingHistory)
    #expect(store.historyQuery.isEmpty)
    #expect(store.historyFocusToken == initialHistoryFocus + 1)
    #expect(backend.commands.last == ["type": "listHistory"])

    // Typing a query dispatches listHistory with query and ignores stale responses for earlier queries.
    store.updateHistoryQuery("alf")
    #expect(backend.commands.last == ["type": "listHistory", "query": "alf"])
    store.updateHistoryQuery("alfama")
    #expect(backend.commands.last == ["type": "listHistory", "query": "alfama"])

    let staleEntry = HistoryEntry(id: "conv-stale", title: "Stale", updatedAt: "2026-04-01T10:00:00.000Z", preview: "Alf", model: "gpt-6-luna", messageCount: 1)
    let matchedActive = HistoryEntry(
        id: "conv-a",
        title: "Plan Lisbon",
        updatedAt: "2026-04-02T10:00:00.000Z",
        preview: "Ride Tram 28 through Alfama.",
        model: "gpt-6-luna",
        messageCount: 3,
        previewMatchRanges: [HistoryMatchRange(start: 21, end: 27)],
        firstMatchingMessageId: "a-m2"
    )
    backend.emit(BridgeEvent(type: "history", history: [staleEntry], query: "alf"))
    backend.emit(BridgeEvent(type: "history", history: [matchedActive], query: "alfama"))
    try await waitForCondition { store.historyEntries == [matchedActive] }
    #expect(store.historyEntries.map(\.id) == ["conv-a"])

    // Pressing Esc (closeHistory) while query text is present immediately closes History in one action,
    // clears historyQuery, keeps the active conversation & draft intact, and refocuses composer.
    let composerFocusBeforeEsc = store.focusToken
    store.closeHistory()
    #expect(!store.showingHistory)
    #expect(store.historyQuery.isEmpty)
    #expect(store.session.conversationId == "conv-a")
    #expect(store.draft == "Unsent draft for active chat")
    #expect(store.focusToken == composerFocusBeforeEsc + 1)

    // Reopen History, type a query, then clear with inline × (clearHistoryQuery) -> stays in History and keeps search focused.
    store.openHistory()
    store.updateHistoryQuery("alfama")
    let focusBeforeClear = store.historyFocusToken
    store.clearHistoryQuery()
    #expect(store.showingHistory)
    #expect(store.historyQuery.isEmpty)
    #expect(store.historyFocusToken == focusBeforeClear + 1)
    #expect(backend.commands.last == ["type": "listHistory"])

    // Search again and re-select the CURRENTLY ACTIVE conversation from a non-empty query ->
    // closes History, preserves its draft, sends scrollToMessageId, and updates session.scrollTargetMessageId!
    store.updateHistoryQuery("alfama")
    backend.emit(BridgeEvent(type: "history", history: [matchedActive], query: "alfama"))
    try await waitForCondition { store.historyEntries == [matchedActive] }
    let transcriptBeforeReselect = store.session.transcriptID
    store.openSelectedHistoryConversation()
    #expect(!store.showingHistory)
    #expect(store.historyQuery.isEmpty)
    #expect(store.draft == "Unsent draft for active chat")
    #expect(backend.commands.last == ["type": "openConversation", "conversationId": "conv-a", "scrollToMessageId": "a-m2"])
    backend.emit(BridgeEvent(
        type: "ready",
        conversationId: "conv-a",
        messages: activeMessages,
        models: models,
        model: "gpt-6-luna",
        scrollToMessageId: "a-m2"
    ))
    try await waitForCondition { store.session.transcriptID != transcriptBeforeReselect }
    #expect(store.session.scrollTargetMessageId == "a-m2")

    // Opening a conversation when the search bar is empty omits scrollToMessageId and scrolls to bottom.
    let emptyQueryEntry = HistoryEntry(id: "conv-b", title: "Other chat", updatedAt: "2026-04-01T10:00:00.000Z", preview: "Latest", model: "gpt-6-luna", messageCount: 1)
    store.openHistory()
    backend.emit(BridgeEvent(type: "history", history: [emptyQueryEntry], query: ""))
    try await waitForCondition { store.historyEntries == [emptyQueryEntry] }
    store.openSelectedHistoryConversation()
    #expect(backend.commands.last == ["type": "openConversation", "conversationId": "conv-b"])
    #expect(store.followBottom)
    backend.emit(BridgeEvent(
        type: "ready",
        conversationId: "conv-b",
        messages: [ChatMessage(id: "b-m1", role: "user", text: "Latest")],
        models: models,
        model: "gpt-6-luna"
    ))
    try await waitForCondition { store.session.conversationId == "conv-b" }
    #expect(store.session.scrollTargetMessageId == nil)

    store.stop()
}

@MainActor
private func waitForCondition(timeout: Duration = .seconds(2), _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !predicate(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(predicate())
}

private final class RecordingHistoryBackend: ChatBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (BridgeEvent) -> Void)?
    private var recorded = [[String: String]]()

    var commands: [[String: String]] { lock.withLock { recorded } }

    func start(codexOverride: String, options: ChatClientOptions, onEvent: @escaping @Sendable (BridgeEvent) -> Void) {
        lock.withLock { sink = onEvent }
    }

    func send(_ command: [String: String]) {
        lock.withLock { recorded.append(command) }
    }

    func close(completion: (@Sendable () -> Void)?) {
        lock.withLock { sink = nil }
        completion?()
    }

    func emit(_ event: BridgeEvent) {
        let sink = lock.withLock { self.sink }
        sink?(event)
    }
}

@MainActor
private final class MinimalWindowWorkspace: WindowWorkspace {
    private(set) var isPanelVisible = false
    var isPanelOnActiveSpace: Bool { isPanelVisible }
    private(set) var isPanelKey = false
    var panelFrame = CGRect(x: 100, y: 100, width: 790, height: 740)
    var displays: [DisplayBounds] = [DisplayBounds(id: "main", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 64, width: 1440, height: 811))]
    var activeDisplay: DisplayBounds? { displays.first }
    var now: TimeInterval = 1
    var onEvent: ((WindowWorkspaceEvent) -> Void)?

    func orderOutPanel() { isPanelVisible = false; isPanelKey = false }
    func setPanelFrame(_ frame: CGRect) { panelFrame = frame }
    func orderFrontAndMakePanelKey() { isPanelVisible = true; isPanelKey = true }
    func isSecondaryWindowVisible(_ window: SecondaryWindow) -> Bool { false }
    func isSecondaryWindowOnActiveSpace(_ window: SecondaryWindow) -> Bool { false }
    func orderOutSecondaryWindow(_ window: SecondaryWindow) {}
    func orderFrontAndMakeSecondaryWindowKey(_ window: SecondaryWindow) {}
    func activateApp() {}
    func focusComposer() {}
    func stopObserving() { onEvent = nil }
}
