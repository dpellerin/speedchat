import Foundation

public struct PersistedState: Codable, Equatable, Sendable {
    public static let currentVersion = 3

    public var version: Int
    public var threadId: String
    public var model: String
    public var updatedAt: String
    public var messages: [ChatMessage]?
    public var codexSyncedCount: Int?

    public init(
        version: Int = Self.currentVersion,
        threadId: String,
        model: String,
        updatedAt: String,
        messages: [ChatMessage]? = nil,
        codexSyncedCount: Int? = nil
    ) {
        self.version = version
        self.threadId = threadId
        self.model = model
        self.updatedAt = updatedAt
        self.messages = messages
        self.codexSyncedCount = codexSyncedCount
    }
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

    public static func load(from url: URL? = nil, env: [String: String] = ProcessInfo.processInfo.environment) -> PersistedState? {
        let target = url ?? stateURL(env: env)
        guard let data = try? Data(contentsOf: target),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = raw["version"] as? Int, version == PersistedState.currentVersion,
              let threadId = raw["threadId"] as? String, !threadId.isEmpty,
              let model = raw["model"] as? String, !model.isEmpty,
              let updatedAt = raw["updatedAt"] as? String else {
            return nil
        }

        var validMessages: [ChatMessage]? = nil
        if let rawMessages = raw["messages"] as? [[String: Any]] {
            validMessages = rawMessages.compactMap { item in
                guard let id = item["id"] as? String,
                      let role = item["role"] as? String, (role == "user" || role == "assistant"),
                      let text = item["text"] as? String else {
                    return nil
                }
                return ChatMessage(id: id, role: role, text: text)
            }
        }
        let codexSyncedCount = raw["codexSyncedCount"] as? Int
        return PersistedState(
            version: PersistedState.currentVersion,
            threadId: threadId,
            model: model,
            updatedAt: updatedAt,
            messages: validMessages,
            codexSyncedCount: codexSyncedCount
        )
    }

    public static func save(
        threadId: String,
        model: String,
        to url: URL? = nil,
        messages: [ChatMessage]? = nil,
        codexSyncedCount: Int? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let target = url ?? stateURL(env: env)
        let dir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        let payload = PersistedState(
            version: PersistedState.currentVersion,
            threadId: threadId,
            model: model,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            messages: messages,
            codexSyncedCount: codexSyncedCount
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(payload)
        data.append(10)
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    public static func messagesFromTurns(_ turns: [[String: Any]]) -> [ChatMessage] {
        var result = [ChatMessage]()
        for turn in turns {
            let items = (turn["items"] as? [[String: Any]]) ?? []
            let sources = items.flatMap { item -> [CitationSource] in
                guard (item["type"] as? String) == "webSearch" else { return [] }
                return RenderNormalizer.citationSources(from: item["results"])
            }
            for item in items {
                guard let id = item["id"] as? String, let type = item["type"] as? String else { continue }
                if type == "userMessage" {
                    let parts = (item["content"] as? [[String: Any]]) ?? []
                    let text = parts.compactMap { part -> String? in
                        guard (part["type"] as? String) == "text" else { return nil }
                        return part["text"] as? String
                    }.joined(separator: "\n")
                    if !text.isEmpty {
                        result.append(ChatMessage(id: id, role: "user", text: text))
                    }
                } else if type == "agentMessage" {
                    let phase = item["phase"] as? String
                    let text = item["text"] as? String ?? ""
                    if phase != "commentary" && !text.isEmpty {
                        result.append(ChatMessage(id: id, role: "assistant", text: RenderNormalizer.normalizeAssistantText(text, sources: sources)))
                    }
                }
            }
        }
        return result
    }

    public static func friendlyError(_ error: Error) -> String {
        friendlyErrorMessage(error.localizedDescription)
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
