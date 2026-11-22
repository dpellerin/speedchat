struct CodexHistory: Sendable {
    struct UserInput: Sendable {
        let id: String?
        let clientId: String?
        let wireText: String?
        let visibleText: String

        init?(item: [String: Any]) {
            guard item["type"] as? String == "userMessage" else { return nil }
            id = item["id"] as? String
            clientId = item["clientId"] as? String
            let parts = item["content"] as? [[String: Any]] ?? []
            let text = parts.compactMap { part -> String? in
                guard part["type"] as? String == "text" else { return nil }
                return part["text"] as? String
            }
            if parts.count == 1, let part = parts.first,
               part["text_elements"] == nil || (part["text_elements"] as? [Any])?.isEmpty == true {
                wireText = text.first
            } else {
                wireText = nil
            }
            visibleText = text.joined(separator: "\n")
        }

        func containsPrompt(_ prompt: String) -> Bool {
            guard let wireText else { return false }
            if wireText.utf8.elementsEqual(prompt.utf8) { return true }
            let suffix = "]\n\n\(prompt)".utf8
            return wireText.hasPrefix(ChatPrompt.quotedHistoryPrefix) &&
                wireText.utf8.suffix(suffix.count).elementsEqual(suffix)
        }

        var containsQuotedHistory: Bool {
            visibleText.hasPrefix(ChatPrompt.quotedHistoryPrefix) && visibleText.contains("]\n\n")
        }
    }

    enum Item: Sendable {
        case user(UserInput)
        case assistant(ChatMessage)

        var user: UserInput? {
            if case .user(let input) = self { return input }
            return nil
        }
    }

    struct Exchange {
        let input: UserInput
        var replies: [ChatMessage] = []
    }

    struct Turn: Sendable {
        let id: String?
        let items: [Item]
        let status: String?
        let isFull: Bool

        init(_ turn: [String: Any]) {
            id = turn["id"] as? String
            status = turn["status"] as? String
            let rawItems = turn["items"] as? [[String: Any]]
            isFull = rawItems != nil && (turn["itemsView"] == nil || turn["itemsView"] as? String == "full")
            let sources = (rawItems ?? []).flatMap { item -> [CitationSource] in
                guard item["type"] as? String == "webSearch" else { return [] }
                return RenderNormalizer.citationSources(from: item["results"])
            }
            items = (rawItems ?? []).compactMap { item in
                switch item["type"] as? String {
                case "userMessage":
                    return UserInput(item: item).map(Item.user)
                case "agentMessage":
                    guard let id = item["id"] as? String, !id.isEmpty,
                          item["phase"] as? String != "commentary",
                          let text = item["text"] as? String, !text.isEmpty else { return nil }
                    return .assistant(ChatMessage(id: id, role: "assistant", text: RenderNormalizer.normalizeAssistantText(text, sources: sources)))
                default:
                    return nil
                }
            }
        }

        var exchanges: [Exchange] {
            guard isFull else { return [] }
            var result = [Exchange]()
            for item in items {
                switch item {
                case .user(let input):
                    result.append(Exchange(input: input))
                case .assistant(let message):
                    if !result.isEmpty { result[result.count - 1].replies.append(message) }
                }
            }
            return result
        }
    }

    let turns: [Turn]
    let isThreadActive: Bool

    init(turns: [[String: Any]], isThreadActive: Bool = false) {
        self.turns = turns.map(Turn.init)
        self.isThreadActive = isThreadActive
    }

    func matchingReceipt(for attempt: CodexSendAttempt, threadId: String) -> (turn: Turn, itemId: String)? {
        let matches = turns.flatMap { turn -> [(turn: Turn, itemId: String)] in
            guard turn.isFull, let turnId = turn.id else { return [] }
            return turn.items.compactMap { item in
                guard let input = item.user, let itemId = input.id,
                      attempt.matchesReceipt(threadId: threadId, turnId: turnId, input: input) else { return nil }
                return (turn, itemId)
            }
        }
        return matches.count == 1 ? matches.first : nil
    }

    var legacyMessages: [ChatMessage] {
        turns.flatMap { turn in
            turn.items.compactMap { item in
                switch item {
                case .user(let input):
                    // Without a saved prompt there is no safe way to split the unescaped quote.
                    guard let id = input.id, !input.visibleText.isEmpty, !input.containsQuotedHistory else { return nil }
                    return ChatMessage(id: id, role: "user", text: input.visibleText)
                case .assistant(let message):
                    return message
                }
            }
        }
    }
}
