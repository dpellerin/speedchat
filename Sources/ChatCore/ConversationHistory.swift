import Foundation

public enum HistoryRetention: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case days7 = "7d"
    case days30 = "30d"
    case days90 = "90d"
    case year1 = "1y"
    case forever = "forever"

    public static let defaultPolicy: HistoryRetention = .days30

    public var id: String { rawValue }

    public var days: Int? {
        switch self {
        case .days7: return 7
        case .days30: return 30
        case .days90: return 90
        case .year1: return 365
        case .forever: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .days7: return "7 days"
        case .days30: return "30 days"
        case .days90: return "90 days"
        case .year1: return "1 year"
        case .forever: return "Forever"
        }
    }

    /// Returns true when switching from `other` to `self` shortens the retention window.
    public func isShorter(than other: HistoryRetention) -> Bool {
        switch (days, other.days) {
        case (.some(let lhs), .some(let rhs)): return lhs < rhs
        case (.some, .none): return true
        case (.none, _): return false
        }
    }

    public func isExpired(updatedAt: String, relativeTo now: Date) -> Bool {
        guard let days else { return false }
        guard let updatedDate = StateStore.parseTimestamp(updatedAt) else { return false }
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        return updatedDate < cutoff
    }
}

public struct HistoryMutationResult: Equatable, Sendable {
    public var removedCount: Int
    public var clearedActiveConversation: Bool
    public var readyState: ReadyState?

    public init(removedCount: Int, clearedActiveConversation: Bool, readyState: ReadyState? = nil) {
        self.removedCount = removedCount
        self.clearedActiveConversation = clearedActiveConversation
        self.readyState = readyState
    }
}

public struct HistoryMatchRange: Codable, Equatable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var updatedAt: String
    public var preview: String
    public var model: String
    public var messageCount: Int
    public var titleMatchRanges: [HistoryMatchRange]
    public var previewMatchRanges: [HistoryMatchRange]
    public var firstMatchingMessageId: String?

    public init(
        id: String,
        title: String,
        updatedAt: String,
        preview: String,
        model: String,
        messageCount: Int,
        titleMatchRanges: [HistoryMatchRange] = [],
        previewMatchRanges: [HistoryMatchRange] = [],
        firstMatchingMessageId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.preview = preview
        self.model = model
        self.messageCount = messageCount
        self.titleMatchRanges = titleMatchRanges
        self.previewMatchRanges = previewMatchRanges
        self.firstMatchingMessageId = firstMatchingMessageId
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, updatedAt, preview, model, messageCount
        case titleMatchRanges, previewMatchRanges, firstMatchingMessageId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        preview = try container.decode(String.self, forKey: .preview)
        model = try container.decode(String.self, forKey: .model)
        messageCount = try container.decode(Int.self, forKey: .messageCount)
        titleMatchRanges = try container.decodeIfPresent([HistoryMatchRange].self, forKey: .titleMatchRanges) ?? []
        previewMatchRanges = try container.decodeIfPresent([HistoryMatchRange].self, forKey: .previewMatchRanges) ?? []
        firstMatchingMessageId = try container.decodeIfPresent(String.self, forKey: .firstMatchingMessageId)
    }
}

public enum ConversationHistory {
    private static let maxPreviewLength = 160
    private static let leadingContextLength = 52

    public static func entries(from conversations: [SavedConversation]) -> [HistoryEntry] {
        conversations.map { entry(from: $0) }
    }

    public static func entry(from conversation: SavedConversation) -> HistoryEntry {
        HistoryEntry(
            id: conversation.id,
            title: conversation.title,
            updatedAt: conversation.updatedAt,
            preview: latestMessagePreview(from: conversation.messages),
            model: conversation.model,
            messageCount: conversation.messages.count
        )
    }

    /// Searches saved conversations using case-insensitive all-words matching across
    /// titles and visible user/assistant message text (strictly excluding private Beam reasoning).
    /// Conversations matching all query words in their title rank ahead of body-only matches,
    /// with ties broken by `updatedAt` descending.
    public static func search(_ conversations: [SavedConversation], query: String) -> [HistoryEntry] {
        let terms = tokenize(query)
        guard !terms.isEmpty else {
            return entries(from: sortedByUpdatedAtDescending(conversations))
        }

        var scored = [(entry: HistoryEntry, titleMatchesAll: Bool, updatedAt: Date?, updatedAtRaw: String)]()
        for conversation in conversations {
            let visibleMessages = conversation.messages.filter { $0.role == "user" || $0.role == "assistant" }
            let allTermsMatch = terms.allSatisfy { term in
                conversation.title.range(of: term, options: .caseInsensitive) != nil ||
                visibleMessages.contains { $0.text.range(of: term, options: .caseInsensitive) != nil }
            }
            guard allTermsMatch else { continue }

            let titleMatchesAll = terms.allSatisfy {
                conversation.title.range(of: $0, options: .caseInsensitive) != nil
            }
            let titleRanges = matchRanges(in: conversation.title, terms: terms)
            let matchedMessage = selectMatchingMessage(in: visibleMessages, title: conversation.title, terms: terms)

            let snippet: String
            let snippetRanges: [HistoryMatchRange]
            if let matchedMessage {
                let built = buildSnippet(from: matchedMessage.text, terms: terms)
                snippet = built.text
                snippetRanges = built.ranges
            } else {
                snippet = latestMessagePreview(from: visibleMessages)
                snippetRanges = matchRanges(in: snippet, terms: terms)
            }

            let entry = HistoryEntry(
                id: conversation.id,
                title: conversation.title,
                updatedAt: conversation.updatedAt,
                preview: snippet,
                model: conversation.model,
                messageCount: conversation.messages.count,
                titleMatchRanges: titleRanges,
                previewMatchRanges: snippetRanges,
                firstMatchingMessageId: matchedMessage?.id
            )
            scored.append((
                entry: entry,
                titleMatchesAll: titleMatchesAll,
                updatedAt: StateStore.parseTimestamp(conversation.updatedAt),
                updatedAtRaw: conversation.updatedAt
            ))
        }

        scored.sort { lhs, rhs in
            if lhs.titleMatchesAll != rhs.titleMatchesAll {
                return lhs.titleMatchesAll
            }
            switch (lhs.updatedAt, rhs.updatedAt) {
            case let (l?, r?) where l != r:
                return l > r
            default:
                return lhs.updatedAtRaw > rhs.updatedAtRaw
            }
        }
        return scored.map(\.entry)
    }

    /// Single-line preview derived strictly from visible message text (never private Beam reasoning).
    public static func latestMessagePreview(from messages: [ChatMessage]) -> String {
        let candidate = messages.reversed().first {
            ($0.role == "user" || $0.role == "assistant") &&
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.text ?? ""
        let collapsed = normalizeWhitespace(candidate)
        guard collapsed.count > maxPreviewLength else { return collapsed }
        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: maxPreviewLength - 1)
        let sliced = String(collapsed[..<cutoff]).replacingOccurrences(
            of: #"\s+\S*$"#,
            with: "",
            options: .regularExpression
        )
        return (sliced.isEmpty ? String(collapsed[..<cutoff]) : sliced) + "…"
    }

    private static func tokenize(_ query: String) -> [String] {
        var seen = Set<String>()
        var terms = [String]()
        for piece in query.split(whereSeparator: \.isWhitespace) {
            let term = String(piece)
            let key = term.lowercased()
            if seen.insert(key).inserted {
                terms.append(term)
            }
        }
        return terms
    }

    private static func sortedByUpdatedAtDescending(_ conversations: [SavedConversation]) -> [SavedConversation] {
        conversations.sorted { lhs, rhs in
            switch (StateStore.parseTimestamp(lhs.updatedAt), StateStore.parseTimestamp(rhs.updatedAt)) {
            case let (l?, r?) where l != r:
                return l > r
            default:
                return lhs.updatedAt > rhs.updatedAt
            }
        }
    }

    private static func selectMatchingMessage(
        in messages: [ChatMessage],
        title: String,
        terms: [String]
    ) -> ChatMessage? {
        // 1. Prefer the first message in chronological order containing all query terms.
        if let allMatch = messages.first(where: { message in
            terms.allSatisfy { message.text.range(of: $0, options: .caseInsensitive) != nil }
        }) {
            return allMatch
        }
        // 2. Next prefer the first message containing a query term not already matched in the title.
        let bodyOnlyTerms = terms.filter { title.range(of: $0, options: .caseInsensitive) == nil }
        if !bodyOnlyTerms.isEmpty,
           let bodyMatch = messages.first(where: { message in
               bodyOnlyTerms.contains { message.text.range(of: $0, options: .caseInsensitive) != nil }
           }) {
            return bodyMatch
        }
        // 3. Fall back to the first message matching any query term.
        return messages.first { message in
            terms.contains { message.text.range(of: $0, options: .caseInsensitive) != nil }
        }
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func buildSnippet(from rawText: String, terms: [String]) -> (text: String, ranges: [HistoryMatchRange]) {
        let collapsed = normalizeWhitespace(rawText)
        guard !collapsed.isEmpty else { return ("", []) }

        let fullRanges = matchRanges(in: collapsed, terms: terms)
        guard collapsed.count > maxPreviewLength, let firstMatch = fullRanges.first else {
            return (collapsed, fullRanges)
        }

        let totalCount = collapsed.count
        let desiredStart = max(0, firstMatch.start - leadingContextLength)
        let windowBudget = maxPreviewLength - (desiredStart > 0 ? 1 : 0)
        var startOffset = desiredStart
        var endOffset = min(totalCount, startOffset + windowBudget)
        if endOffset == totalCount {
            startOffset = max(0, totalCount - windowBudget)
        }

        // Snap start forward to a word boundary if it doesn't push past the match.
        if startOffset > 0 {
            let candidateStartIdx = collapsed.index(collapsed.startIndex, offsetBy: startOffset)
            let matchStartIdx = collapsed.index(collapsed.startIndex, offsetBy: firstMatch.start)
            if candidateStartIdx < matchStartIdx,
               let spaceIdx = collapsed[candidateStartIdx..<matchStartIdx].firstIndex(of: " ") {
                let afterSpace = collapsed.index(after: spaceIdx)
                let snappedOffset = collapsed.distance(from: collapsed.startIndex, to: afterSpace)
                if snappedOffset <= firstMatch.start {
                    startOffset = snappedOffset
                }
            }
        }

        let hasLeadingEllipsis = startOffset > 0
        let remainingBudget = maxPreviewLength - (hasLeadingEllipsis ? 1 : 0)
        endOffset = min(totalCount, startOffset + remainingBudget)
        let hasTrailingEllipsis = endOffset < totalCount
        if hasTrailingEllipsis {
            endOffset = min(totalCount, startOffset + max(1, remainingBudget - 1))
            let endIdx = collapsed.index(collapsed.startIndex, offsetBy: endOffset)
            let minEndIdx = collapsed.index(collapsed.startIndex, offsetBy: min(totalCount, firstMatch.end))
            if minEndIdx < endIdx,
               let lastSpace = collapsed[minEndIdx..<endIdx].lastIndex(of: " ") {
                endOffset = collapsed.distance(from: collapsed.startIndex, to: lastSpace)
            }
        }

        let sliceStart = collapsed.index(collapsed.startIndex, offsetBy: startOffset)
        let sliceEnd = collapsed.index(collapsed.startIndex, offsetBy: endOffset)
        var snippet = String(collapsed[sliceStart..<sliceEnd]).trimmingCharacters(in: .whitespaces)
        if hasLeadingEllipsis { snippet = "…" + snippet }
        if hasTrailingEllipsis { snippet += "…" }

        return (snippet, matchRanges(in: snippet, terms: terms))
    }

    private static func matchRanges(in text: String, terms: [String]) -> [HistoryMatchRange] {
        guard !text.isEmpty, !terms.isEmpty else { return [] }
        var found = [HistoryMatchRange]()
        for term in terms {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: term, options: .caseInsensitive, range: searchStart..<text.endIndex) {
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                let end = text.distance(from: text.startIndex, to: range.upperBound)
                if end > start {
                    found.append(HistoryMatchRange(start: start, end: end))
                }
                searchStart = range.upperBound
            }
        }
        guard !found.isEmpty else { return [] }
        found.sort { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.end < rhs.end
        }
        var merged = [HistoryMatchRange]()
        for range in found {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1].end = max(last.end, range.end)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
