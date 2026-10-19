import Testing
import Foundation
@testable import ChatCore

@Test func stateRoundTripsWithPrivatePermissions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("speedchat-state-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("nested/state.json")
    try StateStore.save(threadId: "thread-123", model: "gpt-6-luna", to: url)
    let loaded = StateStore.load(from: url)
    #expect(loaded?.threadId == "thread-123")
    #expect(loaded?.model == "gpt-6-luna")
    #expect(loaded?.version == PersistedState.currentVersion)
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
    #expect((perms & 0o777) == 0o600)
}

@Test func macStateIsIsolatedFromXDGAndSupportsTestIsolation() {
    let defaultPath = StateStore.stateURL(env: ["XDG_STATE_HOME": "/do-not-use"]).path
    #expect(defaultPath.hasSuffix("/Library/Application Support/SpeedChat/state.json"))
    #expect(StateStore.stateURL(env: ["SPEEDCHAT_STATE_DIR": "/tmp/mac-test"]).path == "/tmp/mac-test/state.json")
}

@Test func olderChatPolicyStateIsNotResumed() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("speedchat-old-state-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("state.json")
    try "{\"version\":1,\"threadId\":\"old\",\"model\":\"gpt-6-luna\",\"updatedAt\":\"2026-01-01T00:00:00Z\"}".write(to: url, atomically: true, encoding: .utf8)
    #expect(StateStore.load(from: url) == nil)
    #expect(StateStore.load(from: root.appendingPathComponent("missing.json")) == nil)
}

@Test func turnHistoryKeepsOnlyUserAndFinalAssistantMessagesAndResolvesCitations() {
    let turns: [[String: Any]] = [
        [
            "id": "turn",
            "status": "completed",
            "items": [
                ["id": "u", "type": "userMessage", "content": [["type": "text", "text": "Hello"]]],
                ["id": "c", "type": "agentMessage", "phase": "commentary", "text": "Working"],
                ["id": "s", "type": "webSearch", "results": [["ref_id": "turn0search0", "title": "Example", "url": "https://example.com"]]],
                ["id": "a", "type": "agentMessage", "phase": "final_answer", "text": "Fact. \u{E200}cite\u{E202}turn0search0\u{E201}"],
                ["id": "tool", "type": "commandExecution"],
            ],
        ],
    ]
    let messages = StateStore.messagesFromTurns(turns)
    #expect(messages == [
        ChatMessage(id: "u", role: "user", text: "Hello"),
        ChatMessage(id: "a", role: "assistant", text: "Fact. [Example](https://example.com)"),
    ])
}

@Test func errorsAreTranslatedIntoRecoveryActions() {
    #expect(StateStore.friendlyErrorMessage("unauthorized").contains("codex login"))
    #expect(StateStore.friendlyErrorMessage("usageLimitExceeded").contains("usage limit"))
    #expect(StateStore.friendlyErrorMessage("codex executable was not found").contains("Install Codex"))
    #expect(StateStore.friendlyErrorMessage("model is unavailable").contains("not available"))
}

@Test func codexProtocolArgumentsDisableToolsAndKeepLiveWebSearch() {
    let args = CodexProtocol.arguments()
    #expect(Array(args.prefix(2)) == ["app-server", "--stdio"])
    for feature in CodexProtocol.disabledFeatures {
        let found = (0..<(args.count - 1)).contains { args[$0] == "-c" && args[$0 + 1] == "features.\(feature)=false" }
        #expect(found, "Expected \(feature) to be disabled")
    }
    #expect(Array(args.suffix(4)) == ["-c", "mcp_servers={}", "-c", "web_search=\"live\""])
    #expect(args.contains("forced_login_method=\"chatgpt\""))
    #expect(args.contains("skip_host_skill_discovery"))
    #expect(args.contains("standalone_web_search"))
    let disablesCodeModeHost = (0..<(args.count - 1)).contains { args[$0] == "--disable" && args[$0 + 1] == "code_mode_host" }
    #expect(!disablesCodeModeHost)
}
