import Foundation
@testable import ChatCore

final class HistoryTestClock: @unchecked Sendable {
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

    func advance(days: Double) {
        advance(by: days * 86_400)
    }
}

func completeHistoryCodexTurn(
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
