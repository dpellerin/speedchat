import Foundation

// ChatClient owns this value under its conversation lock.
struct ConversationContinuity {
    enum Thread {
        case standalone(String)
        case detached(String)
        case missing(String)
        case attached(String)

        var id: String {
            switch self {
            case .standalone(let id), .detached(let id), .missing(let id), .attached(let id):
                return id
            }
        }
    }

    var thread: Thread?
    var messages: [ChatMessage] = []
    var codexSyncedCount = 0
    var titleNeeded = false
    private var needsLegacyHistory = false

    var attachedThreadId: String? {
        if case .attached(let id) = thread { return id }
        return nil
    }

    init(thread: Thread? = nil, titleNeeded: Bool = false) {
        self.thread = thread
        self.titleNeeded = titleNeeded
    }

    init(restoring saved: PersistedState) {
        thread = saved.threadId.hasPrefix("openrouter-") ? .standalone(saved.threadId) : .detached(saved.threadId)
        messages = saved.messages ?? []
        codexSyncedCount = min(max(saved.codexSyncedCount ?? 0, 0), messages.count)
        needsLegacyHistory = saved.messages == nil
    }

    mutating func recordCodexReceipt(_ attempt: CodexSendAttempt) -> Bool {
        guard thread?.id == attempt.threadId,
              attempt.syncedCount > 0, attempt.syncedCount <= messages.count else { return false }
        let user = messages[attempt.syncedCount - 1]
        guard user.id == attempt.userMessageId, user.role == "user" else { return false }
        codexSyncedCount = max(codexSyncedCount, attempt.syncedCount)
        return true
    }

    mutating func didResume(threadId: String, name: String?, history: CodexHistory) -> Bool {
        guard thread?.id == threadId else { return false }
        thread = .attached(threadId)
        titleNeeded = name == nil || name == "" || name == "SpeedChat" || name == "New chat"
        if needsLegacyHistory && messages.isEmpty {
            guard history.turns.allSatisfy(\.isFull) else { return false }
            needsLegacyHistory = false
            messages = history.legacyMessages
            codexSyncedCount = messages.count
            return true
        }
        needsLegacyHistory = false

        let inputs = history.turns.flatMap { $0.items.compactMap(\.user) }
        let inputsByClientId = Dictionary(grouping: inputs, by: \.clientId)
        let exchanges = history.turns.flatMap(\.exchanges)
        let repliesById = Dictionary(grouping: exchanges.flatMap(\.replies), by: \.id)
        var recovered = false
        for exchange in exchanges {
            guard !exchange.replies.isEmpty,
                  exchange.replies.allSatisfy({ repliesById[$0.id]?.count == 1 }) else { continue }
            let input = exchange.input
            let anchor: Int?
            if let id = input.id, !id.isEmpty,
               let clientId = input.clientId, !clientId.isEmpty, inputsByClientId[clientId]?.count == 1,
               let index = userIndex(messageId: clientId), input.containsPrompt(messages[index].text) {
                anchor = index
            } else {
                anchor = nil
            }
            if recoverReplies(exchange.replies, after: anchor) {
                recovered = true
            }
        }
        return recovered
    }

    // The caller has verified that this Codex input belongs to the saved message.
    mutating func recoverReplies(in turn: CodexHistory.Turn, threadId: String, after userItemId: String, for userMessageId: String) -> Bool {
        guard thread?.id == threadId, !userItemId.isEmpty,
              let anchor = userIndex(messageId: userMessageId) else { return false }
        let matches = turn.exchanges.filter { $0.input.id == userItemId }
        guard matches.count == 1, let exchange = matches.first else { return false }
        return recoverReplies(exchange.replies, after: anchor)
    }

    private func userIndex(messageId: String) -> Int? {
        let matches = messages.indices.filter { messages[$0].id == messageId }
        guard matches.count == 1, let index = matches.first, messages[index].role == "user" else { return nil }
        return index
    }

    private mutating func recoverReplies(_ replies: [ChatMessage], after userAnchor: Int?) -> Bool {
        guard !replies.isEmpty, Set(replies.map(\.id)).count == replies.count else { return false }
        var previousIndex = userAnchor ?? -1
        var firstSavedReply: Int?
        for reply in replies {
            let matches = messages.indices.filter { messages[$0].id == reply.id }
            guard !matches.isEmpty else { continue }
            guard matches.count == 1, let index = matches.first, index > previousIndex,
                  messages[index].role == "assistant" else { return false }
            if firstSavedReply == nil { firstSavedReply = index }
            previousIndex = index
        }

        guard var insertionIndex = userAnchor.map({ $0 + 1 }) ?? firstSavedReply else { return false }
        var recovered = false
        for reply in replies {
            if let index = messages.firstIndex(where: { $0.id == reply.id }) {
                insertionIndex = index + 1
            } else {
                messages.insert(reply, at: insertionIndex)
                if insertionIndex <= codexSyncedCount { codexSyncedCount += 1 }
                insertionIndex += 1
                recovered = true
            }
        }
        return recovered
    }

    mutating func didConfirmThreadLoss(_ id: String) {
        if case .detached(id) = thread {
            thread = .missing(id)
        }
    }

    mutating func didStartCodexThread(_ id: String) {
        thread = .attached(id)
        codexSyncedCount = 0
        titleNeeded = true
        needsLegacyHistory = false
    }

    func save(model: String, to url: URL?, env: [String: String]) throws {
        guard let thread else { return }
        try StateStore.save(
            threadId: thread.id,
            model: model,
            to: url,
            messages: needsLegacyHistory && messages.isEmpty ? nil : messages,
            codexSyncedCount: codexSyncedCount,
            env: env
        )
    }
}
