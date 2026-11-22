import Foundation

struct CodexSendAttempt: Codable, Equatable, Sendable {
    let threadId: String
    let clientId: String
    let userMessageId: String
    let wireText: String
    let syncedCount: Int
    var turnId: String?

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
