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

    mutating func didResume(threadId: String, name: String?, codexMessages: [ChatMessage]) -> Bool {
        thread = .attached(threadId)
        titleNeeded = name == nil || name == "" || name == "SpeedChat" || name == "New chat"
        let shouldImport = needsLegacyHistory && messages.isEmpty
        needsLegacyHistory = false
        guard shouldImport else { return false }
        messages = codexMessages
        codexSyncedCount = codexMessages.count
        return true
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
