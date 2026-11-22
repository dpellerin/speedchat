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

    func matchesReceipt(threadId: String, turnId: String, input: CodexHistory.UserInput) -> Bool {
        guard threadId == self.threadId, !turnId.isEmpty,
              self.turnId == nil || self.turnId == turnId,
              let itemId = input.id, !itemId.isEmpty, input.clientId == clientId,
              let submittedText = input.wireText else { return false }
        return submittedText.utf8.elementsEqual(wireText.utf8)
    }
}

public struct CodexRetry: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case retry
        case checkDelivery
        case recoverReply
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
        case .recoverReply: return "Codex received this message. Retry to recover the reply."
        case .resend: return "Codex may already have received this message. Sending it again could duplicate it."
        }
    }
}
