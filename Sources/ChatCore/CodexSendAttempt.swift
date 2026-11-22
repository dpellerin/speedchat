import Foundation

struct CodexSendAttempt: Codable, Equatable, Sendable {
    enum Delivery: String, Codable, Sendable {
        case unconfirmed
        case rejected
        case confirmed
    }

    let threadId: String
    let clientId: String
    let userMessageId: String
    let wireText: String
    var turnId: String?
    var delivery: Delivery = .unconfirmed

    func matchesReceipt(threadId: String, turnId: String, clientId: String?, wireText: String?) -> Bool {
        guard threadId == self.threadId, !turnId.isEmpty,
              self.turnId == nil || self.turnId == turnId,
              clientId == self.clientId, let wireText else { return false }
        return wireText.utf8.elementsEqual(self.wireText.utf8)
    }

    func matchesReceipt(threadId: String, turnId: String, item: [String: Any]) -> Bool {
        guard item["type"] as? String == "userMessage",
              let itemId = item["id"] as? String, !itemId.isEmpty,
              let content = item["content"] as? [[String: Any]], content.count == 1,
              let text = content.first, text["type"] as? String == "text",
              text["text_elements"] == nil || (text["text_elements"] as? [Any])?.isEmpty == true else { return false }
        return matchesReceipt(
            threadId: threadId, turnId: turnId,
            clientId: item["clientId"] as? String, wireText: text["text"] as? String
        )
    }
}

public struct CodexRetry: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case retry
        case checkDelivery
        case resend
    }

    public let userMessageId: String
    public let action: Action

    public init(userMessageId: String, action: Action) {
        self.userMessageId = userMessageId
        self.action = action
    }

    public var notice: String? {
        switch action {
        case .retry: return nil
        case .checkDelivery: return "Codex may already have received this message. Retry checks delivery."
        case .resend: return "Codex may already have received this message. Sending it again could duplicate it."
        }
    }
}
