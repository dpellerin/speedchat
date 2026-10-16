import Foundation

public struct ReadyState: Equatable, Sendable {
    public var threadId: String
    public var messages: [ChatMessage]
    public var resumed: Bool
    public var model: String
    public var reasoningEffort: String
    public var models: [ChatModel]
    public var openRouterConfigured: Bool

    public init(
        threadId: String,
        messages: [ChatMessage],
        resumed: Bool,
        model: String,
        reasoningEffort: String = ChatPrompt.reasoningEffort,
        models: [ChatModel],
        openRouterConfigured: Bool = false
    ) {
        self.threadId = threadId
        self.messages = messages
        self.resumed = resumed
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.models = models
        self.openRouterConfigured = openRouterConfigured
    }
}

public struct ChatClientOptions: Sendable {
    public var openRouterFetch: OpenRouterFetch?
    public var openRouterConfigURL: URL?
    public var stateURL: URL?
    public var env: [String: String]

    public init(
        openRouterFetch: OpenRouterFetch? = nil,
        openRouterConfigURL: URL? = nil,
        stateURL: URL? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.openRouterFetch = openRouterFetch
        self.openRouterConfigURL = openRouterConfigURL
        self.stateURL = stateURL
        self.env = env
    }
}

public final class ChatClient: @unchecked Sendable {
    private static let toolItemTypes: Set<String> = [
        "commandExecution",
        "fileChange",
        "mcpToolCall",
        "dynamicToolCall",
        "collabAgentToolCall",
        "imageView",
        "imageGeneration",
    ]

    public static func availableModels(from rawModels: [[String: Any]]) -> [ChatModel] {
        rawModels.compactMap { candidate in
            let hidden = (candidate["hidden"] as? Bool) ?? false
            guard !hidden,
                  let model = candidate["model"] as? String, !model.isEmpty else {
                return nil
            }
            let efforts = (candidate["supportedReasoningEfforts"] as? [[String: Any]]) ?? []
            let supportsLow = efforts.contains { ($0["reasoningEffort"] as? String) == ChatPrompt.reasoningEffort }
            guard supportsLow else { return nil }
            let rawDisplay = (candidate["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ChatModel(model: model, displayName: rawDisplay.isEmpty ? model : rawDisplay, provider: "openai")
        }
    }

    public static func defaultModel(from models: [ChatModel]) -> String {
        if let exact = models.first(where: { $0.model == ChatPrompt.defaultOpenAIModel })?.model {
            return exact
        }
        if let luna = models.first(where: { $0.model.range(of: #"(?:^|-)luna(?:$|-)"#, options: [.regularExpression, .caseInsensitive]) != nil })?.model {
            return luna
        }
        return models.first?.model ?? ""
    }

    public static func conversationTitle(_ text: String) -> String {
        var title = text
            .replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[`#*_]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\u0000-\u001f\u007f]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^(?:hey[,!]?\s+|please\s+)?(?:can|could|would) you (?:please )?(?:help me |tell me |explain to me )?"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"^(?:please |help me )"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
        if title.isEmpty { return "New chat" }
        let words = title.split(separator: " ").map(String.init)
        title = words.prefix(10).joined(separator: " ")
        if title.count > 72 {
            let sliced = String(title.prefix(69)).replacingOccurrences(of: #"\s+\S*$"#, with: "", options: .regularExpression)
            title = sliced + "…"
        } else if words.count > 10 {
            title += "…"
        }
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    private let rpc: CodexTransport
    private let options: ChatClientOptions
    private let lock = NSRecursiveLock()

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private var threadId: String?
    private var turnId: String?
    private var turnStarting = false
    private var turnBlocked = false
    private var interruptPending = false
    private var mutationPending = false

    public var busy: Bool {
        sync { turnStarting || turnId != nil || mutationPending }
    }

    private var citationSources = [String: CitationSource]()
    private var citationOrder = [String]()
    private var citationStream = StreamingCitationResolver()
    private var linkStream = StreamingLinkResolver()
    private var runtimeDir: URL?
    private var openAiModels = [ChatModel]()
    private var openRouterConfig = OpenRouterConfig()
    private var codexAvailable = false
    private var models = [ChatModel]()
    private var model = ""
    private var messages = [ChatMessage]()
    private var codexSyncedCount = 0
    private var openRouterTask: Task<Void, Never>?
    private var openRouterTurnToken: UUID?
    private var titleNeeded = true

    public var onDelta: (@Sendable (String, String) -> Void)?
    public var onMessage: (@Sendable (String, String) -> Void)?
    public var onDone: (@Sendable () -> Void)?
    public var onSearching: (@Sendable () -> Void)?
    public var onModel: (@Sendable (String) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?
    public var onFatal: (@Sendable (Error) -> Void)?

    public init(rpc: CodexTransport = JsonRpcProcess(), options: ChatClientOptions = ChatClientOptions()) {
        self.rpc = rpc
        self.options = options
        self.rpc.onNotification = { [weak self] notification in
            self?.handleNotification(notification)
        }
        self.rpc.onExit = { [weak self] in
            self?.handleProcessExit()
        }
    }

    private func orderedCitations() -> [CitationSource] {
        citationOrder.compactMap { citationSources[$0] }
    }

    private func recordCitation(_ source: CitationSource) {
        if citationSources[source.refId] == nil {
            citationOrder.append(source.refId)
        }
        citationSources[source.refId] = source
    }

    private func isOpenRouterModel(_ candidate: String) -> Bool {
        if let found = models.first(where: { $0.model == candidate }), let provider = found.provider {
            return provider == "openrouter"
        }
        return openRouterConfig.models.contains(where: { $0.model == candidate }) || candidate.contains("/")
    }

    private func rebuildModelCatalog() {
        let openRouterModels = !openRouterConfig.key.isEmpty
            ? openRouterConfig.models.map { ChatModel(model: $0.model, displayName: $0.displayName, provider: "openrouter") }
            : []
        models = openAiModels + openRouterModels
    }

    private func handleProcessExit() {
        let handled = sync { () -> Bool in
            if !openRouterConfig.key.isEmpty {
                codexAvailable = false
                openAiModels = []
                rebuildModelCatalog()
                return true
            }
            return false
        }
        if !handled {
            onFatal?(NSError(domain: "SpeedChat.Client", code: 1, userInfo: [NSLocalizedDescriptionKey: "The Codex app-server stopped unexpectedly."]))
        }
    }

    private func nameFromContent(_ text: String) async {
        let currentThread: String? = sync {
            guard let t = threadId, titleNeeded, codexAvailable, !t.hasPrefix("openrouter-") else { return nil }
            return t
        }
        guard let currentThread else { return }
        do {
            _ = try await rpc.request(
                method: "thread/name/set",
                params: ["threadId": currentThread, "name": Self.conversationTitle(text)],
                timeoutMs: 30_000
            )
            sync {
                if threadId == currentThread {
                    titleNeeded = false
                }
            }
        } catch {
            // Naming is optional; retry on the next message without failing chat.
        }
    }

    private func saveCurrentState() {
        guard let currentThread = threadId else { return }
        try? StateStore.save(
            threadId: currentThread,
            model: model,
            to: options.stateURL,
            messages: messages,
            codexSyncedCount: codexSyncedCount,
            env: options.env
        )
    }

    public func connect() async throws -> ReadyState {
        let dir = try RuntimeDiscovery.createRuntimeDirectory()
        let loadedOR = OpenRouterClient.loadConfig(from: options.openRouterConfigURL, env: options.env)

        sync {
            runtimeDir = dir
            openRouterConfig = loadedOR
        }

        var codexError: Error?
        do {
            try await rpc.start(cwd: dir)
            try await loadModels()
            sync { codexAvailable = true }
        } catch {
            codexError = error
            sync {
                codexAvailable = false
                openAiModels = []
            }
        }

        let currentModels: [ChatModel] = sync {
            rebuildModelCatalog()
            return models
        }

        if currentModels.isEmpty {
            if let codexError { throw codexError }
            throw NSError(domain: "SpeedChat.Client", code: 2, userInfo: [NSLocalizedDescriptionKey: "No available models support low reasoning effort."])
        }

        let state = StateStore.load(from: options.stateURL, env: options.env)
        let (isCodexUp, currentModel, currentOpenAiModels) = sync { () -> (Bool, String, [ChatModel]) in
            if let state, models.contains(where: { $0.model == state.model }) {
                model = state.model
            } else {
                model = Self.defaultModel(from: models)
            }
            return (codexAvailable, model, openAiModels)
        }

        if let state {
            if isCodexUp && !state.threadId.hasPrefix("openrouter-") {
                do {
                    let initialCodexModel = sync {
                        isOpenRouterModel(currentModel)
                            ? (Self.defaultModel(from: currentOpenAiModels).isEmpty ? currentModel : Self.defaultModel(from: currentOpenAiModels))
                            : currentModel
                    }
                    let resumed = try await rpc.request(
                        method: "thread/resume",
                        params: [
                            "threadId": state.threadId,
                            "model": initialCodexModel,
                            "personality": ChatPrompt.personality,
                            "cwd": dir.path,
                            "approvalPolicy": "never",
                            "sandbox": "read-only",
                            "baseInstructions": ChatPrompt.instructions,
                            "developerInstructions": ChatPrompt.instructions,
                            "config": ["web_search": "live"],
                            "environments": [],
                            "runtimeWorkspaceRoots": [],
                        ],
                        timeoutMs: 30_000
                    )
                    guard let threadDict = resumed["thread"] as? [String: Any],
                          let resumedThreadId = threadDict["id"] as? String else {
                        throw NSError(domain: "SpeedChat.Client", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid resumed thread."])
                    }
                    let turns = (threadDict["turns"] as? [[String: Any]]) ?? []
                    let codexMessages = StateStore.messagesFromTurns(turns)

                    let (ready, firstPrompt) = sync { () -> (ReadyState, String?) in
                        threadId = resumedThreadId
                        if !isOpenRouterModel(model), let resumedModel = resumed["model"] as? String, !resumedModel.isEmpty {
                            model = resumedModel
                        }
                        if let savedMessages = state.messages, savedMessages.count >= codexMessages.count {
                            messages = savedMessages
                        } else {
                            messages = codexMessages
                        }
                        codexSyncedCount = state.codexSyncedCount ?? codexMessages.count
                        let existingName = threadDict["name"] as? String
                        titleNeeded = existingName == nil || existingName!.isEmpty || existingName == "SpeedChat" || existingName == "New chat"
                        let prompt = messages.first(where: { $0.role == "user" })?.text
                        if state.model != model {
                            saveCurrentState()
                        }
                        let r = ReadyState(
                            threadId: resumedThreadId,
                            messages: messages,
                            resumed: true,
                            model: model,
                            models: models,
                            openRouterConfigured: !openRouterConfig.key.isEmpty
                        )
                        return (r, prompt)
                    }

                    if let firstPrompt {
                        await nameFromContent(firstPrompt)
                    }
                    return ready
                } catch {
                    // A deleted or incompatible thread is safely replaced below.
                }
            } else if let savedMessages = state.messages, !savedMessages.isEmpty {
                return sync {
                    threadId = state.threadId
                    messages = savedMessages
                    codexSyncedCount = state.codexSyncedCount ?? 0
                    titleNeeded = false
                    return ReadyState(
                        threadId: state.threadId,
                        messages: messages,
                        resumed: true,
                        model: model,
                        models: models,
                        openRouterConfigured: !openRouterConfig.key.isEmpty
                    )
                }
            }
        }
        return try await newChat()
    }

    public func reloadOpenRouter() async -> ReadyState {
        let updated = OpenRouterClient.loadConfig(from: options.openRouterConfigURL, env: options.env)
        return sync {
            openRouterConfig = updated
            rebuildModelCatalog()
            if !models.contains(where: { $0.model == model }) {
                model = Self.defaultModel(from: models)
                saveCurrentState()
            }
            return readyStateLocked()
        }
    }

    public func newChat() async throws -> ReadyState {
        let (isCodexUp, codexModel, cwdPath) = try sync { () -> (Bool, String, String) in
            if turnStarting || turnId != nil || mutationPending {
                throw NSError(domain: "SpeedChat.Client", code: 4, userInfo: [NSLocalizedDescriptionKey: "Wait for the current response or change to finish."])
            }
            mutationPending = true
            let resolvedModel = isOpenRouterModel(model)
                ? (Self.defaultModel(from: openAiModels).isEmpty ? model : Self.defaultModel(from: openAiModels))
                : model
            return (codexAvailable, resolvedModel, runtimeDir?.path ?? "")
        }

        defer {
            sync { mutationPending = false }
        }

        if isCodexUp {
            let response = try await rpc.request(
                method: "thread/start",
                params: [
                    "model": codexModel,
                    "personality": ChatPrompt.personality,
                    "cwd": cwdPath,
                    "approvalPolicy": "never",
                    "approvalsReviewer": "user",
                    "sandbox": "read-only",
                    "config": ["web_search": "live"],
                    "baseInstructions": ChatPrompt.instructions,
                    "developerInstructions": ChatPrompt.instructions,
                    "dynamicTools": [],
                    "environments": [],
                    "runtimeWorkspaceRoots": [],
                    "selectedCapabilityRoots": [],
                    "ephemeral": false,
                    "serviceTier": "default",
                ],
                timeoutMs: 30_000
            )
            let threadDict = (response["thread"] as? [String: Any]) ?? [:]
            let startedId = (threadDict["id"] as? String) ?? "codex-\(UUID().uuidString)"
            let respModel = response["model"] as? String
            let ready = sync { () -> ReadyState in
                threadId = startedId
                if !isOpenRouterModel(model), let respModel, !respModel.isEmpty {
                    model = respModel
                }
                turnId = nil
                messages = []
                codexSyncedCount = 0
                titleNeeded = true
                saveCurrentState()
                return ReadyState(
                    threadId: startedId,
                    messages: [],
                    resumed: false,
                    model: model,
                    models: models,
                    openRouterConfigured: !openRouterConfig.key.isEmpty
                )
            }
            _ = try? await rpc.request(method: "thread/name/set", params: ["threadId": startedId, "name": "New chat"], timeoutMs: 30_000)
            return ready
        } else {
            let startedId = "openrouter-\(UUID().uuidString.lowercased())"
            return sync {
                threadId = startedId
                turnId = nil
                messages = []
                codexSyncedCount = 0
                titleNeeded = false
                saveCurrentState()
                return ReadyState(
                    threadId: startedId,
                    messages: [],
                    resumed: false,
                    model: model,
                    models: models,
                    openRouterConfigured: !openRouterConfig.key.isEmpty
                )
            }
        }
    }

    public func selectModel(_ candidate: String) async throws -> ReadyState {
        let (currentThread, shouldUpdateCodex) = try sync { () -> (String, Bool) in
            if turnStarting || turnId != nil || mutationPending {
                throw NSError(domain: "SpeedChat.Client", code: 4, userInfo: [NSLocalizedDescriptionKey: "Wait for the current response or change to finish."])
            }
            guard models.contains(where: { $0.model == candidate }) else {
                throw NSError(domain: "SpeedChat.Client", code: 5, userInfo: [NSLocalizedDescriptionKey: "Selected model is unavailable."])
            }
            guard let t = threadId else {
                throw NSError(domain: "SpeedChat.Client", code: 6, userInfo: [NSLocalizedDescriptionKey: "Chat is not ready."])
            }
            mutationPending = true
            let updateCodex = !isOpenRouterModel(candidate) && codexAvailable && !t.hasPrefix("openrouter-")
            return (t, updateCodex)
        }

        defer {
            sync { mutationPending = false }
        }

        if shouldUpdateCodex {
            _ = try await rpc.request(method: "thread/settings/update", params: ["threadId": currentThread, "model": candidate], timeoutMs: 30_000)
        }
        return sync {
            model = candidate
            saveCurrentState()
            return readyStateLocked()
        }
    }

    private func readyStateLocked() -> ReadyState {
        ReadyState(
            threadId: threadId ?? "",
            messages: messages,
            resumed: true,
            model: model,
            models: models,
            openRouterConfigured: !openRouterConfig.key.isEmpty
        )
    }

    public func send(_ text: String) async throws {
        let (currentThread, currentModel, useOpenRouter, orKey) = try sync { () -> (String, String, Bool, String) in
            if turnStarting || turnId != nil || mutationPending {
                throw NSError(domain: "SpeedChat.Client", code: 4, userInfo: [NSLocalizedDescriptionKey: "Wait for the current response or change to finish."])
            }
            guard let t = threadId else {
                throw NSError(domain: "SpeedChat.Client", code: 6, userInfo: [NSLocalizedDescriptionKey: "Chat is not ready."])
            }
            turnStarting = true
            turnBlocked = false
            interruptPending = false
            citationSources.removeAll()
            citationOrder.removeAll()
            citationStream.reset()
            linkStream.reset()
            return (t, model, isOpenRouterModel(model), openRouterConfig.key)
        }

        onModel?(currentModel)

        if useOpenRouter {
            if orKey.isEmpty {
                sync { turnStarting = false }
                throw NSError(domain: "SpeedChat.Client", code: 7, userInfo: [NSLocalizedDescriptionKey: "OpenRouter API key is required. Add your key in SpeedChat Settings."])
            }
            let userMessage = ChatMessage(id: UUID().uuidString.lowercased(), role: "user", text: text)
            let itemId = "or-msg-\(UUID().uuidString.lowercased())"
            let token = UUID()
            let (snapshotMessages, pendingStop) = sync { () -> ([ChatMessage], Bool) in
                messages.append(userMessage)
                turnId = "or-turn-\(token.uuidString.lowercased())"
                openRouterTurnToken = token
                turnStarting = false
                return (messages, interruptPending)
            }

            if pendingStop {
                await interrupt()
                return
            }

            let task: Task<Void, Never> = Task { [weak self] in
                await self?.runOpenRouterTurn(itemId: itemId, token: token, model: currentModel, key: orKey, messages: snapshotMessages)
            }
            sync { openRouterTask = task }
            await nameFromContent(text)
            return
        }

        do {
            let (inputText, cwdPath) = sync { () -> (String, String) in
                let unsent = Array(messages.dropFirst(codexSyncedCount))
                let formattedInput: String
                if !unsent.isEmpty {
                    let historyText = unsent.map { "\($0.role == "user" ? "User" : "Assistant"): \($0.text)" }.joined(separator: "\n\n")
                    formattedInput = "[Earlier turns in this conversation from another model:\n\(historyText)]\n\n\(text)"
                } else {
                    formattedInput = text
                }
                let userMessage = ChatMessage(id: UUID().uuidString.lowercased(), role: "user", text: text)
                messages.append(userMessage)
                return (formattedInput, runtimeDir?.path ?? "")
            }

            let response = try await rpc.request(
                method: "turn/start",
                params: [
                    "threadId": currentThread,
                    "input": [["type": "text", "text": inputText]],
                    "model": currentModel,
                    "personality": ChatPrompt.personality,
                    "effort": ChatPrompt.reasoningEffort,
                    "serviceTierForTurn": "default",
                    "approvalPolicy": "never",
                    "cwd": cwdPath,
                    "environments": [],
                    "runtimeWorkspaceRoots": [],
                ],
                timeoutMs: 30_000
            )
            let turnDict = (response["turn"] as? [String: Any]) ?? [:]
            let startedTurnId = (turnDict["id"] as? String) ?? "turn"

            let shouldInterrupt = sync { () -> Bool in
                if turnStarting {
                    turnId = startedTurnId
                    return interruptPending
                }
                return false
            }

            if shouldInterrupt {
                await interrupt()
            }
            await nameFromContent(text)
        } catch {
            sync {
                turnStarting = false
                if !messages.isEmpty { messages.removeLast() }
            }
            throw error
        }
    }

    private func runOpenRouterTurn(
        itemId: String,
        token: UUID,
        model: String,
        key: String,
        messages snapshot: [ChatMessage]
    ) async {
        final class StreamBox: @unchecked Sendable {
            var streamedText = ""
        }
        let box = StreamBox()

        do {
            let fullText = try await OpenRouterClient.streamTurn(
                OpenRouterStreamOptions(
                    key: key,
                    model: model,
                    instructions: ChatPrompt.instructions,
                    messages: snapshot,
                    onDelta: { [weak self] rawDelta in
                        guard let self else { return }
                        let delta: String = self.sync {
                            guard self.openRouterTurnToken == token else { return "" }
                            box.streamedText += rawDelta
                            let citationDelta = self.citationStream.push(rawDelta, sources: self.orderedCitations())
                            return self.linkStream.push(citationDelta)
                        }
                        if !delta.isEmpty {
                            self.onDelta?(delta, itemId)
                        }
                    },
                    onSearching: { [weak self] in
                        guard let self else { return }
                        let isActive = self.sync { self.openRouterTurnToken == token }
                        if isActive {
                            self.onSearching?()
                        }
                    },
                    onCitation: { [weak self] source in
                        guard let self else { return }
                        self.sync { self.recordCitation(source) }
                    },
                    fetch: options.openRouterFetch
                )
            )

            let normalizedOpt: String? = sync {
                guard openRouterTurnToken == token else { return nil }
                citationStream.reset()
                linkStream.reset()
                let rawText = fullText.isEmpty ? box.streamedText : fullText
                let normalized = RenderNormalizer.normalizeAssistantText(rawText, sources: orderedCitations())
                if !normalized.isEmpty {
                    messages.append(ChatMessage(id: itemId, role: "assistant", text: normalized))
                    saveCurrentState()
                }
                openRouterTask = nil
                openRouterTurnToken = nil
                turnId = nil
                turnStarting = false
                return normalized
            }

            guard let normalized = normalizedOpt else { return }
            if !normalized.isEmpty {
                onMessage?(itemId, normalized)
            }
            onDone?()
        } catch {
            let isCancelled = Task.isCancelled || (error is CancellationError)
            let isCurrent = sync { () -> Bool in
                let active = openRouterTurnToken == token
                if isCancelled {
                    let partial = box.streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !partial.isEmpty {
                        let normalized = RenderNormalizer.normalizeAssistantText(box.streamedText, sources: orderedCitations())
                        messages.append(ChatMessage(id: itemId, role: "assistant", text: normalized))
                        saveCurrentState()
                    }
                }
                if active {
                    openRouterTask = nil
                    openRouterTurnToken = nil
                    turnId = nil
                    turnStarting = false
                }
                return active
            }
            if isCurrent {
                if isCancelled {
                    onDone?()
                } else {
                    onError?(error)
                }
            }
        }
    }

    public func interrupt() async {
        enum Action {
            case cancelTask(Task<Void, Never>)
            case rpcInterrupt(threadId: String, turnId: String)
            case none
        }
        let action: Action = sync {
            if let activeOR = openRouterTask {
                interruptPending = false
                return .cancelTask(activeOR)
            }
            if turnStarting && turnId == nil {
                interruptPending = true
                return .none
            }
            guard let currentThread = threadId, let currentTurn = turnId else {
                return .none
            }
            interruptPending = false
            return .rpcInterrupt(threadId: currentThread, turnId: currentTurn)
        }

        switch action {
        case .cancelTask(let task):
            task.cancel()
        case .rpcInterrupt(let currentThread, let currentTurn):
            _ = try? await rpc.request(method: "turn/interrupt", params: ["threadId": currentThread, "turnId": currentTurn], timeoutMs: 30_000)
        case .none:
            break
        }
    }

    public func close() async {
        let (task, dir) = sync { () -> (Task<Void, Never>?, URL?) in
            let t = openRouterTask
            openRouterTask = nil
            openRouterTurnToken = nil
            let d = runtimeDir
            runtimeDir = nil
            return (t, d)
        }

        task?.cancel()
        await rpc.stop()
        if let dir {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func loadModels() async throws {
        let response = try await rpc.request(method: "model/list", params: ["limit": 100, "includeHidden": false], timeoutMs: 30_000)
        let rawList = (response["data"] as? [[String: Any]]) ?? []
        let filtered = Self.availableModels(from: rawList)
        let hasORKey = sync { () -> Bool in
            openAiModels = filtered
            return !openRouterConfig.key.isEmpty
        }

        if filtered.isEmpty && !hasORKey {
            throw NSError(domain: "SpeedChat.Client", code: 2, userInfo: [NSLocalizedDescriptionKey: "No available models support low reasoning effort."])
        }
    }

    private func handleNotification(_ notification: CodexNotification) {
        let method = notification.method
        let params = notification.params

        if method == "speedchat/blockedRequest" {
            Task { await self.interrupt() }
            onError?(NSError(domain: "SpeedChat.Client", code: 8, userInfo: [NSLocalizedDescriptionKey: "Blocked an unexpected client tool or local action request."]))
            return
        }

        lock.lock()
        if let notifThread = params["threadId"] as? String, notifThread != threadId {
            lock.unlock()
            return
        }
        if let notifTurn = params["turnId"] as? String, let activeTurn = turnId, notifTurn != activeTurn {
            lock.unlock()
            return
        }
        if (method.hasPrefix("item/") || method.hasPrefix("turn/")) && !turnStarting && turnId == nil {
            lock.unlock()
            return
        }

        if method == "item/agentMessage/delta" {
            let rawDelta = (params["delta"] as? String) ?? ""
            let itemId = (params["itemId"] as? String) ?? ""
            let citationDelta = citationStream.push(rawDelta, sources: orderedCitations())
            let delta = linkStream.push(citationDelta)
            lock.unlock()
            if !delta.isEmpty {
                onDelta?(delta, itemId)
            }
            return
        }

        if method == "item/started" || method == "item/completed" {
            guard let item = params["item"] as? [String: Any],
                  let itemType = item["type"] as? String else {
                lock.unlock()
                return
            }
            if itemType == "webSearch" {
                if method == "item/started" {
                    lock.unlock()
                    onSearching?()
                } else {
                    for source in RenderNormalizer.citationSources(from: item["results"]) {
                        recordCitation(source)
                    }
                    lock.unlock()
                }
                return
            }
            if method == "item/completed", itemType == "agentMessage" {
                let phase = item["phase"] as? String
                let text = (item["text"] as? String) ?? ""
                let itemId = (item["id"] as? String) ?? "assistant"
                if phase != "commentary" && !text.isEmpty {
                    citationStream.reset()
                    linkStream.reset()
                    let normalized = RenderNormalizer.normalizeAssistantText(text, sources: orderedCitations())
                    messages.append(ChatMessage(id: itemId, role: "assistant", text: normalized))
                    codexSyncedCount = messages.count
                    saveCurrentState()
                    lock.unlock()
                    onMessage?(itemId, normalized)
                    return
                }
            }
            let allowedTypes: Set<String> = ["userMessage", "agentMessage", "reasoning", "contextCompaction"]
            if Self.toolItemTypes.contains(itemType) || !allowedTypes.contains(itemType) {
                if !turnBlocked {
                    turnBlocked = true
                    let itemId = (item["id"] as? String) ?? "blocked"
                    let itemJSON = (try? JSONSerialization.data(withJSONObject: item)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let isImageAttempt = itemType == "imageGeneration" || itemType == "imageView" || itemJSON.range(of: #"emitImage|image"#, options: [.regularExpression, .caseInsensitive]) != nil
                    if isImageAttempt {
                        let explanation = "I can’t generate or display images here—this quick-chat panel is text-only for fast conversation."
                        messages.append(ChatMessage(id: itemId, role: "assistant", text: explanation))
                        codexSyncedCount = messages.count
                        lock.unlock()
                        Task { await self.interrupt() }
                        onMessage?(itemId, explanation)
                    } else {
                        lock.unlock()
                        Task { await self.interrupt() }
                        onError?(NSError(domain: "SpeedChat.Client", code: 9, userInfo: [NSLocalizedDescriptionKey: "Blocked an unexpected \(itemType) request."]))
                    }
                    return
                }
            }
            lock.unlock()
            return
        }

        if method == "turn/started" {
            let turn = params["turn"] as? [String: Any]
            if let startedId = turn?["id"] as? String, !startedId.isEmpty {
                turnId = startedId
            }
            let pendingStop = interruptPending
            lock.unlock()
            if pendingStop {
                Task { await self.interrupt() }
            }
            return
        }

        if method == "model/rerouted", (params["threadId"] as? String) == threadId {
            let actualModel = (params["toModel"] as? String) ?? ""
            lock.unlock()
            if !actualModel.isEmpty {
                onModel?(actualModel)
            }
            return
        }

        if method == "turn/completed" {
            turnStarting = false
            turnBlocked = false
            turnId = nil
            codexSyncedCount = messages.count
            let turn = params["turn"] as? [String: Any]
            let status = turn?["status"] as? String
            let errDict = turn?["error"] as? [String: Any]
            let errMsg = (errDict?["message"] as? String) ?? "The response failed."
            lock.unlock()
            if status == "failed" {
                onError?(NSError(domain: "SpeedChat.Client", code: 10, userInfo: [NSLocalizedDescriptionKey: errMsg]))
            } else {
                onDone?()
            }
            return
        }

        if method == "error" {
            let errDict = params["error"] as? [String: Any]
            let errMsg = (errDict?["message"] as? String) ?? (params["message"] as? String) ?? "Codex reported an error."
            lock.unlock()
            onError?(NSError(domain: "SpeedChat.Client", code: 11, userInfo: [NSLocalizedDescriptionKey: errMsg]))
            return
        }

        lock.unlock()
    }
}
