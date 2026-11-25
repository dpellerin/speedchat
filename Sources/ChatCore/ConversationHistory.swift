import Foundation

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
