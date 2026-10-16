import Testing
import Foundation
@testable import ChatCore

final class FakeCodexTransport: CodexTransport, @unchecked Sendable {
    private let lock = NSLock()
    var onNotification: (@Sendable (CodexNotification) -> Void)?
    var onExit: (@Sendable () -> Void)?
    var calls = [(method: String, params: [String: Any])]()
    var failStart = false
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
        if method == "thread/start" {
            let count = sync { () -> Int in
                let c = threadCounter
                threadCounter += 1
                return c
            }
            let id = count == 0 ? "dedicated" : "thread-\(count)"
            return ["thread": ["id": id], "model": "gpt-6-luna"]
        }
        if method == "turn/start" {
            return ["turn": ["id": "turn-1"]]
        }
        return [:]
    }
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
