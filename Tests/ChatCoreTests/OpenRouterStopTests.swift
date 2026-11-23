import Foundation
import Testing
@testable import ChatCore

@Test(arguments: [false, true])
func stopBeforeOpenRouterDispatchSettlesAndKeepsSubmission(attachedCodex: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("or-stop-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configURL = root.appendingPathComponent("openrouter.json")
    let stateURL = root.appendingPathComponent("state.json")
    try OpenRouterClient.saveConfig(key: "test-key", to: configURL)

    let options = ChatClientOptions(
        openRouterFetch: { _ in
            Issue.record("Stop already won before OpenRouter dispatch")
            return OpenRouterHTTPResponse(statusCode: 200, lines: AsyncThrowingStream { $0.finish() })
        },
        openRouterConfigURL: configURL, stateURL: stateURL, env: [:]
    )
    let rpc = FakeCodexTransport()
    rpc.failStart = !attachedCodex
    let client = ChatClient(rpc: rpc, options: options)
    let ready = try await client.connect()
    let model = try #require(ready.models.first { $0.isOpenRouter }?.model)
    _ = try await client.selectModel(model)

    let (preparing, signal) = AsyncStream<Void>.makeStream()
    let proceed = DispatchSemaphore(value: 0)
    client.onModel = { _ in
        signal.yield()
        if proceed.wait(timeout: .now() + .seconds(5)) == .timedOut {
            Issue.record("Stop did not return during provider startup")
        }
    }
    let submitted = ChatMessage(id: "first-submission", role: "user", text: "Keep this for later.")
    try await confirmation("the stopped turn settles once") { done in
        client.onDone = { done() }
        let sending = Task { try await client.send(submitted.text, userMessageId: submitted.id) }
        for await _ in preparing { break }
        await client.interrupt()
        await client.interrupt()
        proceed.signal()
        try await sending.value
        let remainsBusy = client.busy
        #expect(!remainsBusy)
        #expect(rpc.calls.filter { $0.method == "turn/interrupt" }.isEmpty)
    }
    await client.close()

    let reopenedRPC = FakeCodexTransport()
    reopenedRPC.failStart = !attachedCodex
    reopenedRPC.resumeResult = .success(CodexPayload(["thread": ["id": ready.threadId, "turns": []]]))
    let reopened = ChatClient(rpc: reopenedRPC, options: options)
    #expect(try await reopened.connect().messages == [submitted])
    await reopened.close()
}
