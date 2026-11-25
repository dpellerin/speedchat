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

public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var updatedAt: String
    public var preview: String
    public var model: String
    public var messageCount: Int

    public init(
        id: String,
        title: String,
        updatedAt: String,
        preview: String,
        model: String,
        messageCount: Int
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.preview = preview
        self.model = model
        self.messageCount = messageCount
    }
}

public enum ConversationHistory {
    private static let maxPreviewLength = 160

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

    /// Single-line preview derived strictly from visible message text (never private Beam reasoning).
    public static func latestMessagePreview(from messages: [ChatMessage]) -> String {
        let candidate = messages.reversed().first {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.text ?? ""
        let collapsed = candidate
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxPreviewLength else { return collapsed }
        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: maxPreviewLength - 1)
        let sliced = String(collapsed[..<cutoff]).replacingOccurrences(
            of: #"\s+\S*$"#,
            with: "",
            options: .regularExpression
        )
        return (sliced.isEmpty ? String(collapsed[..<cutoff]) : sliced) + "…"
    }
}
