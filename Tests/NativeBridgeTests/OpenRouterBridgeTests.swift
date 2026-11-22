import ChatCore
import Foundation
import Testing
@testable import SpeedChat

@MainActor
@Test(arguments: [false, true], [false, true])
func nativeBridgeStopsOpenRouterAndKeepsThePanelUsable(saveFails: Bool, blankReply: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-or-stop-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configURL = root.appendingPathComponent("openrouter.json")
    let stateURL = root.appendingPathComponent("state.json")
    let model = OpenRouterClient.defaultModels[0].model
    try OpenRouterClient.saveConfig(key: "test-key", to: configURL)
    try StateStore.save(threadId: "openrouter-stop-test", model: model, to: stateURL, messages: [])

    let (firstReply, firstSink) = AsyncThrowingStream<String, Error>.makeStream()
    let (nextReply, nextSink) = AsyncThrowingStream<String, Error>.makeStream()
    let (cancellations, cancellationSink) = AsyncStream<Void>.makeStream()
    firstSink.onTermination = { termination in
        if case .cancelled = termination { cancellationSink.yield() }
        cancellationSink.finish()
    }
    let acceptedText = blankReply ? " " : "Keep this. [queued"
    let displayedText = blankReply ? " " : "Keep this. "
    let stoppedTexts = blankReply ? ["First prompt"] : ["First prompt", acceptedText]
    let options = ChatClientOptions(
        openRouterFetch: { request in
            let body = try #require(request.httpBody)
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try #require(payload["messages"] as? [[String: String]])
            if messages.last?["content"] == "Follow up" {
                let conversation = messages.filter { $0["role"] != "system" }
                #expect(conversation.compactMap { $0["content"] } == stoppedTexts + ["Follow up"])
                return OpenRouterHTTPResponse(statusCode: 200, lines: nextReply)
            }
            #expect(messages.last?["content"] == "First prompt")
            return OpenRouterHTTPResponse(statusCode: 200, lines: firstReply)
        },
        openRouterConfigURL: configURL, stateURL: stateURL, env: [:]
    )
    // A missing explicit override prevents a real Codex launch.
    let codexPath = root.appendingPathComponent("missing-codex").path
    let bridge = BridgeProcess()
    let events = OpenRouterBridgeEvents()
    let timeout = Task {
        try? await Task.sleep(for: .seconds(5))
        cancellationSink.finish()
    }
    defer { timeout.cancel() }
    bridge.start(codexOverride: codexPath, options: options, onEvent: events.append)

    let store = ChatStore()
    store.fixtureMode = true
    _ = try await receive("ready", from: events, in: store)
    store.draft = "First prompt"
    store.send()
    let firstSend = try #require(store.fixtureCommands.last)
    let firstID = try #require(firstSend["executionID"])
    bridge.send(firstSend)
    firstSink.yield(#"data: {"choices":[{"delta":{"content":"\#(acceptedText)"}}]}"#)
    _ = try await receive("delta", from: events, in: store)
    #expect(store.session.messages.map(\.text) == ["First prompt", displayedText])

    if saveFails {
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)
    }
    store.interrupt()
    let firstStop = try #require(store.fixtureCommands.last)
    #expect(firstStop["executionID"] == firstID)
    bridge.send(firstStop)
    bridge.send(firstStop)
    let stopped = try await receive("done", from: events, in: store)
    let stoppedMessages = store.session.messages
    #expect(stoppedMessages.map(\.text) == stoppedTexts)
    #expect(store.session.canSend)
    #expect(!store.session.canRetryOpenRouter)
    var cancelled = cancellations.makeAsyncIterator()
    let didCancel = await cancelled.next() != nil
    #expect(didCancel)

    if saveFails {
        #expect(stopped.stateSaveError?.contains("missing after reopening") == true)
        #expect(store.session.notice == stopped.stateSaveError)
        try FileManager.default.removeItem(at: stateURL)
    } else {
        #expect(stopped.stateSaveError == nil)
        let reopened = BridgeProcess()
        let (reopenedEvents, reopenedSink) = AsyncStream<BridgeEvent>.makeStream()
        let reopenTimeout = Task {
            try? await Task.sleep(for: .seconds(5))
            reopenedSink.finish()
        }
        defer { reopenTimeout.cancel() }
        reopened.start(codexOverride: codexPath, options: options) { reopenedSink.yield($0) }
        var restored = reopenedEvents.makeAsyncIterator()
        let ready = await restored.next()
        await withCheckedContinuation { continuation in reopened.close { continuation.resume() } }
        #expect(ready?.type == "ready")
        #expect(ready?.messages == stoppedMessages)
    }

    store.draft = "Follow up"
    store.send()
    let nextSend = try #require(store.fixtureCommands.last)
    #expect(nextSend["executionID"] != firstID)
    bridge.send(nextSend)
    bridge.send(firstStop)
    bridge.send(["type": "reloadConfig"])
    _ = try await receive("modelsUpdated", from: events, in: store)
    let stoppedID = try #require(UUID(uuidString: firstID))
    store.session.receive(BridgeEvent(type: "delta", itemId: "stale", delta: "Late text.", executionID: stoppedID))
    store.session.receive(BridgeEvent(type: "searching", executionID: stoppedID))
    store.session.receive(BridgeEvent(type: "error", message: "Late error.", executionID: stoppedID))
    store.session.receive(BridgeEvent(type: "done", executionID: stoppedID))
    #expect(store.session.streaming)
    #expect(store.session.notice == "Thinking…")
    firstSink.yield(#"data: {"choices":[{"delta":{"content":"Late text."}}]}"#)
    firstSink.finish(throwing: URLError(.networkConnectionLost))
    store.bridge = bridge
    store.hide()
    nextSink.yield(#"data: {"choices":[{"delta":{"content":"Complete reply."}}]}"#)
    nextSink.yield("data: [DONE]")
    nextSink.finish()
    let completed = try await receive("done", from: events, in: store)
    #expect(completed.executionID?.uuidString == nextSend["executionID"])
    #expect(store.session.messages.map(\.text) == stoppedTexts + ["Follow up", "Complete reply."])
    #expect(store.session.canSend)
    store.show()
    #expect(store.warmReopens == 1)
    // A late Stop after completion cannot replace the complete reply.
    bridge.send(["type": "interrupt", "executionID": try #require(nextSend["executionID"])])
    await withCheckedContinuation { continuation in bridge.close { continuation.resume() } }
    #expect(StateStore.load(from: stateURL)?.messages == store.session.messages)
}

private final class OpenRouterBridgeEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events = [BridgeEvent]()

    func append(_ event: BridgeEvent) { lock.withLock { events.append(event) } }
    func pop() -> BridgeEvent? { lock.withLock { events.isEmpty ? nil : events.removeFirst() } }
}

@MainActor
private func receive(
    _ type: String,
    from events: OpenRouterBridgeEvents,
    in store: ChatStore
) async throws -> BridgeEvent {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        guard let event = events.pop() else {
            try await Task.sleep(for: .milliseconds(5))
            continue
        }
        store.session.receive(event)
        if event.type == type { return event }
        if event.type == "fatal" || event.type == "error" {
            throw NSError(domain: "NativeBridgeTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: event.message ?? "Unexpected bridge error",
            ])
        }
    }
    throw NSError(domain: "NativeBridgeTests", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Timed out waiting for \(type)",
    ])
}

@MainActor
@Test func reconnectSavesTheAcceptedOpenRouterReplyBeforeRestoring() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-or-reconnect-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configURL = root.appendingPathComponent("openrouter.json")
    let stateURL = root.appendingPathComponent("state.json")
    let model = OpenRouterClient.defaultModels[0].model
    try OpenRouterClient.saveConfig(key: "test-key", to: configURL)
    try StateStore.save(
        threadId: "codex-history", model: model, to: stateURL,
        messages: [ChatMessage(id: "earlier", role: "user", text: "Earlier prompt")], codexSyncedCount: 1
    )

    let (firstPass, firstSink) = AsyncThrowingStream<String, Error>.makeStream()
    let (searchStarted, searchSink) = AsyncStream<Void>.makeStream()
    let (searchReturned, returnedSink) = AsyncStream<Void>.makeStream()
    let lateFetch = HeldOpenRouterFetch()
    defer { Task { await lateFetch.release() } }
    let options = ChatClientOptions(
        openRouterFetch: { request in
            let body = try #require(request.httpBody)
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try #require(payload["messages"] as? [[String: String]])
            if messages.last?["content"] == "Follow up" {
                #expect(messages.filter { $0["role"] != "system" }.compactMap { $0["content"] } ==
                    ["Earlier prompt", "First prompt", "Keep this. [queued", "Follow up"])
                return OpenRouterHTTPResponse(statusCode: 200, lines: AsyncThrowingStream { sink in
                    sink.yield(#"data: {"choices":[{"delta":{"content":"New reply."}}]}"#)
                    sink.finish()
                })
            }
            if payload["plugins"] != nil {
                let late = await lateFetch.response(onEntry: { searchSink.yield() })
                returnedSink.yield()
                return late
            }
            return OpenRouterHTTPResponse(statusCode: 200, lines: firstPass)
        },
        openRouterConfigURL: configURL, stateURL: stateURL, env: [:]
    )
    let codexPath = root.appendingPathComponent("missing-codex").path
    let bridge = BridgeProcess()
    let events = OpenRouterBridgeEvents()
    bridge.start(codexOverride: codexPath, options: options, onEvent: events.append)
    let panel = ChatStore()
    panel.fixtureMode = true
    _ = try await receive("ready", from: events, in: panel)
    panel.draft = "First prompt"
    panel.send()
    bridge.send(try #require(panel.fixtureCommands.last))
    firstSink.yield(#"data: {"choices":[{"delta":{"content":"Keep this. [queued"}}]}"#)
    _ = try await receive("delta", from: events, in: panel)
    #expect(panel.session.messages.map(\.text) == ["Earlier prompt", "First prompt", "Keep this. "])
    firstSink.yield(#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"search","function":{"name":"web_search","arguments":"{}"}}]}}]}"#)
    firstSink.finish()
    let searchTimeout = Task {
        try? await Task.sleep(for: .seconds(5))
        searchSink.finish()
        returnedSink.finish()
    }
    defer { searchTimeout.cancel() }
    var search = searchStarted.makeAsyncIterator()
    let searchWasDispatched = await search.next() != nil
    try #require(searchWasDispatched)

    await withCheckedContinuation { continuation in bridge.close { continuation.resume() } }
    let replacement = BridgeProcess()
    let replacementEvents = OpenRouterBridgeEvents()
    replacement.start(codexOverride: codexPath, options: options, onEvent: replacementEvents.append)
    let settled = try await receive("ready", from: replacementEvents, in: panel)
    #expect(settled.messages?.map(\.text) == ["Earlier prompt", "First prompt", "Keep this. [queued"])

    panel.draft = "Follow up"
    panel.send()
    replacement.send(try #require(panel.fixtureCommands.last))
    _ = try await receive("done", from: replacementEvents, in: panel)
    #expect(panel.session.messages.map(\.text) == ["Earlier prompt", "First prompt", "Keep this. [queued", "Follow up", "New reply."])
    #expect(StateStore.load(from: stateURL)?.codexSyncedCount == 1)
    let newerState = try Data(contentsOf: stateURL)
    await lateFetch.release()
    var oldResponse = searchReturned.makeAsyncIterator()
    let oldResponseReturned = await oldResponse.next() != nil
    #expect(oldResponseReturned)
    await withCheckedContinuation { continuation in replacement.close { continuation.resume() } }
    #expect(try Data(contentsOf: stateURL) == newerState)
    #expect(events.pop()?.type == "searching")
    #expect(events.pop() == nil)
}

private actor HeldOpenRouterFetch {
    private var pending: CheckedContinuation<OpenRouterHTTPResponse, Never>?

    func response(onEntry: @Sendable () -> Void) async -> OpenRouterHTTPResponse {
        await withCheckedContinuation { continuation in
            pending = continuation
            onEntry()
        }
    }

    func release() {
        pending?.resume(returning: OpenRouterHTTPResponse(statusCode: 200, lines: AsyncThrowingStream { sink in
            sink.yield(#"data: {"choices":[{"delta":{"content":"Late reply."}}]}"#)
            sink.finish()
        }))
        pending = nil
    }
}
