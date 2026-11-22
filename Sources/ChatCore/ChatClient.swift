import Foundation

public struct ReadyState: Equatable, Sendable {
    public var threadId: String
    public var messages: [ChatMessage]
    public var resumed: Bool
    public var model: String
    public var reasoningEffort: String
    public var models: [ChatModel]
    public var openRouterConfigured: Bool
    public var offlineReason: String?
    public var stateSaveError: String?
    public var codexRetry: CodexRetry?

    public init(
        threadId: String,
        messages: [ChatMessage],
        resumed: Bool,
        model: String,
        reasoningEffort: String = ChatPrompt.reasoningEffort,
        models: [ChatModel],
        openRouterConfigured: Bool = false,
        offlineReason: String? = nil,
        stateSaveError: String? = nil,
        codexRetry: CodexRetry? = nil
    ) {
        self.threadId = threadId
        self.messages = messages
        self.resumed = resumed
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.models = models
        self.openRouterConfigured = openRouterConfigured
        self.offlineReason = offlineReason
        self.stateSaveError = stateSaveError
        self.codexRetry = codexRetry
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
    private var turnBlocked = false
    private var interruptPending = false
    private var mutationPending = false
    private var checkedCodexSendId: String?
    private var undispatchedCodexMessage: ChatMessage?

    private struct PendingSend {
        let user: ChatMessage
        let thread: ConversationContinuity.Thread
        let model: String
        let openRouterKey: String?
    }

    private struct ActiveExecution {
        let id: UUID
        var pendingSend: PendingSend?
        var openRouter: OpenRouterReply?
    }

    private struct OpenRouterReply {
        let itemId = "or-msg-\(UUID().uuidString.lowercased())"
        var task: Task<Void, Never>?
        var streamedText = ""
        var reasoning: String?
    }

    private var activeExecution: ActiveExecution?

    private struct ActiveCodexTurn {
        var attempt: CodexSendAttempt
        var receiptConfirmed = false
        var awaitingDeliveryCheck = false
        var deferredNotifications = [CodexNotification]()
    }

    private var codexTurn: ActiveCodexTurn?

    public var busy: Bool {
        sync { activeExecution != nil || mutationPending }
    }

    public var codexRetry: CodexRetry? {
        sync { codexRetryLocked() }
    }

    private func codexRetryLocked() -> CodexRetry? {
        if let message = undispatchedCodexMessage {
            return CodexRetry(userMessageId: message.id, action: .retry)
        }
        guard let attempt = conversation.lastCodexSend else { return nil }
        let action: CodexRetry.Action
        switch attempt.delivery {
        case .confirmed: return nil
        case .rejected: action = .retry
        case .unconfirmed: action = checkedCodexSendId == attempt.clientId ? .resend : .checkDelivery
        }
        return CodexRetry(userMessageId: attempt.userMessageId, action: action)
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
    public var onTurnEvent: (@Sendable (BridgeEvent) -> Void)?
    public var onDelta: (@Sendable (String, String) -> Void)?
    public var onMessage: (@Sendable (String, String) -> Void)?
    public var onHistoryRecovered: (@Sendable ([ChatMessage]) -> Void)?
    public var onCodexReplyResumed: (@Sendable (String, [ChatMessage]) -> Void)?
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
        let (openRouterReady, interruptedTurn) = sync {
            if let attached = conversation.attachedThreadId {
                conversation.thread = .detached(attached)
            }
            let interruptedTurn = codexTurn?.awaitingDeliveryCheck == false
            if interruptedTurn { finishCodexTurn() }
            else { codexTurn = nil }
            codexAvailable = false
            openAiModels = []
            rebuildModelCatalog()
            return (!openRouterConfig.key.isEmpty, interruptedTurn)
        }
        let error = NSError(domain: "SpeedChat.Client", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The Codex app-server stopped unexpectedly.",
        ])
        if !openRouterReady {
            onFatal?(error)
        } else if interruptedTurn {
            onError?(error)
        }
    }

    private func ensureCodexRunning() async throws {
        let (available, dir) = sync { (codexAvailable, runtimeDir) }
        guard !available else { return }
        try await rpc.start(cwd: dir)
        try await loadModels()
        sync {
            codexAvailable = true
            rebuildModelCatalog()
        }
    }

    private func nameFromContent(_ text: String, threadId expectedThread: String? = nil) async {
        let namingRequest = sync { () -> (threadId: String, prompt: String)? in
            guard let threadId = conversation.attachedThreadId,
                  expectedThread == nil || threadId == expectedThread,
                  conversation.titleNeeded, codexAvailable else { return nil }
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

    private func saveCodexState() throws {
        do {
            try conversation.save(model: model, to: options.stateURL, env: options.env)
        } catch {
            throw NSError(domain: "SpeedChat.Persistence", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "SpeedChat couldn’t save the conversation to local storage.",
            ])
        }
    }

    private func codexStateSaveFailure() -> Error? {
        do {
            try saveCodexState()
            return nil
        } catch {
            return error
        }
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
            try await ensureCodexRunning()
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

        let state = StateStore.load(from: options.stateURL, env: options.env)
        if currentModels.isEmpty {
            let error = codexError ?? NSError(domain: "SpeedChat.Client", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No available models support low reasoning effort.",
            ])
            guard let state else { throw error }
            return sync {
                model = state.model
                conversation = ConversationContinuity(restoring: state)
                return readyStateLocked(offlineReason: StateStore.friendlyError(error))
            }
        }

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
        var saveFailure: Error?
        if let (threadId, resumeModel) = resumeRequest {
            do {
                let resumed = try await resumeCodexThread(id: threadId, model: resumeModel, cwdPath: dir.path)
                sync {
                    guard codexAvailable, conversation.thread?.id == threadId else { return }
                    let recoveredHistory = conversation.didResume(
                        threadId: threadId,
                        name: resumed.name,
                        history: CodexHistory(turns: resumed.turns)
                    )
                    if !isOpenRouterModel(model), let resumedModel = resumed.model, !resumedModel.isEmpty {
                        model = resumedModel
                    }
                    if recoveredHistory {
                        saveFailure = codexStateSaveFailure()
                    } else if state.model != model {
                        saveCurrentState()
                    }
                }
            } catch let error as CodexRPCError where error.confirmsMissingRollout(for: threadId) {
                sync { conversation.didConfirmThreadLoss(threadId) }
            } catch {
                // Keep the saved conversation ready while thread availability is unknown.
            }
        }
        return sync {
            let offlineReason = models.isEmpty ? "The Codex app-server stopped unexpectedly." : nil
            return readyStateLocked(offlineReason: offlineReason, stateSaveError: saveFailure?.localizedDescription)
        }
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

    private enum CodexSendThread {
        case existing(String)
        case started(String)

        var id: String {
            switch self {
            case .existing(let id), .started(let id): return id
            }
        }
    }

    private func codexThreadForSend(
        currentThread: ConversationContinuity.Thread, model: String
    ) async throws -> CodexSendThread {
        let cwdPath = sync { runtimeDir?.path ?? "" }
        switch currentThread {
        case .attached(let id):
            return .existing(id)
        case .detached(let id):
            do {
                let resumed = try await resumeCodexThread(id: id, model: model, cwdPath: cwdPath)
                return try sync {
                    guard codexAvailable, conversation.thread?.id == id else { throw CodexRequestNotSent() }
                    let previousMessages = conversation.messages
                    if conversation.didResume(
                        threadId: id,
                        name: resumed.name,
                        history: CodexHistory(turns: resumed.turns)
                    ) {
                        if conversation.messages != previousMessages { onHistoryRecovered?(conversation.messages) }
                        if let error = codexStateSaveFailure() { onError?(error) }
                    }
                    return .existing(id)
                }
            } catch let error as CodexRPCError where error.confirmsMissingRollout(for: id) {
                sync { conversation.didConfirmThreadLoss(id) }
            }
        case .standalone, .missing:
            break
        }

        return .started(try await startCodexThread(model: model, cwdPath: cwdPath))
    }

    public func newChat() async throws -> ReadyState {
        let (isCodexUp, codexModel, cwdPath) = try sync { () -> (Bool, String, String) in
            if activeExecution != nil || mutationPending {
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
            checkedCodexSendId = nil
            undispatchedCodexMessage = nil
            codexTurn = nil
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
            if activeExecution != nil || mutationPending {
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

    private func readyStateLocked(
        resumed: Bool = true, offlineReason: String? = nil, stateSaveError: String? = nil
    ) -> ReadyState {
        ReadyState(
            threadId: conversation.thread?.id ?? "",
            messages: conversation.messages,
            resumed: resumed,
            model: model,
            models: models,
            openRouterConfigured: !openRouterConfig.key.isEmpty,
            offlineReason: offlineReason,
            stateSaveError: stateSaveError,
            codexRetry: codexRetryLocked()
        )
    }

    public func retryCodexSend(userMessageId: String? = nil, resend: Bool = false) async throws -> ReadyState? {
        let (thread, selectedModel, user, attempt, action) = try sync {
            let thread = try threadForNewTurn()
            guard !isOpenRouterModel(model), let retry = codexRetryLocked(),
                  !resend || retry.action == .resend,
                  userMessageId == nil || retry.userMessageId == userMessageId else {
                throw NSError(domain: "SpeedChat.Client", code: 6, userInfo: [NSLocalizedDescriptionKey: "There is no Codex send to retry."])
            }
            let message = undispatchedCodexMessage ?? conversation.userIndex(messageId: retry.userMessageId)
                .map { conversation.messages[$0] }
            guard let message else {
                throw NSError(domain: "SpeedChat.Client", code: 6, userInfo: [NSLocalizedDescriptionKey: "The message to retry is unavailable."])
            }
            beginTurn()
            return (thread, model, message, conversation.lastCodexSend, retry.action)
        }

        if action == .retry {
            onModel?(selectedModel)
            return try await sendCodex(user, on: thread, model: selectedModel)
        }

        guard let attempt else {
            return sync {
                finishCodexTurn()
                return readyStateLocked()
            }
        }
        enum DeliveryCheck {
            case checked(ReadyState)
            case streaming(interrupt: Bool)
            case resend(ConversationContinuity.Thread)
        }

        let history = await readCodexHistory(threadId: attempt.threadId)
        let result = sync { () -> DeliveryCheck in
            checkedCodexSendId = attempt.clientId
            // A by-ID read does not subscribe. Only this still-attached attempt
            // can resume its original stream or consume buffered notifications.
            let canResume = codexAvailable && conversation.attachedThreadId == attempt.threadId &&
                codexTurn?.awaitingDeliveryCheck == true && codexTurn?.attempt.clientId == attempt.clientId
            if canResume, let deferred = codexTurn?.deferredNotifications {
                let completedTurns = deferred.compactMap { notification -> [String: Any]? in
                    guard notification.method == "turn/completed" else { return nil }
                    return notification.params["turn"] as? [String: Any]
                }
                if let id = applyCodexTurnItems(
                    CodexHistory(turns: completedTurns), threadId: attempt.threadId, resumingReply: true
                ) {
                    return .streaming(interrupt: bindCodexTurn(id))
                }
            }
            if let history {
                if case .missing(let id) = conversation.thread, id == attempt.threadId {
                    conversation.thread = .detached(id)
                }
                if let recorded = conversation.reconcileCodexSend(threadId: attempt.threadId, history: history) {
                    let saveFailure = codexStateSaveFailure()
                    if canResume, let id = recorded.id {
                        let isInProgress = history.isThreadActive && recorded.status == "inProgress"
                        let hasBufferedCompletion = codexTurn?.deferredNotifications.contains { notification in
                            guard notification.method == "turn/completed",
                                  let turn = notification.params["turn"] as? [String: Any] else { return false }
                            return turn["id"] as? String == id
                        } == true
                        if isInProgress || hasBufferedCompletion {
                            codexTurn?.awaitingDeliveryCheck = false
                            codexTurn?.receiptConfirmed = true
                            onCodexReplyResumed?(user.id, conversation.messages)
                            if let saveFailure { onError?(saveFailure) }
                            return .streaming(interrupt: bindCodexTurn(id))
                        }
                    }
                    finishCodexTurn()
                    return .checked(readyStateLocked(stateSaveError: saveFailure?.localizedDescription))
                }
            }
            if resend, conversation.lastCodexSend?.delivery == .unconfirmed {
                return .resend(conversation.thread ?? thread)
            }
            endCodexOperation()
            return .checked(readyStateLocked())
        }
        switch result {
        case .checked(let ready):
            return ready
        case .streaming(let shouldInterrupt):
            if shouldInterrupt { await interrupt() }
            return nil
        case .resend(let currentThread):
            onModel?(selectedModel)
            return try await sendCodex(user, on: currentThread, model: selectedModel, replacing: attempt)
        }
    }

    private func readCodexHistory(threadId: String) async -> CodexHistory? {
        do {
            try await ensureCodexRunning()
            let result = try await rpc.request(
                method: "thread/read",
                params: ["threadId": threadId, "includeTurns": true],
                timeoutMs: 30_000
            )
            guard let thread = result["thread"] as? [String: Any], thread["id"] as? String == threadId,
                  let turns = thread["turns"] as? [[String: Any]] else { return nil }
            let status = thread["status"] as? [String: Any]
            return CodexHistory(turns: turns, isThreadActive: status?["type"] as? String == "active")
        } catch {
            return nil
        }
    }

    private func threadForNewTurn() throws -> ConversationContinuity.Thread {
        guard !busy else {
            throw NSError(domain: "SpeedChat.Client", code: 4, userInfo: [NSLocalizedDescriptionKey: "Wait for the current response or change to finish."])
        }
        guard let thread = conversation.thread else {
            throw NSError(domain: "SpeedChat.Client", code: 6, userInfo: [NSLocalizedDescriptionKey: "Chat is not ready."])
        }
        return thread
    }

    private func beginTurn(_ execution: ActiveExecution = ActiveExecution(id: UUID())) {
        activeExecution = execution
        turnBlocked = false
        interruptPending = false
        citationSources.removeAll()
        citationOrder.removeAll()
        citationStream.reset()
        linkStream.reset()
    }

    /// Register a Send before scheduling provider work, so Stop can settle it immediately.
    public func acceptSend(_ text: String, userMessageId: String, executionID: UUID) throws {
        try sync {
            let thread = try threadForNewTurn()
            let useOpenRouter = isOpenRouterModel(model)
            if !useOpenRouter, let action = codexRetryLocked(), action.action != .retry {
                throw NSError(domain: "SpeedChat.Client", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: action.notice ?? "Check the previous Codex send first.",
                ])
            }
            let key = openRouterConfig.key
            if useOpenRouter && key.isEmpty {
                throw NSError(domain: "SpeedChat.Client", code: 7, userInfo: [NSLocalizedDescriptionKey: "OpenRouter API key is required. Add your key in SpeedChat Settings."])
            }
            let user = ChatMessage(id: userMessageId, role: "user", text: text)
            beginTurn(ActiveExecution(
                id: executionID,
                pendingSend: PendingSend(user: user, thread: thread, model: model, openRouterKey: useOpenRouter ? key : nil),
                openRouter: useOpenRouter ? OpenRouterReply() : nil
            ))
            if useOpenRouter { conversation.messages.append(user) }
        }
    }

    public func send(_ text: String, userMessageId: String = UUID().uuidString.lowercased()) async throws {
        let executionID = UUID()
        try acceptSend(text, userMessageId: userMessageId, executionID: executionID)
        try await startSend(executionID: executionID)
    }

    public func startSend(executionID: UUID) async throws {
        let pending = sync { () -> PendingSend? in
            guard activeExecution?.id == executionID, let pending = activeExecution?.pendingSend else { return nil }
            activeExecution?.pendingSend = nil
            if pending.openRouterKey != nil {
                onTurnEvent?(BridgeEvent(type: "activeModel", model: pending.model, executionID: executionID))
            }
            return pending
        }
        guard let pending else { return }

        if pending.openRouterKey == nil || onTurnEvent == nil { onModel?(pending.model) }
        if let key = pending.openRouterKey {
            let namingThread = sync { () -> String? in
                guard activeExecution?.id == executionID else { return nil }
                let snapshot = conversation.messages
                activeExecution?.openRouter?.task = Task { [weak self] in
                    await self?.runOpenRouterTurn(executionID: executionID, model: pending.model, key: key, messages: snapshot)
                }
                return conversation.attachedThreadId
            }
            if let namingThread { await nameFromContent(pending.user.text, threadId: namingThread) }
        } else {
            _ = try await sendCodex(pending.user, on: pending.thread, model: pending.model)
        }
    }

    private func sendCodex(
        _ user: ChatMessage, on thread: ConversationContinuity.Thread, model currentModel: String,
        replacing previous: CodexSendAttempt? = nil
    ) async throws -> ReadyState? {
        var dispatchedAttempt: CodexSendAttempt?
        var beforeResend: ConversationContinuity?
        var journalSaveFailed = false
        do {
            try await ensureCodexRunning()
            let currentThread = sync { conversation.thread ?? thread }
            let target = try await codexThreadForSend(currentThread: currentThread, model: currentModel)
            let codexThread = target.id
            let prepared = try sync { () -> (CodexSendAttempt, String)? in
                if let previous, conversation.lastCodexSend?.clientId == previous.clientId {
                    if conversation.lastCodexSend?.delivery == .confirmed {
                        finishCodexTurn()
                        return nil
                    }
                    beforeResend = conversation
                }
                let beforeSend = conversation
                guard codexAvailable else { throw CodexRequestNotSent() }
                switch target {
                case .existing:
                    guard conversation.attachedThreadId == codexThread else { throw CodexRequestNotSent() }
                case .started:
                    conversation.didStartCodexThread(codexThread)
                }
                let index: Int
                let clientId: String
                if let existing = conversation.userIndex(messageId: user.id) {
                    index = existing
                    clientId = UUID().uuidString.lowercased()
                } else {
                    index = conversation.messages.count
                    conversation.messages.append(user)
                    clientId = user.id
                }
                let start = min(conversation.codexSyncedCount, index)
                let unsent = conversation.messages[start..<index]
                let historyText = unsent.map { "\($0.role == "user" ? "User" : "Assistant"): \($0.text)" }.joined(separator: "\n\n")
                let formattedInput = unsent.isEmpty ? user.text : "\(ChatPrompt.quotedHistoryPrefix)\(historyText)]\n\n\(user.text)"
                let wireText = previous?.threadId == codexThread ? (previous?.wireText ?? formattedInput) : formattedInput
                let attempt = CodexSendAttempt(
                    threadId: codexThread, clientId: clientId, userMessageId: user.id, wireText: wireText
                )
                conversation.lastCodexSend = attempt
                do {
                    try saveCodexState()
                } catch {
                    journalSaveFailed = true
                    conversation = beforeSend
                    throw error
                }
                undispatchedCodexMessage = nil
                codexTurn = ActiveCodexTurn(attempt: attempt)
                return (attempt, runtimeDir?.path ?? "")
            }

            guard let (attempt, cwdPath) = prepared else { return sync { readyStateLocked() } }
            dispatchedAttempt = attempt
            let response = try await rpc.request(
                method: "turn/start",
                params: [
                    "threadId": codexThread,
                    "input": [["type": "text", "text": attempt.wireText]],
                    "clientUserMessageId": attempt.clientId,
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
            let shouldInterrupt = try sync { () -> Bool in
                guard let active = codexTurn, active.attempt.clientId == attempt.clientId else { return false }
                guard let turn = response["turn"] as? [String: Any],
                      let id = turn["id"] as? String, !id.isEmpty,
                      active.attempt.turnId == nil || active.attempt.turnId == id else {
                    throw NSError(domain: "SpeedChat.Client", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid Codex turn acknowledgement."])
                }
                let provedReceipt = applyCodexTurnItems(CodexHistory(turns: [turn]), threadId: codexThread)
                if provedReceipt != nil, let status = turn["status"] as? String,
                   ["completed", "interrupted", "failed"].contains(status) {
                    handleNotification(CodexNotification(method: "turn/completed", params: [
                        "threadId": codexThread, "turn": turn,
                    ]))
                    return false
                }
                guard active.attempt.turnId == nil else { return false }
                return bindCodexTurn(id)
            }

            if shouldInterrupt {
                await interrupt()
            }
            await nameFromContent(user.text, threadId: codexThread)
            return nil
        } catch let sendError {
            let report = sync { () -> Error? in
                guard let dispatchedAttempt else {
                    defer { endCodexOperation() }
                    // A retry that never reached turn/start cannot replace old
                    // evidence about this same prompt.
                    guard conversation.lastCodexSend?.userMessageId != user.id else { return sendError }
                    if journalSaveFailed {
                        undispatchedCodexMessage = user
                        return sendError
                    }
                    let beforeRejection = conversation
                    conversation.recordUndispatchedCodexPrompt(user)
                    do {
                        try saveCodexState()
                        undispatchedCodexMessage = nil
                        return sendError
                    } catch {
                        conversation = beforeRejection
                        undispatchedCodexMessage = user
                        return error
                    }
                }
                guard let active = codexTurn, active.attempt.clientId == dispatchedAttempt.clientId,
                      !active.receiptConfirmed else { return nil }
                let rpcError = sendError as? CodexRPCError
                let unloaded = rpcError?.confirmsUnloadedThread(for: dispatchedAttempt.threadId) == true
                let rejected = unloaded || rpcError?.confirmsInputRejection == true || sendError is CodexRequestNotSent
                var report = sendError
                if rejected {
                    if let beforeResend {
                        conversation = beforeResend
                    } else {
                        conversation.lastCodexSend?.delivery = .rejected
                    }
                    do {
                        try saveCodexState()
                    } catch {
                        report = error
                    }
                }
                if unloaded, conversation.attachedThreadId == dispatchedAttempt.threadId {
                    conversation.thread = .detached(dispatchedAttempt.threadId)
                }
                if !rejected, codexAvailable, conversation.attachedThreadId == dispatchedAttempt.threadId {
                    codexTurn?.awaitingDeliveryCheck = true
                    endCodexOperation()
                } else {
                    finishCodexTurn()
                }
                return report
            }
            if let report { throw report }
            return nil
        }
    }

    private func applyCodexTurnItems(
        _ history: CodexHistory, threadId: String, resumingReply: Bool = false
    ) -> String? {
        guard let active = codexTurn,
              let (turn, itemId) = history.matchingReceipt(for: active.attempt, threadId: threadId),
              let turnId = turn.id,
              active.receiptConfirmed || conversation.recordCodexReceipt(active.attempt, turnId: turnId) else { return nil }
        codexTurn?.receiptConfirmed = true
        if resumingReply {
            codexTurn?.awaitingDeliveryCheck = false
            onCodexReplyResumed?(active.attempt.userMessageId, conversation.messages)
        }
        let existingIds = Set(conversation.messages.map(\.id))
        let recovered = conversation.recoverReplies(
            in: turn, threadId: threadId, after: itemId, for: active.attempt.userMessageId
        )
        if !active.receiptConfirmed || recovered, let error = codexStateSaveFailure() { onError?(error) }
        if recovered {
            onHistoryRecovered?(conversation.messages)
            for reply in conversation.messages where !existingIds.contains(reply.id) {
                onMessage?(reply.id, reply.text)
            }
        }
        return turnId
    }

    // Both the acknowledged turn and an exact prompt receipt can bind an attempt.
    // Other notifications wait for that binding so a late turn cannot claim a new send.
    private func bindCodexTurn(_ id: String) -> Bool {
        guard let active = codexTurn else { return false }
        let deferred = active.deferredNotifications
        codexTurn?.deferredNotifications.removeAll()
        codexTurn?.attempt.turnId = id
        if conversation.lastCodexSend?.clientId == active.attempt.clientId,
           conversation.lastCodexSend?.turnId != id {
            conversation.lastCodexSend?.turnId = id
            saveCurrentState()
        }
        turnId = id
        for notification in deferred { handleNotification(notification) }
        return turnId == id && interruptPending
    }

    private func finishCodexTurn() {
        codexTurn = nil
        endCodexOperation()
    }

    private func endCodexOperation() {
        turnId = nil
        activeExecution = nil
        turnBlocked = false
        interruptPending = false
    }

    private func emitTurnEvent(_ event: BridgeEvent, executionID: UUID, fallback: () -> Void) {
        if let onTurnEvent {
            var scopedEvent = event
            scopedEvent.executionID = executionID
            onTurnEvent(scopedEvent)
        } else {
            fallback()
        }
    }

    private func runOpenRouterTurn(
        executionID: UUID,
        model: String,
        key: String,
        messages snapshot: [ChatMessage]
    ) async {
        guard sync({ activeExecution?.id == executionID }) else { return }
        do {
            var streamOptions = OpenRouterStreamOptions(
                key: key,
                model: model,
                instructions: ChatPrompt.instructions,
                messages: snapshot,
                onDelta: { [weak self] rawDelta in
                    guard let self else { return }
                    self.sync {
                        guard self.activeExecution?.id == executionID,
                              let itemId = self.activeExecution?.openRouter?.itemId else { return }
                        self.activeExecution?.openRouter?.streamedText += rawDelta
                        let citationDelta = self.citationStream.push(rawDelta, sources: self.orderedCitations())
                        let delta = self.linkStream.push(citationDelta)
                        guard !delta.isEmpty else { return }
                        self.emitTurnEvent(BridgeEvent(type: "delta", itemId: itemId, delta: delta), executionID: executionID) {
                            self.onDelta?(delta, itemId)
                        }
                    }
                },
                onSearching: { [weak self] in
                    guard let self else { return }
                    self.sync {
                        guard self.activeExecution?.id == executionID else { return }
                        self.emitTurnEvent(BridgeEvent(type: "searching"), executionID: executionID) {
                            self.onSearching?()
                        }
                    }
                },
                onCitation: { [weak self] source in
                    guard let self else { return }
                    self.sync {
                        guard self.activeExecution?.id == executionID else { return }
                        self.recordCitation(source)
                    }
                },
                onReasoning: { [weak self] reasoning in
                    guard let self else { return }
                    self.sync {
                        guard self.activeExecution?.id == executionID else { return }
                        self.activeExecution?.openRouter?.reasoning = reasoning.isEmpty ? nil : reasoning
                    }
                },
                fetch: options.openRouterFetch
            )
            streamOptions.checkDispatch = { [weak self] in
                guard let self, self.sync({ self.activeExecution?.id == executionID }) else {
                    throw CancellationError()
                }
            }
            let fullText = try await OpenRouterClient.streamTurn(streamOptions)
            sync { finishOpenRouterTurn(executionID: executionID, outcome: .completed(fullText)) }
        } catch is CancellationError {
            sync { finishOpenRouterTurn(executionID: executionID, outcome: .stopped) }
        } catch {
            sync { finishOpenRouterTurn(executionID: executionID, outcome: .failed(error)) }
        }
    }

    private enum OpenRouterOutcome {
        case completed(String)
        case stopped
        case failed(Error)
    }

    // The caller holds the lock. Only the first terminal action can take the active reply.
    private func finishOpenRouterTurn(executionID: UUID, outcome: OpenRouterOutcome) {
        guard activeExecution?.id == executionID, let reply = activeExecution?.openRouter else { return }
        activeExecution = nil

        let rawText: String
        let reasoning: String?
        switch outcome {
        case .completed(let fullText):
            rawText = fullText.isEmpty ? reply.streamedText : fullText
            reasoning = reply.reasoning
        case .stopped:
            reply.task?.cancel()
            rawText = reply.streamedText
            reasoning = nil
        case .failed(let error):
            emitTurnEvent(BridgeEvent(type: "error", message: StateStore.friendlyError(error), busy: false, codexRetry: codexRetryLocked()), executionID: executionID) {
                onError?(error)
            }
            return
        }

        let text = RenderNormalizer.normalizeAssistantText(rawText, sources: orderedCitations())
        if !text.isEmpty {
            conversation.messages.append(ChatMessage(id: reply.itemId, role: "assistant", text: text, reasoning: reasoning))
        }
        let saveWarning: String?
        do {
            try conversation.save(model: model, to: options.stateURL, env: options.env)
            saveWarning = nil
        } catch {
            saveWarning = "Couldn’t save this turn locally. It may be missing after reopening."
        }
        if !text.isEmpty || !reply.streamedText.isEmpty {
            emitTurnEvent(BridgeEvent(type: "message", itemId: reply.itemId, text: text), executionID: executionID) {
                if !text.isEmpty { onMessage?(reply.itemId, text) }
            }
        }
        emitTurnEvent(BridgeEvent(type: "done", stateSaveError: saveWarning, codexRetry: codexRetryLocked()), executionID: executionID) {
            onDone?()
        }
    }

    /// Record Stop synchronously. Only a bound Codex interrupt needs an asynchronous RPC.
    @discardableResult
    public func requestStop(executionID: UUID? = nil) -> Task<Void, Never>? {
        sync {
            guard let execution = activeExecution, executionID == nil || execution.id == executionID else { return nil }
            if execution.openRouter != nil {
                finishOpenRouterTurn(executionID: execution.id, outcome: .stopped)
                return nil
            }
            guard let currentTurn = turnId else {
                interruptPending = true
                return nil
            }
            guard let currentThread = conversation.attachedThreadId else { return nil }
            interruptPending = false
            return Task { [rpc] in
                _ = try? await rpc.request(method: "turn/interrupt", params: ["threadId": currentThread, "turnId": currentTurn], timeoutMs: 30_000)
            }
        }
    }

    public func interrupt() async {
        await requestStop()?.value
    }

    public func close() async {
        let (task, dir) = sync {
            let task = activeExecution?.openRouter?.task
            if activeExecution?.openRouter != nil { activeExecution = nil }
            let dir = runtimeDir
            runtimeDir = nil
            return (task, dir)
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
            sync {
                guard activeExecution?.openRouter == nil else { return }
                requestStop()
                onError?(NSError(domain: "SpeedChat.Client", code: 8, userInfo: [NSLocalizedDescriptionKey: "Blocked an unexpected client tool or local action request."]))
            }
            return
        }

        lock.lock()
        guard let active = codexTurn,
              let attachedThreadId = conversation.attachedThreadId,
              active.attempt.threadId == attachedThreadId,
              params["threadId"] as? String == attachedThreadId else {
            lock.unlock()
            return
        }
        let turn = params["turn"] as? [String: Any]
        let notificationTurnId = (method.hasPrefix("turn/") ? turn?["id"] : nil) ?? params["turnId"]
        guard let notificationTurnId = notificationTurnId as? String, !notificationTurnId.isEmpty else {
            lock.unlock()
            return
        }

        if active.awaitingDeliveryCheck {
            codexTurn?.deferredNotifications.append(notification)
            lock.unlock()
            return
        }

        if (method == "item/started" || method == "item/completed"),
           let item = params["item"] as? [String: Any], item["type"] as? String == "userMessage" {
            var shouldInterrupt = false
            if !active.receiptConfirmed, let input = CodexHistory.UserInput(item: item),
               active.attempt.matchesReceipt(threadId: attachedThreadId, turnId: notificationTurnId, input: input),
               conversation.recordCodexReceipt(active.attempt, turnId: notificationTurnId) {
                codexTurn?.receiptConfirmed = true
                if let error = codexStateSaveFailure() { onError?(error) }
                if active.attempt.turnId == nil {
                    shouldInterrupt = bindCodexTurn(notificationTurnId)
                }
            }
            lock.unlock()
            if shouldInterrupt { Task { await self.interrupt() } }
            return
        }

        if method == "turn/completed", let turn,
           applyCodexTurnItems(CodexHistory(turns: [turn]), threadId: attachedThreadId) != nil,
           active.attempt.turnId == nil {
            _ = bindCodexTurn(notificationTurnId)
        }

        guard let active = codexTurn else {
            lock.unlock()
            return
        }
        guard let activeTurnId = active.attempt.turnId else {
            codexTurn?.deferredNotifications.append(notification)
            lock.unlock()
            return
        }
        guard notificationTurnId == activeTurnId else {
            lock.unlock()
            return
        }

        if method == "item/agentMessage/delta" {
            let rawDelta = (params["delta"] as? String) ?? ""
            let itemId = (params["itemId"] as? String) ?? ""
            guard !conversation.messages.contains(where: { $0.id == itemId && $0.role == "assistant" }) else {
                lock.unlock()
                return
            }
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
                    let changed = conversation.placeCodexReply(
                        ChatMessage(id: itemId, role: "assistant", text: normalized),
                        after: active.attempt.userMessageId, followsConfirmedPrompt: active.receiptConfirmed
                    )
                    if changed { saveCurrentState() }
                    lock.unlock()
                    if changed { onMessage?(itemId, normalized) }
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

        if method == "model/rerouted" {
            let actualModel = (params["toModel"] as? String) ?? ""
            lock.unlock()
            if !actualModel.isEmpty {
                onModel?(actualModel)
            }
            return
        }

        if method == "turn/completed" {
            finishCodexTurn()
            saveCurrentState()
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
