@testable import ChatCore
import Foundation
import Testing
@testable import SpeedChat

@MainActor
@Test func preferencesPersistsHistoryRetentionAndConfirmsShrinkAndClearAll() throws {
    let suiteName = "speedchat.retention.prefs.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("prefs-retention-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let configURL = root.appendingPathComponent("openrouter.json")

    let prefs = Preferences(defaults: defaults, configURL: configURL)
    #expect(prefs.historyRetention == .days30)

    var savedCount = 3
    var expiredByPolicy: [HistoryRetention: Int] = [
        .days7: 2,
        .days30: 0,
        .days90: 0,
        .year1: 0,
        .forever: 0,
    ]
    var appliedRetentions = [HistoryRetention]()
    var clearAllCount = 0

    prefs.countSavedHistory = { savedCount }
    prefs.countExpiredHistory = { expiredByPolicy[$0] ?? 0 }
    prefs.applyHistoryRetention = { policy in
        appliedRetentions.append(policy)
        savedCount -= expiredByPolicy[policy] ?? 0
        expiredByPolicy[policy] = 0
    }
    prefs.clearAllHistory = {
        clearAllCount += 1
        savedCount = 0
    }
    prefs.refreshHistoryCount()
    #expect(prefs.savedHistoryCount == 3)

    // 1. Shortening from 30d -> 7d with 2 expired conversations asks for confirmation with exact count.
    prefs.requestHistoryRetention(.days7)
    #expect(prefs.pendingHistoryConfirmation == .shortenRetention(target: .days7, previous: .days30, affectedCount: 2))
    #expect(appliedRetentions.isEmpty)
    #expect(defaults.string(forKey: "historyRetention") == nil)

    // Cancel reverts picker back to 30d and does not prune or persist.
    prefs.cancelHistoryConfirmation()
    #expect(prefs.pendingHistoryConfirmation == nil)
    #expect(prefs.historyRetention == .days30)
    #expect(appliedRetentions.isEmpty)
    #expect(savedCount == 3)

    // Re-attempt 30d -> 7d and confirm: persists, prunes, updates savedHistoryCount.
    prefs.requestHistoryRetention(.days7)
    #expect(prefs.pendingHistoryConfirmation == .shortenRetention(target: .days7, previous: .days30, affectedCount: 2))
    prefs.confirmHistoryConfirmation()
    #expect(prefs.pendingHistoryConfirmation == nil)
    #expect(prefs.historyRetention == .days7)
    #expect(defaults.string(forKey: "historyRetention") == "7d")
    #expect(appliedRetentions == [.days7])
    #expect(prefs.savedHistoryCount == 1)

    // Reloading Preferences from the same UserDefaults restores 7d.
    let reloaded = Preferences(defaults: defaults, configURL: configURL)
    #expect(reloaded.historyRetention == .days7)

    // 2. Lengthening (7d -> forever) applies immediately without confirmation.
    prefs.requestHistoryRetention(.forever)
    #expect(prefs.pendingHistoryConfirmation == nil)
    #expect(prefs.historyRetention == .forever)
    #expect(defaults.string(forKey: "historyRetention") == "forever")
    #expect(appliedRetentions == [.days7, .forever])

    // 3. Shortening when 0 conversations would be deleted applies immediately without confirmation.
    prefs.requestHistoryRetention(.days90)
    #expect(prefs.pendingHistoryConfirmation == nil)
    #expect(prefs.historyRetention == .days90)
    #expect(defaults.string(forKey: "historyRetention") == "90d")
    #expect(appliedRetentions == [.days7, .forever, .days90])

    // 4. Clear All prompts with exact remaining count (1), cancel does nothing, confirm clears all.
    prefs.requestClearAllHistory()
    #expect(prefs.pendingHistoryConfirmation == .clearAll(affectedCount: 1))
    #expect(clearAllCount == 0)

    prefs.cancelHistoryConfirmation()
    #expect(prefs.pendingHistoryConfirmation == nil)
    #expect(clearAllCount == 0)
    #expect(savedCount == 1)

    prefs.requestClearAllHistory()
    prefs.confirmHistoryConfirmation()
    #expect(prefs.pendingHistoryConfirmation == nil)
    #expect(clearAllCount == 1)
    #expect(prefs.savedHistoryCount == 0)

    // 5. Clear All when History is already empty does not prompt.
    prefs.requestClearAllHistory()
    #expect(prefs.pendingHistoryConfirmation == nil)
    #expect(clearAllCount == 1)

    // 6. While an active turn is busy, shortening with expired conversations or Clear All is blocked cleanly.
    savedCount = 2
    expiredByPolicy[.days7] = 1
    prefs.refreshHistoryCount()
    prefs.isChatBusy = { true }
    prefs.requestHistoryRetention(.days7)
    #expect(prefs.historyRetention == .days90)
    #expect(prefs.pendingHistoryConfirmation == nil)
    #expect(prefs.error.contains("Wait for the current response"))

    prefs.error = ""
    prefs.requestClearAllHistory()
    #expect(prefs.pendingHistoryConfirmation == nil)
    #expect(prefs.error.contains("Wait for the current response"))
}

@MainActor
@Test func chatStorePassesRetentionToBackendAndResetsPanelDraftAndHistoryWhenActiveRemoved() async throws {
    let backend = RecordingRetentionBackend()
    let store = ChatStore { backend }
    store.historyRetention = .days90

    store.connect()
    #expect(backend.startedOptions?.historyRetention == .days90)

    let models = [ChatModel(model: "gpt-6-luna", displayName: "GPT-6 Luna", provider: "openai")]
    let entryOld = HistoryEntry(id: "conv-old", title: "Old chat", updatedAt: "2026-04-01T10:00:00.000Z", preview: "Old reply", model: "gpt-6-luna", messageCount: 2)
    let entryFresh = HistoryEntry(id: "conv-fresh", title: "Fresh chat", updatedAt: "2026-05-01T10:00:00.000Z", preview: "Fresh reply", model: "gpt-6-luna", messageCount: 2)

    backend.emit(BridgeEvent(
        type: "ready",
        conversationId: "conv-fresh",
        messages: [ChatMessage(id: "f-u1", role: "user", text: "Fresh question")],
        models: models,
        model: "gpt-6-luna"
    ))
    try await waitUntil { store.session.conversationId == "conv-fresh" }
    store.draft = "Draft for fresh"
    store.openHistory()
    backend.emit(BridgeEvent(type: "history", history: [entryFresh, entryOld]))
    try await waitUntil { store.historyEntries.count == 2 }

    // 1. Pruning removes ONLY conv-old (active conv-fresh survives):
    // History view updates, active conversation and draft remain untouched.
    store.applyHistoryRetention(.days7)
    #expect(store.historyRetention == .days7)
    #expect(backend.commands.last == ["type": "applyRetention", "retention": "7d"])
    backend.emit(BridgeEvent(type: "history", history: [entryFresh], clearedActiveConversation: false))
    try await waitUntil { store.historyEntries.map(\.id) == ["conv-fresh"] }
    #expect(store.showingHistory)
    #expect(store.session.conversationId == "conv-fresh")
    #expect(store.draft == "Draft for fresh")

    // 2. Clear All removes active conv-fresh:
    // Panel resets to blank New Chat with clean Draft, and open History refreshes to empty.
    store.clearAllHistory()
    #expect(backend.commands.last == ["type": "clearHistory"])
    backend.emit(BridgeEvent(
        type: "ready",
        conversationId: nil,
        messages: [],
        models: models,
        model: "gpt-6-luna",
        notice: "New chat",
        clearedActiveConversation: true
    ))
    backend.emit(BridgeEvent(type: "history", history: [], clearedActiveConversation: true))
    try await waitUntil { store.session.conversationId == nil && store.historyEntries.isEmpty }
    #expect(store.session.messages.isEmpty)
    #expect(store.draft.isEmpty)
    #expect(store.showingHistory)

    // Closing History lands on the blank New Chat with empty Draft.
    store.closeHistory()
    #expect(!store.showingHistory)
    #expect(store.session.conversationId == nil)
    #expect(store.draft.isEmpty)

    store.stop()
}

@MainActor
@Test func applyRetentionAndClearHistoryRespectActiveHistorySearchQuery() async throws {
    let backend = RecordingRetentionBackend()
    let store = ChatStore { backend }
    store.connect()

    let models = [ChatModel(model: "gpt-6-luna", displayName: "GPT-6 Luna", provider: "openai")]
    backend.emit(BridgeEvent(
        type: "ready",
        conversationId: "conv-fresh",
        messages: [ChatMessage(id: "f-u1", role: "user", text: "Visit Alfama")],
        models: models,
        model: "gpt-6-luna"
    ))
    try await waitUntil { store.session.conversationId == "conv-fresh" }

    store.openHistory()
    store.updateHistoryQuery("alfama")
    let matchedOld = HistoryEntry(
        id: "conv-old",
        title: "Old Lisbon notes",
        updatedAt: "2026-04-01T10:00:00.000Z",
        preview: "Walk through Alfama.",
        model: "gpt-6-luna",
        messageCount: 1,
        previewMatchRanges: [HistoryMatchRange(start: 13, end: 19)],
        firstMatchingMessageId: "o-u1"
    )
    let matchedFresh = HistoryEntry(
        id: "conv-fresh",
        title: "Fresh Lisbon notes",
        updatedAt: "2026-05-14T10:00:00.000Z",
        preview: "Visit Alfama.",
        model: "gpt-6-luna",
        messageCount: 1,
        previewMatchRanges: [HistoryMatchRange(start: 6, end: 12)],
        firstMatchingMessageId: "f-u1"
    )
    backend.emit(BridgeEvent(type: "history", history: [matchedFresh, matchedOld], query: "alfama"))
    try await waitUntil { store.historyEntries.count == 2 }

    // Pruning while a search query is active forwards the active query and updates filtered results.
    store.applyHistoryRetention(.days7)
    #expect(backend.commands.last == ["type": "applyRetention", "retention": "7d", "query": "alfama"])
    backend.emit(BridgeEvent(type: "history", history: [matchedFresh], clearedActiveConversation: false, query: "alfama"))
    try await waitUntil { store.historyEntries == [matchedFresh] }
    #expect(store.historyQuery == "alfama")

    // Clear All empties History even while a non-empty search query is active.
    store.clearAllHistory()
    #expect(backend.commands.last == ["type": "clearHistory"])
    backend.emit(BridgeEvent(type: "history", history: [], clearedActiveConversation: true))
    try await waitUntil { store.historyEntries.isEmpty }

    store.stop()
}

@Test func bridgeProcessPrunesOnLaunchAndHandlesApplyRetentionAndClearHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-retention-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let stateURL = root.appendingPathComponent("state.json")
    let now = try #require(StateStore.parseTimestamp("2026-05-15T10:00:00.000Z"))
    let expiredConv = SavedConversation(
        id: "conv-expired",
        title: "Forty days ago",
        createdAt: "2026-04-01T10:00:00.000Z",
        updatedAt: "2026-04-01T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-expired",
        messages: [ChatMessage(id: "u0", role: "user", text: "Ancient question")]
    )
    let midConv = SavedConversation(
        id: "conv-mid",
        title: "Fifteen days ago",
        createdAt: "2026-04-30T10:00:00.000Z",
        updatedAt: "2026-04-30T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-mid",
        messages: [ChatMessage(id: "u1", role: "user", text: "Mid-age question")]
    )
    let freshConv = SavedConversation(
        id: "conv-fresh",
        title: "Yesterday",
        createdAt: "2026-05-14T10:00:00.000Z",
        updatedAt: "2026-05-14T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-fresh",
        messages: [ChatMessage(id: "u2", role: "user", text: "Fresh question")]
    )
    try StateStore.saveActiveConversation(expiredConv, to: stateURL)
    try StateStore.saveActiveConversation(freshConv, to: stateURL)
    try StateStore.saveActiveConversation(midConv, to: stateURL)

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
        elif method == "thread/start":
            print(json.dumps({"id": mid, "result": {"thread": {"id": "codex-started"}, "model": "gpt-6-luna"}}), flush=True)
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
        env: [:],
        now: { now },
        historyRetention: .days30
    )) { sink.yield($0) }

    var iter = events.makeAsyncIterator()
    // Startup with 30d retention automatically prunes conv-expired while resuming active conv-mid.
    let initial = try #require(await iter.next())
    #expect(initial.type == "ready")
    #expect(initial.conversationId == "conv-mid")

    bridge.send(["type": "listHistory"])
    let afterLaunch = try #require(await iter.next())
    #expect(afterLaunch.type == "history")
    #expect(afterLaunch.history?.map(\.id) == ["conv-fresh", "conv-mid"])

    // Clear RPC log, then apply 7d retention: active conv-mid (15d old) expires -> emits ready reset + updated history, ZERO Codex RPCs.
    try "".write(to: rpcLog, atomically: true, encoding: .utf8)
    bridge.send(["type": "applyRetention", "retention": "7d"])
    let resetEvent = try #require(await iter.next())
    #expect(resetEvent.type == "ready")
    #expect(resetEvent.conversationId == nil)
    #expect(resetEvent.messages == [])
    #expect(resetEvent.clearedActiveConversation == true)

    let historyAfterShrink = try #require(await iter.next())
    #expect(historyAfterShrink.type == "history")
    #expect(historyAfterShrink.history?.map(\.id) == ["conv-fresh"])

    // Open conv-fresh, then clearHistory: resets active + empties History, still ZERO Codex RPCs.
    bridge.send(["type": "openConversation", "conversationId": "conv-fresh"])
    let openedFresh = try #require(await iter.next())
    #expect(openedFresh.conversationId == "conv-fresh")

    bridge.send(["type": "clearHistory"])
    let clearedReset = try #require(await iter.next())
    #expect(clearedReset.type == "ready")
    #expect(clearedReset.conversationId == nil)
    #expect(clearedReset.messages == [])
    #expect(clearedReset.clearedActiveConversation == true)

    let historyAfterClear = try #require(await iter.next())
    #expect(historyAfterClear.type == "history")
    #expect(historyAfterClear.history == [])

    let rpcsDuringRetentionAndClear = try String(contentsOf: rpcLog, encoding: .utf8)
    #expect(rpcsDuringRetentionAndClear.isEmpty)

    await withCheckedContinuation { cont in
        bridge.close { cont.resume() }
    }
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(2), _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !predicate(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(predicate())
}

private final class RecordingRetentionBackend: ChatBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (BridgeEvent) -> Void)?
    private var recorded = [[String: String]]()
    private var capturedOptions: ChatClientOptions?

    var commands: [[String: String]] { lock.withLock { recorded } }
    var startedOptions: ChatClientOptions? { lock.withLock { capturedOptions } }

    func start(codexOverride: String, options: ChatClientOptions, onEvent: @escaping @Sendable (BridgeEvent) -> Void) {
        lock.withLock {
            capturedOptions = options
            sink = onEvent
        }
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
