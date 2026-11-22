import Testing
import Foundation
@testable import ChatCore

final class FakeCodexTransport: CodexTransport, @unchecked Sendable {
    private let lock = NSLock()
    var onNotification: (@Sendable (CodexNotification) -> Void)?
    var onExit: (@Sendable () -> Void)?
    var calls = [(method: String, params: [String: Any])]()
    var failStart = false
    var failThreadStart = false
    var missingThreadId = false
    var threadStartModel = "gpt-6-luna"
    var resumeResult: Result<CodexPayload, Error> = .success(CodexPayload())
    var holdTurnStart = false
    var holdSettings = false
    var holdFirstRename = false
    private var turnStartContinuation: CheckedContinuation<CodexPayload, Error>?
    private var settingsContinuation: CheckedContinuation<CodexPayload, Error>?
    private var renameContinuation: CheckedContinuation<CodexPayload, Error>?
    private var threadCounter = 0

    private func sync<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func start(cwd: URL?) async throws {
        if failStart {
            throw NSError(domain: "test", code: 401, userInfo: [NSLocalizedDescriptionKey: "unauthorized"])
        }
    }

    func stop() async {}

    func releaseTurnStart(turnId: String = "t") {
        let cont = sync { () -> CheckedContinuation<CodexPayload, Error>? in
            let c = turnStartContinuation
            turnStartContinuation = nil
            holdTurnStart = false
            return c
        }
        cont?.resume(returning: CodexPayload(["turn": ["id": turnId]]))
    }

    func releaseSettings() {
        let cont = sync { () -> CheckedContinuation<CodexPayload, Error>? in
            let c = settingsContinuation
            settingsContinuation = nil
            holdSettings = false
            return c
        }
        cont?.resume(returning: CodexPayload([:]))
    }

    func releaseRename() {
        let cont = sync { () -> CheckedContinuation<CodexPayload, Error>? in
            let c = renameContinuation
            renameContinuation = nil
            holdFirstRename = false
            return c
        }
        cont?.resume(returning: CodexPayload([:]))
    }

    func request(method: String, params: [String: Any], timeoutMs: Int) async throws -> [String: Any] {
        let (shouldHoldTurn, shouldHoldSettings, shouldHoldRename) = sync { () -> (Bool, Bool, Bool) in
            calls.append((method: method, params: params))
            let holdT = (method == "turn/start" && holdTurnStart)
            let holdS = (method == "thread/settings/update" && holdSettings)
            let nameParam = (params["name"] as? String) ?? ""
            let holdR = (method == "thread/name/set" && nameParam != "New chat" && holdFirstRename)
            if holdR { holdFirstRename = false }
            return (holdT, holdS, holdR)
        }

        if shouldHoldSettings {
            let p: CodexPayload = try await withCheckedThrowingContinuation { cont in
                sync { settingsContinuation = cont }
            }
            return p.value
        }
        if shouldHoldRename {
            let p: CodexPayload = try await withCheckedThrowingContinuation { cont in
                sync { renameContinuation = cont }
            }
            return p.value
        }
        if shouldHoldTurn {
            let p: CodexPayload = try await withCheckedThrowingContinuation { cont in
                sync { turnStartContinuation = cont }
            }
            return p.value
        }

        if method == "model/list" {
            return [
                "data": [
                    [
                        "id": "gpt-6-luna",
                        "model": "gpt-6-luna",
                        "displayName": "GPT-6 Luna",
                        "hidden": false,
                        "supportedReasoningEfforts": [["reasoningEffort": "low"]],
                    ],
                ],
            ]
        }
        if method == "thread/resume" {
            return try resumeResult.get().value
        }
        if method == "thread/start" {
            if failThreadStart { throw NSError(domain: "test", code: 500) }
            if missingThreadId { return ["thread": [:]] }
            let count = sync { () -> Int in
                let c = threadCounter
                threadCounter += 1
                return c
            }
            let id = count == 0 ? "dedicated" : "thread-\(count)"
            return ["thread": ["id": id], "model": threadStartModel]
        }
        if method == "turn/start" {
            if (params["threadId"] as? String)?.hasPrefix("openrouter-") == true {
                throw NSError(domain: "test", code: -32600, userInfo: [NSLocalizedDescriptionKey: "invalid thread id: expected UUID"])
            }
            return ["turn": ["id": "turn-1"]]
        }
        return [:]
    }
}

@Test(arguments: ["rejected", "timed out", "malformed", "wrong thread"])
func savedConversationReopensWhenCodexResumeFails(failure: String) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-reopen-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let options = ChatClientOptions(openRouterConfigURL: dir.appendingPathComponent("openrouter.json"), stateURL: stateURL, env: [:])
    let messages = [
        ChatMessage(id: "saved-user", role: "user", text: "Keep my original prompt."),
        ChatMessage(id: "saved-reply", role: "assistant", text: "Your prompt is saved."),
    ]
    try StateStore.save(threadId: "original-thread", model: "gpt-6-luna", to: stateURL, messages: messages, codexSyncedCount: 2)

    for _ in 0..<2 {
        let rpc = FakeCodexTransport()
        switch failure {
        case "rejected":
            rpc.resumeResult = .failure(NSError(domain: "SpeedChat.Codex", code: -32600))
        case "timed out":
            rpc.resumeResult = .failure(NSError(domain: "SpeedChat.Codex", code: -2))
        case "wrong thread":
            rpc.resumeResult = .success(CodexPayload(["thread": ["id": "unrelated-thread", "turns": []]]))
        default:
            rpc.resumeResult = .success(CodexPayload(["thread": [:]]))
        }
        let client = ChatClient(rpc: rpc, options: options)
        let ready = try await client.connect()
        #expect(ready.resumed)
        #expect(ready.threadId == "original-thread")
        #expect(ready.messages == messages)
        #expect(rpc.calls.first { $0.method == "thread/resume" }?.params["threadId"] as? String == "original-thread")
        #expect(!rpc.calls.contains { $0.method == "thread/start" || $0.method == "turn/start" })
        await client.close()
    }
}

@Test(arguments: [false, true])
func savedConversationTakesPriorityOverLongerCodexHistory(emptySavedConversation: Bool) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-conflict-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let messages: [ChatMessage] = emptySavedConversation ? [] : [
        ChatMessage(id: "saved-user", role: "user", text: "Remember orchard."),
        ChatMessage(id: "saved-router", role: "assistant", text: "Orchard remembered."),
        ChatMessage(id: "saved-follow-up", role: "user", text: "Continue."),
    ]
    try StateStore.save(threadId: "mixed-thread", model: "gpt-6-luna", to: stateURL, messages: messages, codexSyncedCount: messages.count)

    let rpc = FakeCodexTransport()
    let turns: [[String: Any]] = [
        ["id": "handoff", "items": [
            ["id": "quoted", "type": "userMessage", "content": [
                ["type": "text", "text": "[Earlier turns in this conversation from another model:\nUser: Remember orchard.\n\nAssistant: Orchard remembered.]\n\nContinue."],
            ]],
            ["id": "codex-reply", "type": "agentMessage", "text": "Continuing."],
        ]],
        ["id": "unmatched", "items": [
            ["id": "different-user", "type": "userMessage", "content": [["type": "text", "text": "Continue."]]],
            ["id": "different-reply", "type": "agentMessage", "text": "New Codex history."],
        ]],
    ]
    rpc.resumeResult = .success(CodexPayload(["thread": ["id": "mixed-thread", "turns": turns]]))
    let client = ChatClient(rpc: rpc, options: ChatClientOptions(
        openRouterConfigURL: dir.appendingPathComponent("openrouter.json"), stateURL: stateURL, env: [:]))
    let ready = try await client.connect()

    #expect(ready.resumed)
    #expect(ready.messages == messages)
    #expect(!rpc.calls.contains { $0.method == "turn/start" || $0.method == "thread/name/set" })
    await client.close()
}

@Test func legacyConversationRecoversFromCodexAndReopensFromSavedMessages() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-legacy-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let options = ChatClientOptions(openRouterConfigURL: dir.appendingPathComponent("openrouter.json"), stateURL: stateURL, env: [:])
    try StateStore.save(threadId: "legacy-thread", model: "gpt-6-luna", to: stateURL)
    let partial = FakeCodexTransport()
    partial.resumeResult = .success(CodexPayload(["thread": [
        "id": "legacy-thread", "turns": [["id": "legacy-turn", "itemsView": "summary", "items": []]],
    ]]))
    let partialClient = ChatClient(rpc: partial, options: options)
    let incomplete = try await partialClient.connect()
    #expect(incomplete.messages.isEmpty)
    await partialClient.close()

    let rpc = FakeCodexTransport()
    let turns: [[String: Any]] = [
        ["id": "legacy-turn", "items": [
            ["id": "legacy-user", "type": "userMessage", "content": [["type": "text", "text": "Hello again."]]],
            ["id": "legacy-reply", "type": "agentMessage", "text": "Welcome back."],
        ]],
        ["id": "legacy-handoff", "items": [
            ["id": "quoted-user", "type": "userMessage", "content": [
                ["type": "text", "text": "[Earlier turns in this conversation from another model:\nUser: Hello again.\n\nAssistant: Welcome back.]\n\nTell me more."],
            ]],
            ["id": "quoted-reply", "type": "agentMessage", "text": "Here are some more details."],
        ]],
    ]
    rpc.resumeResult = .success(CodexPayload(["thread": ["id": "legacy-thread", "turns": turns]]))
    let messages = [
        ChatMessage(id: "legacy-user", role: "user", text: "Hello again."),
        ChatMessage(id: "legacy-reply", role: "assistant", text: "Welcome back."),
        ChatMessage(id: "quoted-reply", role: "assistant", text: "Here are some more details."),
    ]

    let client = ChatClient(rpc: rpc, options: options)
    let ready = try await client.connect()
    #expect(ready.messages == messages)
    await client.close()

    let unavailable = FakeCodexTransport()
    unavailable.resumeResult = .failure(NSError(domain: "SpeedChat.Codex", code: -2))
    let reopened = ChatClient(rpc: unavailable, options: options)
    let restored = try await reopened.connect()
    #expect(restored.threadId == "legacy-thread")
    #expect(restored.messages == messages)
    await reopened.close()
}

@Test(arguments: [false, true])
func reopeningRecoversAMissingCodexReplyAfterItsVerifiedPrompt(quotedContext: Bool) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-reconcile-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let options = ChatClientOptions(openRouterConfigURL: dir.appendingPathComponent("openrouter.json"), stateURL: stateURL, env: [:])
    let prompt = ChatMessage(id: "saved-codex-prompt", role: "user", text: "What is the forecast?")
    let routerPrompt = ChatMessage(id: "saved-router-prompt", role: "user", text: "What is the forecast?")
    let routerReply = ChatMessage(id: "saved-router-reply", role: "assistant", text: "Windy.", reasoning: "For Beam follow-ups.")
    let earlierMessages: [ChatMessage] = quotedContext
        ? [ChatMessage(id: "earlier", role: "user", text: "I live in Fresno.")]
        : []
    let input = quotedContext
        ? "[Earlier turns in this conversation from another model:\nUser: I live in Fresno.]\n\nWhat is the forecast?"
        : "What is the forecast?"
    try StateStore.save(threadId: "forecast-thread", model: "gpt-6-luna", to: stateURL, messages: earlierMessages + [prompt, routerPrompt, routerReply], codexSyncedCount: earlierMessages.count + 1)

    let turns: [[String: Any]] = [
        ["id": "forecast-turn", "items": [
            ["id": "codex-prompt", "clientId": prompt.id, "type": "userMessage", "content": [["type": "text", "text": input]]],
            ["id": "private-reasoning", "type": "reasoning", "content": ["Private Codex reasoning."]],
            ["id": "commentary", "type": "agentMessage", "phase": "commentary", "text": "Checking the forecast."],
            ["id": "search", "type": "webSearch", "results": [["ref_id": "turn0search0", "url": "https://example.com/forecast", "title": "Forecast"]]],
            ["id": "codex-reply", "type": "agentMessage", "phase": "final_answer", "text": "Sunny. \u{E200}cite\u{E202}turn0search0\u{E201}"],
        ]],
    ]
    let expected = earlierMessages + [prompt, ChatMessage(id: "codex-reply", role: "assistant", text: "Sunny. [Forecast](https://example.com/forecast)"), routerPrompt, routerReply]
    for (reopen, resumeSucceeds) in [true, false, true].enumerated() {
        let rpc = FakeCodexTransport()
        rpc.resumeResult = resumeSucceeds
            ? .success(CodexPayload(["thread": ["id": "forecast-thread", "turns": turns]]))
            : .failure(NSError(domain: "SpeedChat.Codex", code: -2))
        let client = ChatClient(rpc: rpc, options: options)
        let ready = try await client.connect()
        #expect(ready.messages == expected)
        if reopen == 2 {
            try await client.send("Is that tomorrow?")
            let turn = try #require(rpc.calls.last { $0.method == "turn/start" })
            let input = turn.params["input"] as? [[String: String]]
            #expect(input?.first?["text"] == "[Earlier turns in this conversation from another model:\nUser: What is the forecast?\n\nAssistant: Windy.]\n\nIs that tomorrow?")
        }
        await client.close()
    }
}

@Test(arguments: ["full", "summary"])
func reopeningUsesASavedCodexReplyToPlaceAMissingReplyInTheSameExchange(itemsView: String) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-assistant-anchor-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let options = ChatClientOptions(openRouterConfigURL: dir.appendingPathComponent("openrouter.json"), stateURL: stateURL, env: [:])
    let original = ChatMessage(id: "saved-prompt", role: "user", text: "Where should I hike?")
    let savedReply = ChatMessage(id: "saved-codex-reply", role: "assistant", text: "The trail is closed in winter.")
    let routerReply = ChatMessage(id: "router-reply", role: "assistant", text: "Consider an alternative trail.")
    let saved = [original, savedReply, routerReply]
    try StateStore.save(threadId: "trail-thread", model: "gpt-6-luna", to: stateURL, messages: saved, codexSyncedCount: 2)

    let rpc = FakeCodexTransport()
    let turns: [[String: Any]] = [
        ["id": "trail-turn", "itemsView": itemsView, "items": [
            ["id": "old-codex-prompt", "type": "userMessage", "content": [["type": "text", "text": "Where should I hike?"]]],
            ["id": "missing-codex-reply", "type": "agentMessage", "text": "Try Eagle Trail."],
            ["id": savedReply.id, "type": "agentMessage", "text": "A conflicting copy of the saved reply."],
            ["id": "another-prompt", "type": "userMessage", "content": [["type": "text", "text": "Where should I hike?"]]],
            ["id": "unmatched-reply", "type": "agentMessage", "text": "Try another route."],
        ]],
    ]
    rpc.resumeResult = .success(CodexPayload(["thread": ["id": "trail-thread", "turns": turns]]))
    let client = ChatClient(rpc: rpc, options: options)
    let ready = try await client.connect()
    let recovered = ChatMessage(id: "missing-codex-reply", role: "assistant", text: "Try Eagle Trail.")
    #expect(ready.messages == (itemsView == "full" ? [original, recovered, savedReply, routerReply] : saved))
    await client.close()
}

@Test(arguments: ["deepseek/deepseek-v4.1-flash", "gpt-6-luna"])
func newChatClearsTheConversationAndKeepsTheSelectedModel(selectedModel: String) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-reset-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let configURL = dir.appendingPathComponent("openrouter.json")
    try OpenRouterClient.saveConfig(key: "test-or-key", to: configURL)
    try StateStore.save(threadId: "previous-thread", model: "gpt-6-luna", to: stateURL, messages: [
        ChatMessage(id: "previous-user", role: "user", text: "Previous conversation."),
    ])
    let options = ChatClientOptions(openRouterConfigURL: configURL, stateURL: stateURL, env: [:])
    let rpc = FakeCodexTransport()
    rpc.threadStartModel = "gpt-6-reroute"
    let client = ChatClient(rpc: rpc, options: options)
    _ = try await client.connect()
    let selected = try await client.selectModel(selectedModel)
    #expect(!selected.messages.isEmpty)

    let ready = try await client.newChat()
    #expect(ready.threadId != selected.threadId)
    #expect(ready.messages.isEmpty)
    #expect(ready.model == selectedModel)
    await client.close()

    let reopened = ChatClient(rpc: FakeCodexTransport(), options: options)
    let restored = try await reopened.connect()
    #expect(restored.threadId == ready.threadId)
    #expect(restored.messages.isEmpty)
    #expect(restored.model == selectedModel)
    await reopened.close()
}

@Test(arguments: ["deepseek/deepseek-v4.1-flash", "gpt-6-luna"])
func restoredOpenRouterChatCanContinueOnCodex(savedModel: String) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("provider-handoff-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let configURL = dir.appendingPathComponent("openrouter.json")
    try OpenRouterClient.saveConfig(key: "test-or-key", to: configURL)
    let history = [
        ChatMessage(id: "user-1", role: "user", text: "Remember orchard."),
        ChatMessage(id: "assistant-1", role: "assistant", text: "Orchard remembered.", reasoning: "private provider reasoning"),
    ]
    try StateStore.save(threadId: "openrouter-" + UUID().uuidString.lowercased(), model: savedModel,
                        to: stateURL, messages: history, codexSyncedCount: 0)
    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: ChatClientOptions(openRouterConfigURL: configURL, stateURL: stateURL, env: [:]))
    let ready = try await client.connect()
    #expect(ready.messages == history)
    if savedModel != "gpt-6-luna" {
        _ = try await client.selectModel("gpt-6-luna")
    }
    try await client.send("What did I ask you to remember?")

    let startedThread = try #require(rpc.calls.first { $0.method == "thread/start" })
    #expect(startedThread.params["model"] as? String == "gpt-6-luna")
    let turn = try #require(rpc.calls.first { $0.method == "turn/start" })
    #expect(turn.params["threadId"] as? String == "dedicated")
    let input = try #require((turn.params["input"] as? [[String: Any]])?.first?["text"] as? String)
    #expect(input.contains("Remember orchard."))
    #expect(input.contains("Orchard remembered."))
    #expect(!input.contains("private provider reasoning"))
    #expect(input.hasSuffix("What did I ask you to remember?"))
    let saved = try #require(StateStore.load(from: stateURL))
    #expect(saved.threadId == "dedicated")
    #expect(saved.messages == history)
    #expect(!rpc.calls.contains { ($0.params["threadId"] as? String)?.hasPrefix("openrouter-") == true })
    rpc.onNotification?(CodexNotification(method: "turn/completed", params: [
        "threadId": "dedicated", "turn": ["id": "turn-1", "status": "completed"],
    ]))
    try await client.send("Continue")
    #expect(rpc.calls.filter { $0.method == "thread/start" }.count == 1)
    let followUp = try #require(rpc.calls.last { $0.method == "turn/start" })
    #expect((followUp.params["input"] as? [[String: Any]])?.first?["text"] as? String == "Continue")
    await client.close()
}

@Test(arguments: [false, true])
func failedCodexHandoffPreservesHistoryAndCanRetry(malformedResponse: Bool) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("failed-handoff-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let history = [ChatMessage(id: "previous", role: "user", text: "Keep this message.")]
    let localId = "openrouter-" + UUID().uuidString.lowercased()
    try StateStore.save(threadId: localId, model: "gpt-6-luna", to: stateURL, messages: history, codexSyncedCount: 0)
    let rpc = FakeCodexTransport()
    rpc.failThreadStart = !malformedResponse
    rpc.missingThreadId = malformedResponse
    let client = ChatClient(rpc: rpc, options: ChatClientOptions(
        openRouterConfigURL: dir.appendingPathComponent("openrouter.json"), stateURL: stateURL, env: [:]))
    _ = try await client.connect()
    await #expect(throws: (any Error).self) { try await client.send("Try again") }
    #expect(!client.busy)
    #expect(StateStore.load(from: stateURL)?.threadId == localId)
    #expect(StateStore.load(from: stateURL)?.messages == history)
    #expect(!rpc.calls.contains { $0.method == "turn/start" })
    rpc.failThreadStart = false
    rpc.missingThreadId = false
    try await client.send("Try again")
    let turn = try #require(rpc.calls.first { $0.method == "turn/start" })
    let input = try #require((turn.params["input"] as? [[String: Any]])?.first?["text"] as? String)
    #expect(input.contains("Keep this message."))
    #expect(StateStore.load(from: stateURL)?.threadId == "dedicated")
    await client.close()
}

private func sseStream(_ events: [[String: Any]]) -> OpenRouterHTTPResponse {
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

@Test func detachedConversationCanSelectModelsAndContinueOnOpenRouter() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-detached-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")
    let configURL = dir.appendingPathComponent("openrouter.json")
    let routerModel = "deepseek/deepseek-v4.1-flash"
    try OpenRouterClient.saveConfig(key: "test-or-key", to: configURL)
    let history = [
        ChatMessage(id: "saved-user", role: "user", text: "Remember orchard."),
        ChatMessage(id: "saved-reply", role: "assistant", text: "Orchard remembered."),
    ]
    try StateStore.save(threadId: "original-thread", model: routerModel, to: stateURL, messages: history, codexSyncedCount: 2)
    let fetch: OpenRouterFetch = { request in
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(body["model"] as? String == routerModel)
        #expect(messages.filter { $0["role"] as? String != "system" }.compactMap { $0["content"] as? String } == [
            "Remember orchard.", "Orchard remembered.", "What did I ask you to remember?",
        ])
        return sseStream([["choices": [["delta": ["content": "Orchard."]]]]])
    }
    let options = ChatClientOptions(openRouterFetch: fetch, openRouterConfigURL: configURL, stateURL: stateURL, env: [:])
    let rpc = FakeCodexTransport()
    rpc.resumeResult = .failure(NSError(domain: "SpeedChat.Codex", code: -2))
    let client = ChatClient(rpc: rpc, options: options)
    let ready = try await client.connect()
    #expect(ready.messages == history)
    let openAI = try await client.selectModel("gpt-6-luna")
    #expect(openAI.model == "gpt-6-luna")
    let openRouter = try await client.selectModel(routerModel)
    #expect(openRouter.model == routerModel)
    #expect(openRouter.messages == history)

    let (done, completion) = AsyncStream<Bool>.makeStream()
    client.onDone = { completion.yield(true) }
    client.onError = { _ in completion.yield(false) }
    try await client.send("What did I ask you to remember?")
    var responses = done.makeAsyncIterator()
    #expect(await responses.next() == true)
    #expect(rpc.calls.filter { $0.method.hasPrefix("thread/") || $0.method.hasPrefix("turn/") }.map(\.method) == ["thread/resume"])
    await client.close()

    let unavailable = FakeCodexTransport()
    unavailable.failStart = true
    let reopened = ChatClient(rpc: unavailable, options: options)
    let restored = try await reopened.connect()
    #expect(restored.threadId == "original-thread")
    #expect(restored.messages.prefix(2).elementsEqual(history))
    #expect(restored.messages.dropFirst(2).map(\.text) == ["What did I ask you to remember?", "Orchard."])
    await reopened.close()
}

@Test func chooserIncludesOnlyVisibleModelsSupportingLowEffortAndPrefersLuna() {
    let raw: [[String: Any]] = [
        ["id": "gpt-6-sol", "model": "gpt-6-sol", "displayName": "Sol", "hidden": false, "supportedReasoningEfforts": [["reasoningEffort": "low"]]],
        ["id": "gpt-6-luna", "model": "gpt-6-luna", "displayName": "Luna", "hidden": false, "supportedReasoningEfforts": [["reasoningEffort": "low"]]],
        ["id": "hidden", "model": "hidden", "displayName": "Hidden", "hidden": true, "supportedReasoningEfforts": [["reasoningEffort": "low"]]],
        ["id": "med", "model": "med", "displayName": "Med", "hidden": false, "supportedReasoningEfforts": [["reasoningEffort": "medium"]]],
    ]
    let models = ChatClient.availableModels(from: raw)
    #expect(models.map(\.model) == ["gpt-6-sol", "gpt-6-luna"])
    #expect(ChatClient.defaultModel(from: models) == "gpt-6-luna")
    let fallback = ChatClient.availableModels(from: [raw[0]])
    #expect(ChatClient.defaultModel(from: fallback) == "gpt-6-sol")
}

@Test func defaultOpenRouterLineupAndModelParsing() throws {
    #expect(OpenRouterClient.defaultModels.map(\.model) == [
        "deepseek/deepseek-v4.1-flash",
        "mistralai/mistral-large-4-0",
        "qwen/qwen3.8-flash",
        "moonshotai/kimi-k3",
        "z-ai/glm-5.3-flashx",
        "google/gemma-4-26b-a4b-it",
        "deepseek/deepseek-v4-pro-0813",
    ])
    #expect(OpenRouterClient.defaultModels.allSatisfy { $0.provider == "openrouter" })

    let parsed = OpenRouterClient.parseModels("deepseek/deepseek-v4.1-flash | DeepSeek Flash\nqwen/qwen3.8-flash\ndeepseek/deepseek-v4.1-flash | Duplicate")
    #expect(parsed == [
        ChatModel(model: "deepseek/deepseek-v4.1-flash", displayName: "DeepSeek Flash", provider: "openrouter"),
        ChatModel(model: "qwen/qwen3.8-flash", displayName: "Qwen 3.8 Flash", provider: "openrouter"),
    ])
}

@Test func unifiedCatalogStreamsOpenRouterWithWebSearchAndSyncsToCodex() async throws {
    let stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-or-client-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: stateDir) }
    let cfgURL = stateDir.appendingPathComponent("openrouter.json")
    let stateURL = stateDir.appendingPathComponent("state.json")
    try OpenRouterClient.saveConfig(key: "test-or-key", to: cfgURL)

    final class FetchRecorder: @unchecked Sendable {
        var bodies = [[String: Any]]()
    }
    let recorder = FetchRecorder()

    let fakeFetch: OpenRouterFetch = { request in
        if let bodyData = request.httpBody,
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            recorder.bodies.append(json)
        }
        if recorder.bodies.count == 1 {
            return sseStream([
                [
                    "choices": [
                        [
                            "delta": [
                                "tool_calls": [
                                    [
                                        "index": 0,
                                        "id": "call_1",
                                        "function": ["name": "web_search", "arguments": "{\"query\":\"Fresno weather\"}"],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ])
        }
        return sseStream([
            ["choices": [["delta": ["content": "It is sunny in Fresno."]]]],
            [
                "choices": [
                    [
                        "delta": [
                            "annotations": [
                                [
                                    "type": "url_citation",
                                    "url_citation": ["url": "https://weather.example.com/fresno", "title": "Fresno Forecast"],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ])
    }

    let rpc = FakeCodexTransport()
    let client = ChatClient(
        rpc: rpc,
        options: ChatClientOptions(openRouterFetch: fakeFetch, openRouterConfigURL: cfgURL, stateURL: stateURL, env: ["SPEEDCHAT_STATE_DIR": stateDir.path])
    )
    let ready = try await client.connect()
    #expect(ready.models.contains(where: { $0.model == "gpt-6-luna" && $0.provider == "openai" }))
    #expect(ready.models.contains(where: { $0.model == "deepseek/deepseek-v4.1-flash" && $0.provider == "openrouter" }))

    _ = try await client.selectModel("deepseek/deepseek-v4.1-flash")

    final class TurnBox: @unchecked Sendable {
        var searched = false
        var messages = [String]()
    }
    let box = TurnBox()
    let (doneStream, doneCont) = AsyncStream<Void>.makeStream()
    client.onSearching = { box.searched = true }
    client.onMessage = { _, text in box.messages.append(text) }
    client.onDone = { doneCont.yield() }

    try await client.send("What is the weather in Fresno?")
    for await _ in doneStream { break }

    #expect(box.searched)
    #expect(recorder.bodies.count == 2)
    let plugins = recorder.bodies[1]["plugins"] as? [[String: Any]]
    #expect(plugins?.first?["id"] as? String == "web")
    #expect(box.messages.last?.contains("It is sunny in Fresno.") == true)
    #expect(box.messages.last?.contains("[Fresno Forecast](https://weather.example.com/fresno)") == true)

    _ = try await client.selectModel("gpt-6-luna")
    try await client.send("Summarize that forecast")
    let turnStart = rpc.calls.first(where: { $0.method == "turn/start" })
    let inputList = turnStart?.params["input"] as? [[String: Any]]
    let sentInput = (inputList?.first?["text"] as? String) ?? ""
    #expect(sentInput.contains("Earlier turns in this conversation"))
    #expect(sentInput.contains("It is sunny in Fresno."))

    await client.close()
}

@Test func openRouterWorksStandaloneWhenCodexIsUnavailable() async throws {
    let stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-or-standalone-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: stateDir) }
    let cfgURL = stateDir.appendingPathComponent("openrouter.json")
    let stateURL = stateDir.appendingPathComponent("state.json")
    try OpenRouterClient.saveConfig(key: "test-or-key", to: cfgURL)

    let rpc = FakeCodexTransport()
    rpc.failStart = true
    let fakeFetch: OpenRouterFetch = { _ in
        sseStream([["choices": [["delta": ["content": "Hello from Kimi!"]]]]])
    }
    let client = ChatClient(
        rpc: rpc,
        options: ChatClientOptions(openRouterFetch: fakeFetch, openRouterConfigURL: cfgURL, stateURL: stateURL, env: ["SPEEDCHAT_STATE_DIR": stateDir.path])
    )
    let ready = try await client.connect()
    #expect(ready.threadId.hasPrefix("openrouter-"))
    #expect(ready.model == "deepseek/deepseek-v4.1-flash")

    let (doneStream, doneCont) = AsyncStream<String>.makeStream()
    client.onMessage = { _, text in doneCont.yield(text) }
    try await client.send("Hi")
    var reply = ""
    for await msg in doneStream { reply = msg; break }
    #expect(reply == "Hello from Kimi!")
    await client.close()
}

@Test func clientLifecycleTitleNamingBusyGatingInterruptAndToolBlocking() async throws {
    let stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-client-lifecycle-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: stateDir) }
    let stateURL = stateDir.appendingPathComponent("state.json")
    let cfgURL = stateDir.appendingPathComponent("openrouter.json")

    let rpc = FakeCodexTransport()
    let client = ChatClient(
        rpc: rpc,
        options: ChatClientOptions(openRouterConfigURL: cfgURL, stateURL: stateURL, env: ["SPEEDCHAT_STATE_DIR": stateDir.path])
    )
    _ = try await client.connect()

    // Check thread/start policy
    let startCall = rpc.calls.first(where: { $0.method == "thread/start" })!
    #expect((startCall.params["config"] as? [String: String])?["web_search"] == "live")
    #expect(startCall.params["sandbox"] as? String == "read-only")
    #expect(startCall.params["approvalPolicy"] as? String == "never")

    // Hold turn/start to test busy gating and early interrupt
    rpc.holdTurnStart = true
    let sendTask = Task {
        try await client.send("Can you help me plan a weekend trip to Yosemite?")
    }
    for _ in 0..<50 {
        if client.busy { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    await #expect(throws: Error.self) { try await client.send("duplicate") }
    await #expect(throws: Error.self) { _ = try await client.newChat() }

    await client.interrupt()
    rpc.releaseTurnStart(turnId: "t1")
    try await sendTask.value

    // First message title derived and early interrupt delivered
    let renameCalls = rpc.calls.filter { $0.method == "thread/name/set" && ($0.params["name"] as? String) != "New chat" }
    #expect(renameCalls.last?.params["name"] as? String == "Plan a weekend trip to Yosemite")
    #expect(rpc.calls.contains(where: { $0.method == "turn/interrupt" }))

    // Foreign and late events ignored; reroutes update active model; unknown tools & image tools handled
    final class EventCollector: @unchecked Sendable {
        var models = [String]()
        var deltas = [String]()
        var errors = [String]()
        var messages = [String]()
    }
    let collector = EventCollector()
    client.onModel = { collector.models.append($0) }
    client.onDelta = { d, _ in collector.deltas.append(d) }
    client.onError = { collector.errors.append($0.localizedDescription) }
    client.onMessage = { _, text in collector.messages.append(text) }

    rpc.onNotification?(CodexNotification(method: "item/agentMessage/delta", params: ["threadId": "other", "delta": "foreign"]))
    rpc.onNotification?(CodexNotification(method: "item/agentMessage/delta", params: ["threadId": "dedicated", "turnId": "old", "delta": "old"]))
    #expect(collector.deltas.isEmpty)

    rpc.onNotification?(CodexNotification(method: "model/rerouted", params: ["threadId": "dedicated", "toModel": "gpt-6-sol"]))
    #expect(collector.models.last == "gpt-6-sol")

    // Blocked tool item
    rpc.onNotification?(CodexNotification(method: "item/started", params: [
        "threadId": "dedicated",
        "turnId": "t1",
        "item": ["id": "bad", "type": "browserControl"],
    ]))
    #expect(collector.errors.last?.contains("Blocked") == true)
    rpc.onNotification?(CodexNotification(method: "turn/completed", params: [
        "threadId": "dedicated",
        "turnId": "t1",
        "turn": ["status": "interrupted"],
    ]))

    // Image tool attempt produces plain-text explanation without raising turn error
    try await client.send("make an image")
    rpc.onNotification?(CodexNotification(method: "item/started", params: [
        "threadId": "dedicated",
        "turnId": "turn-1",
        "item": ["id": "img", "type": "mcpToolCall", "arguments": ["code": "nodeRepl.emitImage(buf)"]],
    ]))
    #expect(collector.messages.last?.contains("text-only") == true)

    await client.close()
}

@Test func inFlightTitleNamingAndModelUpdateLocking() async throws {
    let stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-client-locks-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: stateDir) }
    let stateURL = stateDir.appendingPathComponent("state.json")
    let cfgURL = stateDir.appendingPathComponent("openrouter.json")

    let rpc = FakeCodexTransport()
    let client = ChatClient(
        rpc: rpc,
        options: ChatClientOptions(openRouterConfigURL: cfgURL, stateURL: stateURL, env: ["SPEEDCHAT_STATE_DIR": stateDir.path])
    )
    _ = try await client.connect()

    // 1. Model update locks send and newChat until acknowledgement
    rpc.holdSettings = true
    let selectTask = Task {
        try await client.selectModel("gpt-6-luna")
    }
    for _ in 0..<50 {
        if client.busy { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    await #expect(throws: Error.self) { try await client.send("race") }
    await #expect(throws: Error.self) { _ = try await client.newChat() }
    rpc.releaseSettings()
    _ = try await selectTask.value

    // 2. In-flight title naming for an earlier thread does not suppress naming after newChat
    rpc.holdFirstRename = true
    let firstSend = Task {
        try await client.send("First thread topic")
    }
    for _ in 0..<50 {
        if rpc.calls.contains(where: { $0.method == "turn/start" }) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    rpc.onNotification?(CodexNotification(method: "turn/completed", params: [
        "threadId": "dedicated",
        "turnId": "turn-1",
        "turn": ["status": "completed"],
    ]))
    _ = try await client.newChat()
    rpc.releaseRename()
    try await firstSend.value

    try await client.send("Second thread topic")
    let renames = rpc.calls.filter { $0.method == "thread/name/set" && ($0.params["name"] as? String) != "New chat" }
    #expect(renames.map { "\($0.params["threadId"] ?? ""):\($0.params["name"] ?? "")" } == [
        "dedicated:First thread topic",
        "thread-1:Second thread topic",
    ])

    await client.close()
}
