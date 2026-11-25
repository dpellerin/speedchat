import Foundation

public struct SavedConversation: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var createdAt: String
    public var updatedAt: String
    public var model: String
    public var threadId: String
    public var messages: [ChatMessage]
    public var codexSyncedCount: Int
    var lastCodexSend: CodexSendAttempt?

    public init(
        id: String,
        title: String,
        createdAt: String,
        updatedAt: String,
        model: String,
        threadId: String,
        messages: [ChatMessage],
        codexSyncedCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.threadId = threadId
        self.messages = messages
        self.codexSyncedCount = codexSyncedCount
    }
}

public struct PersistedState: Codable, Equatable, Sendable {
    public static let currentVersion = 4
    static let legacyVersion = 3

    public var version: Int
    public var conversationId: String?
    public var title: String?
    public var createdAt: String?
    public var threadId: String
    public var model: String
    public var updatedAt: String
    public var messages: [ChatMessage]?
    public var codexSyncedCount: Int?
    var lastCodexSend: CodexSendAttempt?

    public init(
        version: Int = Self.currentVersion,
        conversationId: String? = nil,
        title: String? = nil,
        createdAt: String? = nil,
        threadId: String,
        model: String,
        updatedAt: String,
        messages: [ChatMessage]? = nil,
        codexSyncedCount: Int? = nil
    ) {
        self.version = version
        self.conversationId = conversationId
        self.title = title
        self.createdAt = createdAt
        self.threadId = threadId
        self.model = model
        self.updatedAt = updatedAt
        self.messages = messages
        self.codexSyncedCount = codexSyncedCount
    }
}

private struct ActiveStateRecord: Codable {
    var version: Int
    var activeConversationId: String?
    var threadId: String
    var model: String
    var updatedAt: String
    var needsLegacyHistory: Bool?
}

public enum StateStore {
    public static func stateDirectory(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = env["SPEEDCHAT_STATE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SpeedChat")
    }

    public static func stateURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        stateDirectory(env: env).appendingPathComponent("state.json")
    }

    public static func conversationsDirectory(
        stateURL url: URL? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let target = url ?? stateURL(env: env)
        return target.deletingLastPathComponent().appendingPathComponent("conversations", isDirectory: true)
    }

    static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    static func derivedTitle(from messages: [ChatMessage]) -> String {
        if let firstUser = messages.first(where: { $0.role == "user" }) {
            return ChatClient.conversationTitle(firstUser.text)
        }
        return "New chat"
    }

    private static func isValidConversationId(_ id: String) -> Bool {
        !id.isEmpty && !id.contains("/") && !id.contains("\\") && !id.hasPrefix(".") && id != ".."
    }

    private static func conversationURL(id: String, stateURL target: URL) -> URL? {
        guard isValidConversationId(id) else { return nil }
        return conversationsDirectory(stateURL: target).appendingPathComponent("\(id).json")
    }

    private static func parseMessages(_ rawMessages: [[String: Any]]) -> [ChatMessage] {
        rawMessages.compactMap { item in
            guard let id = item["id"] as? String,
                  let role = item["role"] as? String, (role == "user" || role == "assistant"),
                  let text = item["text"] as? String else {
                return nil
            }
            return ChatMessage(id: id, role: role, text: text, reasoning: role == "assistant" ? item["reasoning"] as? String : nil)
        }
    }

    private static func decodeLastCodexSend(from raw: [String: Any]) -> CodexSendAttempt? {
        guard let attempt = raw["lastCodexSend"], JSONSerialization.isValidJSONObject(attempt),
              let data = try? JSONSerialization.data(withJSONObject: attempt) else {
            return nil
        }
        return try? JSONDecoder().decode(CodexSendAttempt.self, from: data)
    }

    private static func decodeConversation(from url: URL) -> SavedConversation? {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = raw["id"] as? String, isValidConversationId(id),
              let threadId = raw["threadId"] as? String, !threadId.isEmpty,
              let model = raw["model"] as? String, !model.isEmpty,
              let updatedAt = raw["updatedAt"] as? String, !updatedAt.isEmpty,
              let rawMessages = raw["messages"] as? [[String: Any]] else {
            return nil
        }
        let messages = parseMessages(rawMessages)
        guard !messages.isEmpty else { return nil }
        let rawTitle = (raw["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = rawTitle.isEmpty ? derivedTitle(from: messages) : rawTitle
        let createdAt = (raw["createdAt"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? updatedAt
        let syncedCount = min(max((raw["codexSyncedCount"] as? Int) ?? 0, 0), messages.count)
        var saved = SavedConversation(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            model: model,
            threadId: threadId,
            messages: messages,
            codexSyncedCount: syncedCount
        )
        saved.lastCodexSend = decodeLastCodexSend(from: raw)
        return saved
    }

    private static func persistedState(from saved: SavedConversation) -> PersistedState {
        var state = PersistedState(
            version: PersistedState.currentVersion,
            conversationId: saved.id,
            title: saved.title,
            createdAt: saved.createdAt,
            threadId: saved.threadId,
            model: saved.model,
            updatedAt: saved.updatedAt,
            messages: saved.messages,
            codexSyncedCount: saved.codexSyncedCount
        )
        state.lastCodexSend = saved.lastCodexSend
        return state
    }

    public static func loadConversation(
        id: String,
        stateURL url: URL? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> SavedConversation? {
        let target = url ?? stateURL(env: env)
        _ = migrateLegacyIfNeeded(target: target)
        guard let fileURL = conversationURL(id: id, stateURL: target) else { return nil }
        return decodeConversation(from: fileURL)
    }

    public static func loadConversations(
        stateURL url: URL? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> [SavedConversation] {
        let target = url ?? stateURL(env: env)
        _ = migrateLegacyIfNeeded(target: target)
        let dir = conversationsDirectory(stateURL: target)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let records = entries
            .filter { $0.pathExtension == "json" }
            .compactMap { decodeConversation(from: $0) }
        return records.sorted { lhs, rhs in
            let lDate = parseTimestamp(lhs.updatedAt) ?? .distantPast
            let rDate = parseTimestamp(rhs.updatedAt) ?? .distantPast
            if lDate != rDate { return lDate > rDate }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }

    @discardableResult
    private static func migrateLegacyIfNeeded(target: URL) -> PersistedState? {
        guard let data = try? Data(contentsOf: target),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = raw["version"] as? Int, version == PersistedState.legacyVersion else {
            return nil
        }
        return migrateLegacyV3(raw: raw, target: target)
    }

    private static func migrateLegacyV3(raw: [String: Any], target: URL) -> PersistedState? {
        guard let threadId = raw["threadId"] as? String, !threadId.isEmpty,
              let model = raw["model"] as? String, !model.isEmpty,
              let updatedAt = raw["updatedAt"] as? String, !updatedAt.isEmpty else {
            return nil
        }
        let codexSyncedCount = raw["codexSyncedCount"] as? Int
        let lastCodexSend = decodeLastCodexSend(from: raw)
        if let rawMessages = raw["messages"] as? [[String: Any]] {
            let validMessages = parseMessages(rawMessages)
            if validMessages.isEmpty {
                try? saveBlankActiveState(
                    threadId: "",
                    model: model,
                    updatedAt: updatedAt,
                    needsLegacyHistory: false,
                    to: target
                )
                return PersistedState(
                    version: PersistedState.currentVersion,
                    conversationId: nil,
                    threadId: "",
                    model: model,
                    updatedAt: updatedAt,
                    messages: [],
                    codexSyncedCount: 0
                )
            }
            let id = UUID().uuidString.lowercased()
            var record = SavedConversation(
                id: id,
                title: derivedTitle(from: validMessages),
                createdAt: updatedAt,
                updatedAt: updatedAt,
                model: model,
                threadId: threadId,
                messages: validMessages,
                codexSyncedCount: min(max(codexSyncedCount ?? 0, 0), validMessages.count)
            )
            record.lastCodexSend = lastCodexSend
            try? saveActiveConversation(record, to: target)
            return persistedState(from: record)
        }

        // Legacy pre-ADR-0001 v3 state without saved messages: preserve threadId for one-time Codex backfill.
        try? saveBlankActiveState(
            threadId: threadId,
            model: model,
            updatedAt: updatedAt,
            needsLegacyHistory: true,
            to: target
        )
        var state = PersistedState(
            version: PersistedState.currentVersion,
            conversationId: nil,
            threadId: threadId,
            model: model,
            updatedAt: updatedAt,
            messages: nil,
            codexSyncedCount: codexSyncedCount
        )
        state.lastCodexSend = lastCodexSend
        return state
    }

    public static func load(from url: URL? = nil, env: [String: String] = ProcessInfo.processInfo.environment) -> PersistedState? {
        let target = url ?? stateURL(env: env)
        guard let data = try? Data(contentsOf: target),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = raw["version"] as? Int else {
            return nil
        }

        if version == PersistedState.legacyVersion {
            return migrateLegacyV3(raw: raw, target: target)
        }

        guard version == PersistedState.currentVersion,
              let model = raw["model"] as? String, !model.isEmpty,
              let updatedAt = raw["updatedAt"] as? String, !updatedAt.isEmpty else {
            return nil
        }

        if let activeId = raw["activeConversationId"] as? String, isValidConversationId(activeId) {
            if let fileURL = conversationURL(id: activeId, stateURL: target),
               let saved = decodeConversation(from: fileURL) {
                return persistedState(from: saved)
            }
            return PersistedState(
                version: PersistedState.currentVersion,
                conversationId: nil,
                threadId: "",
                model: model,
                updatedAt: updatedAt,
                messages: [],
                codexSyncedCount: 0
            )
        }

        let threadId = (raw["threadId"] as? String) ?? ""
        let needsLegacy = (raw["needsLegacyHistory"] as? Bool) == true
        if needsLegacy && threadId.isEmpty { return nil }
        return PersistedState(
            version: PersistedState.currentVersion,
            conversationId: nil,
            threadId: threadId,
            model: model,
            updatedAt: updatedAt,
            messages: needsLegacy ? nil : [],
            codexSyncedCount: needsLegacy ? nil : 0
        )
    }

    private static func ensurePrivateDirectory(_ dir: URL) throws {
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(value)
        data.append(10)
        return data
    }

    private static func writeStagedTempFile(_ data: Data, in directory: URL) throws -> URL {
        let tempURL = directory.appendingPathComponent(".tmp-\(UUID().uuidString.lowercased())")
        guard FileManager.default.createFile(
            atPath: tempURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            let code = errno != 0 ? errno : EIO
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        return tempURL
    }

    private static func replaceFile(at destination: URL, withTemp tempURL: URL) throws {
        if Darwin.rename(tempURL.path, destination.path) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func writePrivateFile(_ data: Data, to target: URL) throws {
        let dir = target.deletingLastPathComponent()
        try ensurePrivateDirectory(dir)
        let tempURL = try writeStagedTempFile(data, in: dir)
        var committed = false
        defer {
            if !committed { try? FileManager.default.removeItem(at: tempURL) }
        }
        try replaceFile(at: target, withTemp: tempURL)
        committed = true
    }

    static func saveActiveConversation(_ record: SavedConversation, to target: URL) throws {
        guard let destURL = conversationURL(id: record.id, stateURL: target) else {
            throw NSError(domain: "SpeedChat.Persistence", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid conversation identifier.",
            ])
        }
        let stateDir = target.deletingLastPathComponent()
        let conversationsDir = conversationsDirectory(stateURL: target)
        try ensurePrivateDirectory(stateDir)
        try ensurePrivateDirectory(conversationsDir)

        let conversationData = try encodeJSON(record)
        let activeState = ActiveStateRecord(
            version: PersistedState.currentVersion,
            activeConversationId: record.id,
            threadId: record.threadId,
            model: record.model,
            updatedAt: record.updatedAt,
            needsLegacyHistory: nil
        )
        let activeData = try encodeJSON(activeState)

        // Stage conversation file first, then commit state.json before replacing the
        // saved conversation so a failed state.json write never mutates the last
        // readable conversation journal on disk.
        let convTempURL = try writeStagedTempFile(conversationData, in: conversationsDir)
        var convCommitted = false
        defer {
            if !convCommitted { try? FileManager.default.removeItem(at: convTempURL) }
        }
        try writePrivateFile(activeData, to: target)
        try replaceFile(at: destURL, withTemp: convTempURL)
        convCommitted = true
    }

    static func saveBlankActiveState(
        threadId: String,
        model: String,
        updatedAt: String,
        needsLegacyHistory: Bool,
        to target: URL
    ) throws {
        let activeState = ActiveStateRecord(
            version: PersistedState.currentVersion,
            activeConversationId: nil,
            threadId: threadId,
            model: model,
            updatedAt: updatedAt,
            needsLegacyHistory: needsLegacyHistory ? true : nil
        )
        let activeData = try encodeJSON(activeState)
        try writePrivateFile(activeData, to: target)
    }

    public static func save(
        threadId: String,
        model: String,
        to url: URL? = nil,
        messages: [ChatMessage]? = nil,
        codexSyncedCount: Int? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        try save(threadId: threadId, model: model, to: url, messages: messages,
                 codexSyncedCount: codexSyncedCount, lastCodexSend: nil, env: env)
    }

    static func save(
        threadId: String,
        model: String,
        to url: URL?,
        messages: [ChatMessage]?,
        codexSyncedCount: Int?,
        lastCodexSend: CodexSendAttempt?,
        env: [String: String]
    ) throws {
        let target = url ?? stateURL(env: env)
        let now = formatTimestamp(Date())
        if let messages, !messages.isEmpty {
            let id = UUID().uuidString.lowercased()
            var record = SavedConversation(
                id: id,
                title: derivedTitle(from: messages),
                createdAt: now,
                updatedAt: now,
                model: model,
                threadId: threadId,
                messages: messages,
                codexSyncedCount: min(max(codexSyncedCount ?? 0, 0), messages.count)
            )
            record.lastCodexSend = lastCodexSend
            try saveActiveConversation(record, to: target)
        } else {
            try saveBlankActiveState(
                threadId: threadId,
                model: model,
                updatedAt: now,
                needsLegacyHistory: messages == nil,
                to: target
            )
        }
    }

    public static func messagesFromTurns(_ turns: [[String: Any]]) -> [ChatMessage] {
        CodexHistory(turns: turns).legacyMessages
    }

    public static func friendlyError(_ error: Error) -> String {
        if let providerError = error as? OpenRouterHTTPError { return providerError.message }
        return friendlyErrorMessage(error.localizedDescription)
    }

    public static func friendlyErrorMessage(_ raw: String) -> String {
        if raw.range(of: #"unauthorized|not logged in|authentication"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return "OpenAI sign-in is required. Run `codex login` in a regular terminal, then reopen this popup."
        }
        if raw.range(of: #"usageLimitExceeded|rate.?limit|quota|usage limit"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return "Your Codex usage limit has been reached. Try again after the allowance resets."
        }
        if raw.range(of: #"ENOENT.*codex|spawn codex ENOENT|codex executable was not found"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return "Codex is not installed or is not on PATH. Install Codex, then reconnect."
        }
        if raw.range(of: #"model.*unavailable"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return "That model is not available to this account. Choose another model or update Codex."
        }
        let cleaned = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Something went wrong." : cleaned
    }
}
