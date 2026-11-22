import Foundation
import Testing
@testable import ChatCore

@Test func closeBeforeOpenRouterDispatchSavesTheSubmissionAndCodexDelivery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("or-close-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configURL = root.appendingPathComponent("openrouter.json")
    let stateURL = root.appendingPathComponent("state.json")
    let model = OpenRouterClient.defaultModels[0].model
    try OpenRouterClient.saveConfig(key: "test-key", to: configURL)
    let earlier = ChatMessage(id: "earlier", role: "user", text: "Earlier prompt")
    let delivery = CodexSendAttempt(
        threadId: "old-thread", clientId: "earlier", userMessageId: earlier.id,
        wireText: earlier.text, turnId: "old-turn", delivery: .confirmed
    )
    try StateStore.save(
        threadId: delivery.threadId, model: model, to: stateURL, messages: [earlier], codexSyncedCount: 1,
        lastCodexSend: delivery, env: [:]
    )
    let options = ChatClientOptions(
        openRouterFetch: { _ in
            Issue.record("The outgoing execution reached OpenRouter after handoff")
            return OpenRouterHTTPResponse(statusCode: 200, lines: AsyncThrowingStream { $0.finish() })
        },
        openRouterConfigURL: configURL, stateURL: stateURL, env: [:]
    )
    let unavailable = FakeCodexTransport()
    unavailable.failStart = true
    let outgoing = ChatClient(rpc: unavailable, options: options)
    _ = try await outgoing.connect()
    let queued = ChatMessage(id: "queued", role: "user", text: "The submitted prompt")
    let executionID = UUID()
    try outgoing.acceptSend(queued.text, userMessageId: queued.id, executionID: executionID)
    await outgoing.close()

    let replacementRPC = FakeCodexTransport()
    replacementRPC.failStart = true
    let replacement = ChatClient(rpc: replacementRPC, options: options)
    #expect(try await replacement.connect().messages == [earlier, queued])
    let saved = try #require(StateStore.load(from: stateURL))
    #expect(saved.codexSyncedCount == 1)
    #expect(saved.lastCodexSend == delivery)

    _ = try await replacement.newChat()
    let newerState = try Data(contentsOf: stateURL)
    try await outgoing.startSend(executionID: executionID)
    #expect(try Data(contentsOf: stateURL) == newerState)
    await replacement.close()
}

@Test func delayedCodexModelSelectionCannotReplaceTheNewerSavedConversation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-close-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configURL = root.appendingPathComponent("openrouter.json")
    let stateURL = root.appendingPathComponent("state.json")
    let options = ChatClientOptions(openRouterConfigURL: configURL, stateURL: stateURL, env: [:])
    let (requests, requestSink) = AsyncStream<Void>.makeStream()
    let timeout = Task {
        try? await Task.sleep(for: .seconds(5))
        requestSink.finish()
    }
    defer { timeout.cancel() }
    let gate = HeldModelUpdate()
    let rpc = HeldModelUpdateTransport(gate: gate, onRequest: { requestSink.yield() })
    let outgoing = ChatClient(rpc: rpc, options: options)
    let ready = try await outgoing.connect()
    let update = Task { try await outgoing.selectModel(ready.model) }
    var pending = requests.makeAsyncIterator()
    let wasDispatched = await pending.next() != nil
    try #require(wasDispatched)

    await outgoing.close()
    let replacement = ChatClient(rpc: FakeCodexTransport(), options: options)
    _ = try await replacement.connect()
    _ = try await replacement.newChat()
    let fresh = try await replacement.newChat()
    #expect(fresh.threadId != ready.threadId)
    let newerState = try Data(contentsOf: stateURL)
    await gate.release()
    _ = await update.result
    #expect(try Data(contentsOf: stateURL) == newerState)
    await replacement.close()
}

private actor HeldModelUpdate {
    private var pending: CheckedContinuation<Void, Never>?

    func wait(onRequest: @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            pending = continuation
            onRequest()
        }
    }

    func release() {
        pending?.resume()
        pending = nil
    }
}

private final class HeldModelUpdateTransport: CodexTransport, @unchecked Sendable {
    private let fake = FakeCodexTransport()
    private let gate: HeldModelUpdate
    private let onRequest: @Sendable () -> Void

    var onNotification: (@Sendable (CodexNotification) -> Void)?
    var onExit: (@Sendable () -> Void)?

    init(gate: HeldModelUpdate, onRequest: @escaping @Sendable () -> Void) {
        self.gate = gate
        self.onRequest = onRequest
    }

    func start(cwd: URL?) async throws { try await fake.start(cwd: cwd) }
    func stop() async { await fake.stop() }

    func request(method: String, params: [String: Any], timeoutMs: Int) async throws -> [String: Any] {
        if method == "thread/settings/update" { await gate.wait(onRequest: onRequest) }
        return try await fake.request(method: method, params: params, timeoutMs: timeoutMs)
    }
}
