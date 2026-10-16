import Foundation

public struct OpenRouterConfig: Equatable, Sendable {
    public var key: String
    public var models: [ChatModel]

    public init(key: String = "", models: [ChatModel] = OpenRouterClient.defaultModels) {
        self.key = key
        self.models = models
    }
}

public struct OpenRouterHTTPResponse: Sendable {
    public var statusCode: Int
    public var lines: AsyncThrowingStream<String, Error>
    public var errorBody: String

    public init(statusCode: Int, lines: AsyncThrowingStream<String, Error>, errorBody: String = "") {
        self.statusCode = statusCode
        self.lines = lines
        self.errorBody = errorBody
    }
}

public typealias OpenRouterFetch = @Sendable (URLRequest) async throws -> OpenRouterHTTPResponse

public struct OpenRouterStreamOptions: Sendable {
    public var key: String
    public var model: String
    public var instructions: String
    public var messages: [ChatMessage]
    public var onDelta: @Sendable (String) -> Void
    public var onSearching: @Sendable () -> Void
    public var onCitation: (@Sendable (CitationSource) -> Void)?
    public var fetch: OpenRouterFetch?

    public init(
        key: String,
        model: String,
        instructions: String,
        messages: [ChatMessage],
        onDelta: @escaping @Sendable (String) -> Void,
        onSearching: @escaping @Sendable () -> Void,
        onCitation: (@Sendable (CitationSource) -> Void)? = nil,
        fetch: OpenRouterFetch? = nil
    ) {
        self.key = key
        self.model = model
        self.instructions = instructions
        self.messages = messages
        self.onDelta = onDelta
        self.onSearching = onSearching
        self.onCitation = onCitation
        self.fetch = fetch
    }
}

public struct OpenRouterHTTPError: Error, LocalizedError, Sendable {
    public var status: Int
    public var rawBody: String
    public var message: String

    public var errorDescription: String? { message }
}

public enum OpenRouterClient {
    public static let apiURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    public static let defaultModels: [ChatModel] = [
        ChatModel(model: "deepseek/deepseek-v4.1-flash", displayName: "DeepSeek V4.1 Flash", provider: "openrouter"),
        ChatModel(model: "mistralai/mistral-large-4-0", displayName: "Mistral Large 4", provider: "openrouter"),
        ChatModel(model: "qwen/qwen3.8-flash", displayName: "Qwen 3.8 Flash", provider: "openrouter"),
        ChatModel(model: "moonshotai/kimi-k3", displayName: "Kimi K3", provider: "openrouter"),
        ChatModel(model: "z-ai/glm-5.3-flashx", displayName: "GLM 5.3 FlashX", provider: "openrouter"),
        ChatModel(model: "google/gemma-4-26b-a4b-it", displayName: "Gemma 4 26B A4B", provider: "openrouter"),
        ChatModel(model: "deepseek/deepseek-v4-pro-0813", displayName: "DeepSeek V4 Pro", provider: "openrouter"),
    ]

    public static func configURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        StateStore.stateDirectory(env: env).appendingPathComponent("openrouter.json")
    }

    public static func formatModelDisplayName(_ slug: String) -> String {
        if let preset = defaultModels.first(where: { $0.model.lowercased() == slug.lowercased() }) {
            return preset.displayName
        }
        let rawName: String
        if let slash = slug.firstIndex(of: "/") {
            rawName = String(slug[slug.index(after: slash)...])
        } else {
            rawName = slug
        }
        let replaced = rawName.replacingOccurrences(of: #":free$"#, with: " (Free)", options: [.regularExpression, .caseInsensitive])
        let parts = replaced.components(separatedBy: CharacterSet(charactersIn: "-_")).filter { !$0.isEmpty }
        let formatted = parts.map { word -> String in
            if word.range(of: #"^v?\d+(\.\d+)*[a-z]*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return word.uppercased()
            }
            if word.range(of: #"^(vl|it|moe|glm|llm|ai)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return word.uppercased()
            }
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        return formatted.joined(separator: " ")
    }

    public static func parseModels(_ input: Any?) -> [ChatModel] {
        guard let input else { return defaultModels }
        var entries = [ChatModel]()
        var seen = Set<String>()

        func addEntry(_ rawSlug: String, _ rawName: String?) {
            let model = rawSlug.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, !seen.contains(model) else { return }
            seen.insert(model)
            let trimmedName = (rawName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = trimmedName.isEmpty ? formatModelDisplayName(model) : trimmedName
            entries.append(ChatModel(model: model, displayName: displayName, provider: "openrouter"))
        }

        if let list = input as? [Any] {
            for item in list {
                if let str = item as? String {
                    let parts = str.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    addEntry(parts.first ?? "", parts.count > 1 ? parts[1] : nil)
                } else if let modelObj = item as? ChatModel {
                    addEntry(modelObj.model, modelObj.displayName)
                } else if let dict = item as? [String: Any], let m = dict["model"] as? String {
                    addEntry(m, dict["displayName"] as? String)
                }
            }
        } else if let str = input as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return defaultModels }
            if trimmed.hasPrefix("["),
               let data = trimmed.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                return parseModels(parsed)
            }
            for line in trimmed.components(separatedBy: CharacterSet(charactersIn: "\r\n,")) {
                let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                let parts = cleaned.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                addEntry(parts.first ?? "", parts.count > 1 ? parts[1] : nil)
            }
        }

        return entries.isEmpty ? defaultModels : entries
    }

    public static func loadConfig(
        from url: URL? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> OpenRouterConfig {
        let target = url ?? configURL(env: env)
        let envKey = (env["SPEEDCHAT_OPENROUTER_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let envModels = env["SPEEDCHAT_OPENROUTER_MODELS"]

        if let data = try? Data(contentsOf: target),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let fileKey = (raw["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolvedKey = envKey.isEmpty ? fileKey : envKey
            let rawModels: Any? = envModels != nil ? envModels : raw["models"]
            return OpenRouterConfig(key: resolvedKey, models: parseModels(rawModels))
        }
        return OpenRouterConfig(key: envKey, models: parseModels(envModels))
    }

    public static func saveConfig(
        key: String,
        models: [ChatModel]? = nil,
        to url: URL? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let target = url ?? configURL(env: env)
        let dir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        let normalized = parseModels(models).map { ["model": $0.model, "displayName": $0.displayName] }
        let payload: [String: Any] = [
            "apiKey": key.trimmingCharacters(in: .whitespacesAndNewlines),
            "models": normalized,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        var data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        data.append(10)
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    private static func webSearchTool() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "web_search",
                "description": "Search the live web when the user asks to search or when current, recent, or uncertain facts would improve the answer.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Focused web search query.",
                        ],
                    ],
                    "required": ["query"],
                ],
            ],
        ]
    }

    public static func extractError(status: Int, bodyText: String) -> OpenRouterHTTPError {
        var detail = ""
        if let data = bodyText.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = parsed["error"] as? [String: Any],
           let msg = err["message"] as? String {
            detail = msg
        } else {
            detail = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let message: String
        if status == 401 || status == 403 || detail.range(of: #"invalid.*key|unauthorized|auth"#, options: [.regularExpression, .caseInsensitive]) != nil {
            message = "OpenRouter API key is missing or invalid. Check your key in SpeedChat Settings."
        } else if status == 402 || detail.range(of: #"insufficient.*credit|balance"#, options: [.regularExpression, .caseInsensitive]) != nil {
            message = "Your OpenRouter account is out of credits. Top up at openrouter.ai and try again."
        } else if status == 429 || detail.range(of: #"rate.?limit"#, options: [.regularExpression, .caseInsensitive]) != nil {
            message = "OpenRouter rate limit reached. Wait a moment or try another model."
        } else {
            message = detail.isEmpty ? "OpenRouter request failed (HTTP \(status))." : detail
        }
        return OpenRouterHTTPError(status: status, rawBody: bodyText, message: message)
    }

    public static let liveFetch: OpenRouterFetch = { request in
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        if !(200..<300).contains(status) {
            var errorBytes = Data()
            for try await b in bytes {
                errorBytes.append(b)
                if errorBytes.count > 16_384 { break }
            }
            let text = String(data: errorBytes, encoding: .utf8) ?? ""
            return OpenRouterHTTPResponse(
                statusCode: status,
                lines: AsyncThrowingStream { $0.finish() },
                errorBody: text
            )
        }
        let lineStream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return OpenRouterHTTPResponse(statusCode: status, lines: lineStream)
    }

    private struct ToolCallAccumulator {
        var id: String
        var name: String
        var argumentsText: String
    }

    private struct SingleStreamResult {
        var content: String
        var toolCalls: [ToolCallAccumulator]
        var citations: [(url: String, title: String)]
    }

    private static func runSingleStream(
        options: OpenRouterStreamOptions,
        extraBody: [String: Any],
        emitContentDeltas: Bool
    ) async throws -> SingleStreamResult {
        let fetchFn = options.fetch ?? liveFetch
        var apiMessages: [[String: String]] = [
            ["role": "system", "content": options.instructions]
        ]
        for msg in options.messages {
            apiMessages.append(["role": msg.role, "content": msg.text])
        }

        var body: [String: Any] = [
            "model": options.model,
            "messages": apiMessages,
            "stream": true,
            "reasoning": ["effort": "low", "exclude": true],
        ]
        for (k, v) in extraBody {
            body[k] = v
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(options.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/dpellerin/speedchat", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("SpeedChat", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let response = try await fetchFn(request)
        if !(200..<300).contains(response.statusCode) {
            throw extractError(status: response.statusCode, bodyText: response.errorBody)
        }

        var content = ""
        var toolCalls = [Int: ToolCallAccumulator]()
        var toolCallOrder = [Int]()
        var citations = [(url: String, title: String)]()
        var seenUrls = Set<String>()

        func recordAnnotations(_ annotations: Any?) {
            guard let list = annotations as? [Any] else { return }
            for entry in list {
                guard let record = entry as? [String: Any] else { continue }
                let citation = (record["url_citation"] as? [String: Any]) ?? record
                let url = (citation["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard url.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil,
                      !seenUrls.contains(url) else { continue }
                seenUrls.insert(url)
                let rawTitle = (citation["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let hostFallback = URL(string: url)?.host?.replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression) ?? "source"
                let title = rawTitle.isEmpty ? hostFallback : rawTitle
                citations.append((url: url, title: title))
                options.onCitation?(CitationSource(refId: "or-\(citations.count)", url: url, title: title))
            }
        }

        func processLine(_ rawLine: String) throws {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix(":"), line.hasPrefix("data:") else { return }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            if let errorDict = parsed["error"] as? [String: Any],
               let message = errorDict["message"] as? String, !message.isEmpty {
                throw OpenRouterHTTPError(status: 500, rawBody: payload, message: message)
            }
            guard let choices = parsed["choices"] as? [[String: Any]],
                  let choice = choices.first else { return }
            let delta = choice["delta"] as? [String: Any]
            let message = choice["message"] as? [String: Any]
            recordAnnotations(delta?["annotations"])
            recordAnnotations(message?["annotations"])

            if let calls = delta?["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    let idx = (call["index"] as? Int) ?? 0
                    var current = toolCalls[idx] ?? ToolCallAccumulator(id: (call["id"] as? String) ?? "call_\(idx)", name: "", argumentsText: "")
                    if toolCalls[idx] == nil { toolCallOrder.append(idx) }
                    if let id = call["id"] as? String, !id.isEmpty { current.id = id }
                    if let fn = call["function"] as? [String: Any] {
                        if let name = fn["name"] as? String { current.name += name }
                        if let args = fn["arguments"] as? String { current.argumentsText += args }
                    }
                    toolCalls[idx] = current
                }
            }

            if let deltaText = delta?["content"] as? String, !deltaText.isEmpty {
                content += deltaText
                if emitContentDeltas && toolCalls.isEmpty {
                    options.onDelta(deltaText)
                }
            }
        }

        for try await line in response.lines {
            try Task.checkCancellation()
            try processLine(line)
        }

        let orderedCalls = toolCallOrder.compactMap { toolCalls[$0] }
        return SingleStreamResult(content: content, toolCalls: orderedCalls, citations: citations)
    }

    public static func streamTurn(_ options: OpenRouterStreamOptions) async throws -> String {
        let firstPass: SingleStreamResult
        do {
            firstPass = try await runSingleStream(
                options: options,
                extraBody: ["tools": [webSearchTool()], "tool_choice": "auto"],
                emitContentDeltas: true
            )
        } catch let error as OpenRouterHTTPError {
            let isToolRejection = error.status == 400 || (error.rawBody.range(of: #"tool|function"#, options: [.regularExpression, .caseInsensitive]) != nil && ![401, 402, 429].contains(error.status))
            if isToolRejection {
                firstPass = try await runSingleStream(options: options, extraBody: [:], emitContentDeltas: true)
            } else {
                throw error
            }
        }

        guard let searchCall = firstPass.toolCalls.first(where: { $0.name == "web_search" }) else {
            return appendMissingCitations(firstPass.content, citations: firstPass.citations)
        }

        var query = ""
        if let argsData = searchCall.argumentsText.data(using: .utf8),
           let parsedArgs = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any],
           let q = parsedArgs["query"] as? String {
            query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        options.onSearching()

        var secondOptions = options
        if !query.isEmpty {
            secondOptions.instructions = "\(options.instructions)\n\nThe user's question requires current web information (search focus: \"\(query)\"). Use the provided web search results and cite sources with Markdown links."
        }

        let secondPass = try await runSingleStream(
            options: secondOptions,
            extraBody: ["plugins": [["id": "web", "max_results": 5]]],
            emitContentDeltas: true
        )
        return appendMissingCitations(secondPass.content, citations: secondPass.citations)
    }

    private static func appendMissingCitations(_ content: String, citations: [(url: String, title: String)]) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !citations.isEmpty else { return content }
        let unreferenced = citations.filter { !trimmed.contains($0.url) }
        guard !unreferenced.isEmpty else { return content }
        let links = unreferenced.prefix(4).map { item in
            let cleanTitle = item.title.replacingOccurrences(of: #"[\[\]]"#, with: "", options: .regularExpression)
            return "[\(cleanTitle)](\(item.url))"
        }.joined(separator: " · ")
        return "\(content)\n\nSources: \(links)"
    }
}
