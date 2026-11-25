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

    var conversationId: String?
    var createdAt: String?
    var updatedAt: String?
    var thread: Thread?
    var messages: [ChatMessage] = []
    var codexSyncedCount = 0
    var lastCodexSend: CodexSendAttempt?
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
        conversationId = saved.conversationId
        createdAt = saved.createdAt
        updatedAt = saved.updatedAt
        if saved.threadId.isEmpty {
            thread = nil
        } else {
            thread = saved.threadId.hasPrefix("openrouter-") ? .standalone(saved.threadId) : .detached(saved.threadId)
        }
        messages = saved.messages ?? []
        codexSyncedCount = min(max(saved.codexSyncedCount ?? 0, 0), messages.count)
        if let attempt = saved.lastCodexSend, attempt.threadId == saved.threadId,
           userIndex(messageId: attempt.userMessageId) != nil {
            lastCodexSend = attempt
        }
        needsLegacyHistory = saved.messages == nil
    }

    init(restoring saved: SavedConversation) {
        conversationId = saved.id
        createdAt = saved.createdAt
        updatedAt = saved.updatedAt
        if saved.threadId.isEmpty {
            thread = nil
        } else {
            thread = saved.threadId.hasPrefix("openrouter-") ? .standalone(saved.threadId) : .detached(saved.threadId)
        }
        messages = saved.messages
        codexSyncedCount = min(max(saved.codexSyncedCount, 0), messages.count)
        if let attempt = saved.lastCodexSend, attempt.threadId == saved.threadId,
           userIndex(messageId: attempt.userMessageId) != nil {
            lastCodexSend = attempt
        }
        needsLegacyHistory = false
    }

    mutating func recordUndispatchedCodexPrompt(_ user: ChatMessage) {
        guard let thread else { return }
        if userIndex(messageId: user.id) == nil {
            messages.append(user)
        }
        lastCodexSend = CodexSendAttempt(
            threadId: thread.id, clientId: user.id, userMessageId: user.id,
            wireText: user.text, delivery: .rejected
        )
    }

    mutating func recordCodexReceipt(_ attempt: CodexSendAttempt, turnId: String) -> Bool {
        guard thread?.id == attempt.threadId, lastCodexSend?.clientId == attempt.clientId,
              let anchor = userIndex(messageId: attempt.userMessageId) else { return false }
        codexSyncedCount = max(codexSyncedCount, anchor + 1)
        lastCodexSend?.turnId = turnId
        lastCodexSend?.delivery = .confirmed
        return true
    }

    mutating func reconcileCodexSend(threadId: String, history: CodexHistory) -> CodexHistory.Turn? {
        guard let attempt = lastCodexSend, attempt.threadId == threadId,
              attempt.delivery != .rejected else { return nil }

        guard let (turn, itemId) = history.matchingReceipt(for: attempt, threadId: threadId),
              let turnId = turn.id,
              recordCodexReceipt(attempt, turnId: turnId) else { return nil }
        if turn.status != "inProgress" {
            _ = recoverReplies(in: turn, threadId: threadId, after: itemId, for: attempt.userMessageId)
        }
        return turn
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
        var recovered = reconcileCodexSend(threadId: threadId, history: history) != nil
        for exchange in exchanges {
            guard !exchange.replies.isEmpty,
                  exchange.replies.allSatisfy({ repliesById[$0.id]?.count == 1 }) else { continue }
            let input = exchange.input
            if let attempt = lastCodexSend,
               input.clientId == attempt.clientId || input.clientId == attempt.userMessageId { continue }
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

    func userIndex(messageId: String) -> Int? {
        let matches = messages.indices.filter { messages[$0].id == messageId }
        guard matches.count == 1, let index = matches.first, messages[index].role == "user" else { return nil }
        return index
    }

    @discardableResult
    mutating func placeCodexReply(_ reply: ChatMessage, after userMessageId: String, followsConfirmedPrompt: Bool) -> Bool {
        if let index = messages.firstIndex(where: { $0.id == reply.id }) {
            guard messages[index].role == "assistant", messages[index] != reply else { return false }
            messages[index] = reply
            return true
        }
        let nextUser = userIndex(messageId: userMessageId).flatMap { anchor in
            messages[(anchor + 1)...].firstIndex { $0.role == "user" }
        }
        let index = nextUser ?? messages.count
        messages.insert(reply, at: index)
        if index < codexSyncedCount || (followsConfirmedPrompt && index == codexSyncedCount) {
            codexSyncedCount += 1
        }
        return true
    }

    private mutating func recoverReplies(_ replies: [ChatMessage], after userAnchor: Int?) -> Bool {
        guard !replies.isEmpty, Set(replies.map(\.id)).count == replies.count else { return false }
        var previousIndex = userAnchor ?? -1
        var firstSavedReply: Int?
        var segmentEnd = userAnchor.flatMap { anchor in
            messages[(anchor + 1)...].firstIndex { $0.role == "user" }
        } ?? messages.count
        for reply in replies {
            let matches = messages.indices.filter { messages[$0].id == reply.id }
            guard !matches.isEmpty else { continue }
            guard matches.count == 1, let index = matches.first, index > previousIndex,
                  index < segmentEnd, messages[index].role == "assistant" else { return false }
            if firstSavedReply == nil {
                firstSavedReply = index
                if userAnchor == nil {
                    segmentEnd = messages[(index + 1)...].firstIndex { $0.role == "user" } ?? messages.count
                }
            }
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

    mutating func save(
        model: String,
        to url: URL?,
        env: [String: String],
        now: Date = Date(),
        touchActivity: Bool = true
    ) throws {
        guard let thread else { return }
        let target = url ?? StateStore.stateURL(env: env)
        let timestamp = StateStore.formatTimestamp(now)
        if !messages.isEmpty {
            let id = conversationId ?? UUID().uuidString.lowercased()
            let created = createdAt ?? timestamp
            let updated = (touchActivity || updatedAt == nil) ? timestamp : (updatedAt ?? timestamp)
            var record = SavedConversation(
                id: id,
                title: StateStore.derivedTitle(from: messages),
                createdAt: created,
                updatedAt: updated,
                model: model,
                threadId: thread.id,
                messages: messages,
                codexSyncedCount: min(max(codexSyncedCount, 0), messages.count)
            )
            record.lastCodexSend = lastCodexSend
            try StateStore.saveActiveConversation(record, to: target)
            conversationId = id
            createdAt = created
            updatedAt = updated
        } else {
            try StateStore.saveBlankActiveState(
                threadId: thread.id,
                model: model,
                updatedAt: timestamp,
                needsLegacyHistory: needsLegacyHistory,
                to: target
            )
        }
    }
}
