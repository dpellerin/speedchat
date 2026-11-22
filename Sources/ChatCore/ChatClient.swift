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

    private var conversation = ConversationContinuity()
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
    private var openRouterTask: Task<Void, Never>?
    private var openRouterTurnToken: UUID?

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

    private func codexModelForSelection() -> String {
        guard isOpenRouterModel(model) else { return model }
        let defaultCodexModel = Self.defaultModel(from: openAiModels)
        return defaultCodexModel.isEmpty ? model : defaultCodexModel
    }

    private func handleProcessExit() {
        let handled = sync { () -> Bool in
            if let attached = conversation.attachedThreadId {
                conversation.thread = .detached(attached)
            }
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
        let namingRequest = sync { () -> (threadId: String, prompt: String)? in
            guard let threadId = conversation.attachedThreadId, conversation.titleNeeded, codexAvailable else { return nil }
            let prompt = conversation.messages.first { $0.role == "user" }?.text ?? text
            return (threadId, prompt)
        }
        guard let (currentThread, prompt) = namingRequest else { return }
        do {
            _ = try await rpc.request(
                method: "thread/name/set",
                params: ["threadId": currentThread, "name": Self.conversationTitle(prompt)],
                timeoutMs: 30_000
            )
            sync {
                if conversation.attachedThreadId == currentThread {
                    conversation.titleNeeded = false
                }
            }
        } catch {
            // Naming is optional; retry on the next message without failing chat.
        }
    }

    private func saveCurrentState() {
        try? conversation.save(model: model, to: options.stateURL, env: options.env)
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
        let resumeRequest = sync { () -> (threadId: String, model: String)? in
            if let state, models.contains(where: { $0.model == state.model }) {
                model = state.model
            } else {
                model = Self.defaultModel(from: models)
            }
            guard let state else { return nil }
            conversation = ConversationContinuity(restoring: state)
            guard codexAvailable, case .detached(let threadId) = conversation.thread else { return nil }
            return (threadId, codexModelForSelection())
        }

        guard let state else { return try await newChat() }
        if let (threadId, resumeModel) = resumeRequest {
            do {
                let resumed = try await resumeCodexThread(id: threadId, model: resumeModel, cwdPath: dir.path)
                sync {
                    guard codexAvailable else { return }
                    let importedLegacyHistory = conversation.didResume(
                        threadId: threadId,
                        name: resumed.name,
                        codexMessages: StateStore.messagesFromTurns(resumed.turns)
                    )
                    if !isOpenRouterModel(model), let resumedModel = resumed.model, !resumedModel.isEmpty {
                        model = resumedModel
                    }
                    if importedLegacyHistory || state.model != model {
                        saveCurrentState()
                    }
                }
            } catch let error as CodexRPCError where error.confirmsMissingRollout(for: threadId) {
                sync { conversation.didConfirmThreadLoss(threadId) }
            } catch {
                // Keep the saved conversation ready while thread availability is unknown.
            }
        }
        return sync { readyStateLocked() }
    }

    private func resumeCodexThread(
        id: String, model: String, cwdPath: String
    ) async throws -> (model: String?, name: String?, turns: [[String: Any]]) {
        let response = try await rpc.request(
            method: "thread/resume",
            params: [
                "threadId": id,
                "model": model,
                "personality": ChatPrompt.personality,
                "cwd": cwdPath,
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
        guard let thread = response["thread"] as? [String: Any],
              thread["id"] as? String == id,
              let turns = thread["turns"] as? [[String: Any]] else {
            throw NSError(domain: "SpeedChat.Client", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid resumed Codex thread."])
        }
        return (response["model"] as? String, thread["name"] as? String, turns)
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

    private func startCodexThread(model: String, cwdPath: String) async throws -> String {
        let response = try await rpc.request(
            method: "thread/start",
            params: [
                "model": model,
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
        guard let thread = response["thread"] as? [String: Any],
              let id = thread["id"] as? String, !id.isEmpty,
              !id.hasPrefix("openrouter-"), !id.hasPrefix("codex-") else {
            throw NSError(domain: "SpeedChat.Client", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid new Codex thread."])
        }
        return id
    }

    private func codexThreadForSend(currentThread: ConversationContinuity.Thread, model: String) async throws -> String {
        let cwdPath = sync { runtimeDir?.path ?? "" }
        switch currentThread {
        case .attached(let id):
            return id
        case .detached(let id):
            do {
                let resumed = try await resumeCodexThread(id: id, model: model, cwdPath: cwdPath)
                return sync {
                    if conversation.didResume(
                        threadId: id,
                        name: resumed.name,
                        codexMessages: StateStore.messagesFromTurns(resumed.turns)
                    ) {
                        saveCurrentState()
                    }
                    return id
                }
            } catch let error as CodexRPCError where error.confirmsMissingRollout(for: id) {
                sync { conversation.didConfirmThreadLoss(id) }
            }
        case .standalone, .missing:
            break
        }

        let startedId = try await startCodexThread(model: model, cwdPath: cwdPath)
        return sync {
            conversation.didStartCodexThread(startedId)
            saveCurrentState()
            return startedId
        }
    }

    public func newChat() async throws -> ReadyState {
        let (isCodexUp, codexModel, cwdPath) = try sync { () -> (Bool, String, String) in
            if turnStarting || turnId != nil || mutationPending {
                throw NSError(domain: "SpeedChat.Client", code: 4, userInfo: [NSLocalizedDescriptionKey: "Wait for the current response or change to finish."])
            }
            mutationPending = true
            return (codexAvailable, codexModelForSelection(), runtimeDir?.path ?? "")
        }

        defer {
            sync { mutationPending = false }
        }

        let thread: ConversationContinuity.Thread
        if isCodexUp {
            thread = .attached(try await startCodexThread(model: codexModel, cwdPath: cwdPath))
        } else {
            thread = .standalone("openrouter-\(UUID().uuidString.lowercased())")
        }
        let ready = sync {
            conversation = ConversationContinuity(thread: thread, titleNeeded: isCodexUp)
            turnId = nil
            saveCurrentState()
            return readyStateLocked(resumed: false)
        }
        if case .attached(let id) = thread {
            _ = try? await rpc.request(method: "thread/name/set", params: ["threadId": id, "name": "New chat"], timeoutMs: 30_000)
        }
        return ready
    }

    public func selectModel(_ candidate: String) async throws -> ReadyState {
        let (currentThread, shouldUpdateCodex) = try sync { () -> (String, Bool) in
            if turnStarting || turnId != nil || mutationPending {
                throw NSError(domain: "SpeedChat.Client", code: 4, userInfo: [NSLocalizedDescriptionKey: "Wait for the current response or change to finish."])
            }
            guard models.contains(where: { $0.model == candidate }) else {
                throw NSError(domain: "SpeedChat.Client", code: 5, userInfo: [NSLocalizedDescriptionKey: "Selected model is unavailable."])
            }
            guard let t = conversation.thread else {
                throw NSError(domain: "SpeedChat.Client", code: 6, userInfo: [NSLocalizedDescriptionKey: "Chat is not ready."])
            }
            mutationPending = true
            let updateCodex = !isOpenRouterModel(candidate) && codexAvailable && conversation.attachedThreadId != nil
            return (t.id, updateCodex)
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

    private func readyStateLocked(resumed: Bool = true) -> ReadyState {
        ReadyState(
            threadId: conversation.thread?.id ?? "",
            messages: conversation.messages,
            resumed: resumed,
            model: model,
            models: models,
            openRouterConfigured: !openRouterConfig.key.isEmpty
        )
    }

    public func send(_ text: String) async throws {
        let (currentThread, currentModel, useOpenRouter, orKey) = try sync { () -> (ConversationContinuity.Thread, String, Bool, String) in
            if turnStarting || turnId != nil || mutationPending {
                throw NSError(domain: "SpeedChat.Client", code: 4, userInfo: [NSLocalizedDescriptionKey: "Wait for the current response or change to finish."])
            }
            guard let t = conversation.thread else {
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
                conversation.messages.append(userMessage)
                turnId = "or-turn-\(token.uuidString.lowercased())"
                openRouterTurnToken = token
                turnStarting = false
                return (conversation.messages, interruptPending)
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

        var appendedUserMessageId: String?
        do {
            let codexThread = try await codexThreadForSend(currentThread: currentThread, model: currentModel)
            let (inputText, cwdPath) = sync { () -> (String, String) in
                let unsent = Array(conversation.messages.dropFirst(conversation.codexSyncedCount))
                let formattedInput: String
                if !unsent.isEmpty {
                    let historyText = unsent.map { "\($0.role == "user" ? "User" : "Assistant"): \($0.text)" }.joined(separator: "\n\n")
                    formattedInput = "[Earlier turns in this conversation from another model:\n\(historyText)]\n\n\(text)"
                } else {
                    formattedInput = text
                }
                let userMessage = ChatMessage(id: UUID().uuidString.lowercased(), role: "user", text: text)
                conversation.messages.append(userMessage)
                appendedUserMessageId = userMessage.id
                return (formattedInput, runtimeDir?.path ?? "")
            }

            let response = try await rpc.request(
                method: "turn/start",
                params: [
                    "threadId": codexThread,
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
                if let appendedUserMessageId, conversation.messages.last?.id == appendedUserMessageId {
                    conversation.messages.removeLast()
                }
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
            var reasoning: String?
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
                    onReasoning: { [weak self] reasoning in
                        guard let self else { return }
                        self.sync {
                            guard self.openRouterTurnToken == token else { return }
                            box.reasoning = reasoning.isEmpty ? nil : reasoning
                        }
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
                    conversation.messages.append(ChatMessage(id: itemId, role: "assistant", text: normalized, reasoning: box.reasoning))
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
                        conversation.messages.append(ChatMessage(id: itemId, role: "assistant", text: normalized))
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
            guard let currentThread = conversation.attachedThreadId, let currentTurn = turnId else {
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
        guard let attachedThreadId = conversation.attachedThreadId else {
            lock.unlock()
            return
        }
        if let notifThread = params["threadId"] as? String, notifThread != attachedThreadId {
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
                    conversation.messages.append(ChatMessage(id: itemId, role: "assistant", text: normalized))
                    conversation.codexSyncedCount = conversation.messages.count
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
                        conversation.messages.append(ChatMessage(id: itemId, role: "assistant", text: explanation))
                        conversation.codexSyncedCount = conversation.messages.count
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

        if method == "model/rerouted", (params["threadId"] as? String) == attachedThreadId {
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
            conversation.codexSyncedCount = conversation.messages.count
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
