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

    private var closeTask: Task<Void, Never>?
    private var conversation = ConversationContinuity()
    private var mutationPending = false
    private var checkedCodexSendId: String?
    private var undispatchedCodexMessage: ChatMessage?

    private struct PendingSend {
        let user: ChatMessage
        let thread: ConversationContinuity.Thread
        let model: String
        let openRouterKey: String?
    }

    private struct PendingCodexRetry {
        let send: PendingSend
        let attempt: CodexSendAttempt?
        let action: CodexRetry.Action
        let resend: Bool
    }

    private struct ActiveExecution {
        let id: UUID
        let user: ChatMessage
        var pendingSend: PendingSend?
        var pendingCodexRetry: PendingCodexRetry?
        var openRouter: OpenRouterReply?
        var codexReply: CodexReply?
        var codexStop: CodexStop?
        var codexToolBlocked = false
    }

    private enum CodexStop {
        case requested, dispatched
    }

    private struct OpenRouterReply {
        let itemId = "or-msg-\(UUID().uuidString.lowercased())"
        var task: Task<Void, Never>?
        var request: Task<OpenRouterHTTPResponse, Error>?
        var streamedText = ""
        var reasoning: String?
    }

    private var activeExecution: ActiveExecution?

    private struct CodexReply {
        var attempt: CodexSendAttempt
        var receiptConfirmed = false
        var deferredNotifications = [CodexNotification]()
    }

    // A timed-out wire attempt may still yield evidence on its attached thread.
    // Its notifications cannot update a reply until a delivery check adopts it.
    private var uncheckedCodexReply: CodexReply?

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
        case .confirmed:
            guard uncheckedCodexReply?.attempt.clientId == attempt.clientId,
                  uncheckedCodexReply?.receiptConfirmed == true else { return nil }
            action = .recoverReply
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
        sync {
            guard closeTask == nil else { return }
            if let attached = conversation.attachedThreadId {
                conversation.thread = .detached(attached)
            }
            uncheckedCodexReply = nil
            codexAvailable = false
            openAiModels = []
            rebuildModelCatalog()

            let error = NSError(domain: "SpeedChat.Client", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The Codex app-server stopped unexpectedly.",
            ])
            let openRouterReady = !openRouterConfig.key.isEmpty
            if let execution = activeExecution, execution.openRouter == nil {
                if !openRouterReady {
                    rpc.retire()
                    activeExecution = nil
                    if conversation.lastCodexSend?.userMessageId != execution.user.id {
                        conversation.recordUndispatchedCodexPrompt(execution.user)
                    }
                    let saveFailure = codexStateSaveFailure()
                    let message = [StateStore.friendlyError(error), saveFailure?.localizedDescription]
                        .compactMap { $0 }.joined(separator: " ")
                    emitTurnEvent(BridgeEvent(type: "fatal", message: message),
                                  executionID: execution.id) { onFatal?(saveFailure ?? error) }
                } else if execution.codexReply != nil {
                    activeExecution = nil
                    emitCodexError(error, executionID: execution.id, busy: false)
                }
            } else if activeExecution == nil && !openRouterReady {
                onFatal?(error)
            }
        }
    }

    private func ensureCodexRunning(executionID: UUID? = nil) async throws {
        func requireCurrentExecution() throws {
            try requireOpen()
            if let executionID, activeExecution?.id != executionID { throw CodexRequestNotSent() }
        }
        let (available, dir) = try sync {
            try requireCurrentExecution()
            return (codexAvailable, runtimeDir)
        }
        guard !available else { return }
        try await rpc.start(cwd: dir)
        try sync { try requireCurrentExecution() }
        try await loadModels()
        try sync {
            try requireCurrentExecution()
            codexAvailable = true
            rebuildModelCatalog()
        }
    }

    private func nameFromContent(_ text: String, threadId expectedThread: String? = nil) async {
        let namingRequest = sync { () -> (threadId: String, prompt: String)? in
            guard closeTask == nil, let threadId = conversation.attachedThreadId,
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
                if closeTask == nil, conversation.attachedThreadId == currentThread {
                    conversation.titleNeeded = false
                }
            }
        } catch {
            // Naming is optional; retry on the next message without failing chat.
        }
    }

    // The caller holds the conversation lock.
    private func requireOpen() throws {
        if closeTask != nil { throw CancellationError() }
    }

    private func saveCurrentState() {
        guard closeTask == nil else { return }
        try? conversation.save(model: model, to: options.stateURL, env: options.env)
    }

    private func saveCodexState() throws {
        try requireOpen()
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
        let loadedOR = OpenRouterClient.loadConfig(from: options.openRouterConfigURL, env: options.env)
        let dir = try sync {
            try requireOpen()
            let dir = try RuntimeDiscovery.createRuntimeDirectory()
            runtimeDir = dir
            openRouterConfig = loadedOR
            return dir
        }

        var codexError: Error?
        do {
            try await ensureCodexRunning()
        } catch {
            codexError = error
            try sync {
                try requireOpen()
                codexAvailable = false
                openAiModels = []
            }
        }

        let (currentModels, state) = try sync {
            try requireOpen()
            rebuildModelCatalog()
            return (models, StateStore.load(from: options.stateURL, env: options.env))
        }
        if currentModels.isEmpty {
            let error = codexError ?? NSError(domain: "SpeedChat.Client", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No available models support low reasoning effort.",
            ])
            guard let state else { throw error }
            return try sync {
                try requireOpen()
                model = state.model
                conversation = ConversationContinuity(restoring: state)
                return readyStateLocked(offlineReason: StateStore.friendlyError(error))
            }
        }

        let resumeRequest = try sync { () -> (threadId: String, model: String)? in
            try requireOpen()
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
                    guard closeTask == nil, codexAvailable, conversation.thread?.id == threadId else { return }
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
                sync { if closeTask == nil { conversation.didConfirmThreadLoss(threadId) } }
            } catch {
                // Keep the saved conversation ready while thread availability is unknown.
            }
        }
        return try sync {
            try requireOpen()
            let offlineReason = models.isEmpty ? "The Codex app-server stopped unexpectedly." : nil
            return readyStateLocked(offlineReason: offlineReason, stateSaveError: saveFailure?.localizedDescription)
        }
    }

    private func resumeCodexThread(
        id: String, model: String, cwdPath: String, whileCurrent: @escaping @Sendable () -> Bool = { true }
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
            timeoutMs: 30_000, whileCurrent: whileCurrent
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
            guard closeTask == nil else { return readyStateLocked() }
            openRouterConfig = updated
            rebuildModelCatalog()
            if !models.contains(where: { $0.model == model }) {
                model = Self.defaultModel(from: models)
                saveCurrentState()
            }
            return readyStateLocked()
        }
    }

    private func startCodexThread(
        model: String, cwdPath: String, whileCurrent: @escaping @Sendable () -> Bool = { true }
    ) async throws -> String {
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
            timeoutMs: 30_000, whileCurrent: whileCurrent
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
        currentThread: ConversationContinuity.Thread, model: String, executionID: UUID
    ) async throws -> CodexSendThread {
        let cwdPath = try sync {
            guard activeExecution?.id == executionID else { throw CodexRequestNotSent() }
            return runtimeDir?.path ?? ""
        }
        let whileCurrent = ownsExecution(executionID)
        switch currentThread {
        case .attached(let id):
            return .existing(id)
        case .detached(let id):
            do {
                let resumed = try await resumeCodexThread(id: id, model: model, cwdPath: cwdPath,
                                                          whileCurrent: whileCurrent)
                return try sync {
                    guard activeExecution?.id == executionID, codexAvailable,
                          conversation.thread?.id == id else { throw CodexRequestNotSent() }
                    let previousMessages = conversation.messages
                    if conversation.didResume(
                        threadId: id,
                        name: resumed.name,
                        history: CodexHistory(turns: resumed.turns)
                    ) {
                        if let error = codexStateSaveFailure() {
                            emitCodexError(error, executionID: executionID, busy: true)
                        }
                        if conversation.messages != previousMessages {
                            emitHistoryRecovered(executionID: executionID)
                        }
                    }
                    return .existing(id)
                }
            } catch let error as CodexRPCError where error.confirmsMissingRollout(for: id) {
                try sync {
                    guard activeExecution?.id == executionID else { throw CodexRequestNotSent() }
                    conversation.didConfirmThreadLoss(id)
                }
            }
        case .standalone, .missing:
            break
        }

        return .started(try await startCodexThread(model: model, cwdPath: cwdPath, whileCurrent: whileCurrent))
    }

    public func newChat() async throws -> ReadyState {
        let (isCodexUp, codexModel, cwdPath) = try sync { () -> (Bool, String, String) in
            try requireOpen()
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
        let ready = try sync {
            try requireOpen()
            conversation = ConversationContinuity(thread: thread, titleNeeded: isCodexUp)
            checkedCodexSendId = nil
            undispatchedCodexMessage = nil
            uncheckedCodexReply = nil
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
            try requireOpen()
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
        return try sync {
            try requireOpen()
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

    /// Reserve Retry or Resend before its provider work can race with Stop.
    public func acceptCodexRetry(userMessageId: String?, resend: Bool, executionID: UUID) throws {
        try sync {
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
            let send = PendingSend(user: message, thread: thread, model: model, openRouterKey: nil)
            beginTurn(ActiveExecution(id: executionID, user: message, pendingCodexRetry: PendingCodexRetry(
                send: send, attempt: conversation.lastCodexSend, action: retry.action, resend: resend
            )))
        }
    }

    public func retryCodexSend(userMessageId: String? = nil, resend: Bool = false) async throws -> ReadyState? {
        let executionID = UUID()
        try acceptCodexRetry(userMessageId: userMessageId, resend: resend, executionID: executionID)
        return try await startCodexRetry(executionID: executionID)
    }

    public func startCodexRetry(executionID: UUID) async throws -> ReadyState? {
        let pending = sync { () -> PendingCodexRetry? in
            guard activeExecution?.id == executionID else { return nil }
            let pending = activeExecution?.pendingCodexRetry
            activeExecution?.pendingCodexRetry = nil
            return pending
        }
        guard let pending else { return nil }
        if pending.action == .retry {
            return try await sendCodex(pending.send, executionID: executionID)
        }

        guard let attempt = pending.attempt else {
            return sync { finishCodexCheck(executionID: executionID) }
        }
        enum DeliveryCheck {
            case checked(ReadyState?)
            case streaming(interrupt: Task<Void, Never>?)
            case resend
        }

        let history = await readCodexHistory(threadId: attempt.threadId, executionID: executionID)
        let result = sync { () -> DeliveryCheck in
            guard activeExecution?.id == executionID else { return .checked(nil) }
            checkedCodexSendId = attempt.clientId
            // A by-ID read does not subscribe. Only this still-attached attempt
            // can resume its original stream or consume buffered notifications.
            let canResume = codexAvailable && conversation.attachedThreadId == attempt.threadId &&
                uncheckedCodexReply?.attempt.clientId == attempt.clientId
            if canResume, let reply = uncheckedCodexReply {
                let completedTurns = reply.deferredNotifications.compactMap { notification -> [String: Any]? in
                    guard notification.method == "turn/completed" else { return nil }
                    return notification.params["turn"] as? [String: Any]
                }
                let completedHistory = CodexHistory(turns: completedTurns)
                if completedHistory.matchingReceipt(for: reply.attempt, threadId: attempt.threadId) != nil {
                    activeExecution?.codexReply = reply
                    uncheckedCodexReply = nil
                    if let id = applyCodexTurnItems(
                        completedHistory, threadId: attempt.threadId, executionID: executionID, resumingReply: true
                    ) {
                        return .streaming(interrupt: bindCodexTurn(id, executionID: executionID))
                    }
                }
            }
            if let history {
                if case .missing(let id) = conversation.thread, id == attempt.threadId {
                    conversation.thread = .detached(id)
                }
                if let recorded = conversation.reconcileCodexSend(threadId: attempt.threadId, history: history) {
                    let saveFailure = codexStateSaveFailure()
                    if canResume, var reply = uncheckedCodexReply, let id = recorded.id {
                        let isInProgress = recorded.status == "inProgress" &&
                            (history.isThreadActive || reply.receiptConfirmed)
                        let hasBufferedCompletion = reply.deferredNotifications.contains { notification in
                            guard notification.method == "turn/completed",
                                  let turn = notification.params["turn"] as? [String: Any] else { return false }
                            return turn["id"] as? String == id
                        }
                        if isInProgress || hasBufferedCompletion {
                            reply.receiptConfirmed = true
                            return .streaming(interrupt: resumeUncheckedCodexReply(
                                reply, turnID: id, executionID: executionID, saveFailure: saveFailure
                            ))
                        }
                    }
                    uncheckedCodexReply = nil
                    return .checked(finishCodexCheck(executionID: executionID, saveFailure: saveFailure))
                }
            }
            if canResume, let reply = uncheckedCodexReply, reply.receiptConfirmed, let id = reply.attempt.turnId {
                return .streaming(interrupt: resumeUncheckedCodexReply(
                    reply, turnID: id, executionID: executionID, saveFailure: codexStateSaveFailure()
                ))
            }
            if pending.resend, conversation.lastCodexSend?.delivery == .unconfirmed {
                return .resend
            }
            return .checked(finishCodexCheck(executionID: executionID))
        }
        switch result {
        case .checked(let ready):
            return ready
        case .streaming(let interrupt):
            await interrupt?.value
            return nil
        case .resend:
            return try await sendCodex(pending.send, executionID: executionID, replacing: attempt)
        }
    }

    private func resumeUncheckedCodexReply(
        _ reply: CodexReply, turnID: String, executionID: UUID, saveFailure: Error?
    ) -> Task<Void, Never>? {
        activeExecution?.codexReply = reply
        uncheckedCodexReply = nil
        emitCodexReplyResumed(userMessageId: reply.attempt.userMessageId, executionID: executionID)
        if let saveFailure { emitCodexError(saveFailure, executionID: executionID, busy: true) }
        return bindCodexTurn(turnID, executionID: executionID)
    }

    private func resumeCodexReplyConfirmedDuringResend(
        replacing previous: CodexSendAttempt?, executionID: UUID
    ) -> Bool {
        guard let previous, let reply = uncheckedCodexReply, reply.receiptConfirmed,
              let turnID = reply.attempt.turnId, reply.attempt.clientId == previous.clientId,
              conversation.lastCodexSend?.clientId == previous.clientId,
              codexAvailable, conversation.attachedThreadId == reply.attempt.threadId else { return false }
        _ = resumeUncheckedCodexReply(
            reply, turnID: turnID, executionID: executionID, saveFailure: codexStateSaveFailure()
        )
        return true
    }

    private func finishCodexCheck(executionID: UUID, saveFailure: Error? = nil) -> ReadyState? {
        guard activeExecution?.id == executionID else { return nil }
        activeExecution = nil
        let ready = readyStateLocked(stateSaveError: saveFailure?.localizedDescription)
        emitTurnEvent(BridgeEvent(
            type: "conversationUpdated", messages: ready.messages,
            notice: ready.codexRetry == nil ? "Codex received this message." : nil,
            stateSaveError: ready.stateSaveError, codexRetry: ready.codexRetry
        ), executionID: executionID) {}
        return ready
    }

    private func readCodexHistory(threadId: String, executionID: UUID) async -> CodexHistory? {
        do {
            try await ensureCodexRunning(executionID: executionID)
            let result = try await rpc.request(
                method: "thread/read",
                params: ["threadId": threadId, "includeTurns": true],
                timeoutMs: 30_000, whileCurrent: ownsExecution(executionID)
            )
            guard let thread = result["thread"] as? [String: Any], thread["id"] as? String == threadId,
                  let turns = thread["turns"] as? [[String: Any]] else { return nil }
            let status = thread["status"] as? [String: Any]
            return CodexHistory(turns: turns, isThreadActive: status?["type"] as? String == "active")
        } catch {
            return nil
        }
    }

    private func ownsExecution(_ executionID: UUID) -> @Sendable () -> Bool {
        { [weak self] in
            guard let self else { return false }
            return self.sync { self.activeExecution?.id == executionID }
        }
    }

    private func threadForNewTurn() throws -> ConversationContinuity.Thread {
        try requireOpen()
        guard !busy else {
            throw NSError(domain: "SpeedChat.Client", code: 4, userInfo: [NSLocalizedDescriptionKey: "Wait for the current response or change to finish."])
        }
        guard let thread = conversation.thread else {
            throw NSError(domain: "SpeedChat.Client", code: 6, userInfo: [NSLocalizedDescriptionKey: "Chat is not ready."])
        }
        return thread
    }

    private func beginTurn(_ execution: ActiveExecution) {
        activeExecution = execution
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
                user: user,
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

        if let key = pending.openRouterKey {
            if onTurnEvent == nil { onModel?(pending.model) }
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
            _ = try await sendCodex(pending, executionID: executionID)
        }
    }

    private func sendCodex(
        _ send: PendingSend, executionID: UUID, replacing previous: CodexSendAttempt? = nil
    ) async throws -> ReadyState? {
        let user = send.user
        let currentModel = send.model
        let canStart = sync {
            guard activeExecution?.id == executionID else { return false }
            emitTurnEvent(BridgeEvent(type: "activeModel", model: currentModel), executionID: executionID) {
                onModel?(currentModel)
            }
            return true
        }
        guard canStart else { return nil }
        var dispatchedAttempt: CodexSendAttempt?
        var beforeResend: (conversation: ConversationContinuity, uncheckedReply: CodexReply?)?
        var journalSaveFailed = false
        do {
            try await ensureCodexRunning(executionID: executionID)
            let currentThread = sync { conversation.thread ?? send.thread }
            let target = try await codexThreadForSend(
                currentThread: currentThread, model: currentModel, executionID: executionID
            )
            let codexThread = target.id
            let prepared = try sync { () -> (CodexSendAttempt, String)? in
                guard activeExecution?.id == executionID else { throw CodexRequestNotSent() }
                if let previous, conversation.lastCodexSend?.clientId == previous.clientId {
                    if conversation.lastCodexSend?.delivery == .confirmed { return nil }
                    beforeResend = (conversation, uncheckedCodexReply)
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
                if previous == nil { uncheckedCodexReply = nil }
                activeExecution?.codexReply = CodexReply(attempt: attempt)
                return (attempt, runtimeDir?.path ?? "")
            }

            guard let (attempt, cwdPath) = prepared else {
                return sync {
                    guard activeExecution?.id == executionID,
                          !resumeCodexReplyConfirmedDuringResend(replacing: previous, executionID: executionID) else {
                        return nil
                    }
                    return finishCodexCheck(executionID: executionID)
                }
            }
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
                timeoutMs: 30_000, whileCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.sync {
                        guard self.activeExecution?.id == executionID,
                              self.conversation.lastCodexSend?.clientId == attempt.clientId else { return false }
                        // Keep the old attempt eligible for a verified receipt
                        // until the serialized transport is ready to dispatch.
                        self.uncheckedCodexReply = nil
                        return true
                    }
                }
            )
            let interrupt = try sync { () -> Task<Void, Never>? in
                guard activeExecution?.id == executionID, let reply = activeExecution?.codexReply,
                      reply.attempt.clientId == attempt.clientId else { return nil }
                guard let turn = response["turn"] as? [String: Any],
                      let id = turn["id"] as? String, !id.isEmpty,
                      reply.attempt.turnId == nil || reply.attempt.turnId == id else {
                    throw NSError(domain: "SpeedChat.Client", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid Codex turn acknowledgement."])
                }
                _ = applyCodexTurnItems(
                    CodexHistory(turns: [turn]), threadId: codexThread, executionID: executionID
                )
                if let status = turn["status"] as? String, ["completed", "interrupted", "failed"].contains(status) {
                    let completion = CodexNotification(method: "turn/completed", params: [
                        "threadId": codexThread, "turn": turn,
                    ])
                    if reply.attempt.turnId == nil {
                        activeExecution?.codexReply?.deferredNotifications.append(completion)
                        return bindCodexTurn(id, executionID: executionID)
                    }
                    handleNotification(completion)
                    return nil
                }
                guard reply.attempt.turnId == nil else { return nil }
                return bindCodexTurn(id, executionID: executionID)
            }

            await interrupt?.value
            await nameFromContent(user.text, threadId: codexThread)
            return nil
        } catch let sendError {
            let report = sync { () -> Error? in
                guard activeExecution?.id == executionID else {
                    // An in-progress preparation throws to its caller even
                    // when the disconnect has already settled its UI state.
                    return closeTask == nil && !codexAvailable && dispatchedAttempt == nil ? sendError : nil
                }
                guard !resumeCodexReplyConfirmedDuringResend(replacing: previous, executionID: executionID)
                else { return nil }
                guard let dispatchedAttempt else {
                    // A retry that never reached turn/start cannot replace old
                    // evidence about this same prompt.
                    guard conversation.lastCodexSend?.userMessageId != user.id else {
                        return failCodexSend(sendError, executionID: executionID)
                    }
                    if journalSaveFailed {
                        undispatchedCodexMessage = user
                        return failCodexSend(sendError, executionID: executionID)
                    }
                    let beforeRejection = conversation
                    conversation.recordUndispatchedCodexPrompt(user)
                    do {
                        try saveCodexState()
                        undispatchedCodexMessage = nil
                        return failCodexSend(sendError, executionID: executionID)
                    } catch {
                        conversation = beforeRejection
                        undispatchedCodexMessage = user
                        return failCodexSend(error, executionID: executionID)
                    }
                }
                guard let reply = activeExecution?.codexReply, reply.attempt.clientId == dispatchedAttempt.clientId,
                      !reply.receiptConfirmed else { return nil }
                let rpcError = sendError as? CodexRPCError
                let unloaded = rpcError?.confirmsUnloadedThread(for: dispatchedAttempt.threadId) == true
                let rejected = unloaded || rpcError?.confirmsInputRejection == true || sendError is CodexRequestNotSent
                var report = sendError
                if rejected {
                    if let beforeResend {
                        conversation = beforeResend.conversation
                        uncheckedCodexReply = beforeResend.uncheckedReply
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
                    uncheckedCodexReply = reply
                }
                return failCodexSend(report, executionID: executionID)
            }
            if let report { throw report }
            return nil
        }
    }

    private func failCodexSend(_ error: Error, executionID: UUID) -> Error {
        activeExecution = nil
        // Direct callers receive the throw. The bridge needs the metadata
        // captured with this outcome, before another execution can start.
        emitCodexError(error, executionID: executionID, busy: false, reportToLegacy: false)
        return error
    }

    private func applyCodexTurnItems(
        _ history: CodexHistory, threadId: String, executionID: UUID, resumingReply: Bool = false
    ) -> String? {
        guard activeExecution?.id == executionID, let reply = activeExecution?.codexReply,
              let (turn, itemId) = history.matchingReceipt(for: reply.attempt, threadId: threadId),
              let turnId = turn.id,
              reply.receiptConfirmed || conversation.recordCodexReceipt(reply.attempt, turnId: turnId) else { return nil }
        activeExecution?.codexReply?.receiptConfirmed = true
        let existingIds = Set(conversation.messages.map(\.id))
        let recovered = conversation.recoverReplies(
            in: turn, threadId: threadId, after: itemId, for: reply.attempt.userMessageId
        )
        let saveFailure = !reply.receiptConfirmed || recovered ? codexStateSaveFailure() : nil
        if resumingReply {
            emitCodexReplyResumed(userMessageId: reply.attempt.userMessageId, executionID: executionID)
        }
        if let saveFailure { emitCodexError(saveFailure, executionID: executionID, busy: true) }
        if recovered {
            emitHistoryRecovered(executionID: executionID)
            for reply in conversation.messages where !existingIds.contains(reply.id) {
                emitTurnEvent(BridgeEvent(type: "message", itemId: reply.id, text: reply.text), executionID: executionID) {
                    onMessage?(reply.id, reply.text)
                }
            }
        }
        return turnId
    }

    private func emitHistoryRecovered(executionID: UUID) {
        let messages = conversation.messages
        emitTurnEvent(BridgeEvent(type: "historyRecovered", messages: messages), executionID: executionID) {
            onHistoryRecovered?(messages)
        }
    }

    private func emitCodexReplyResumed(userMessageId: String, executionID: UUID) {
        let messages = conversation.messages
        emitTurnEvent(BridgeEvent(type: "codexReplyResumed", messages: messages, itemId: userMessageId),
                      executionID: executionID) {
            onCodexReplyResumed?(userMessageId, messages)
        }
    }

    private func emitCodexError(
        _ error: Error, executionID: UUID, busy: Bool, reportToLegacy: Bool = true
    ) {
        emitTurnEvent(BridgeEvent(
            type: "error", message: StateStore.friendlyError(error), busy: busy, codexRetry: codexRetryLocked()
        ), executionID: executionID) {
            if reportToLegacy { onError?(error) }
        }
    }

    // Both the acknowledged turn and an exact prompt receipt can bind an attempt.
    // Other notifications wait for that binding so a late turn cannot claim a new send.
    private func bindCodexTurn(_ id: String, executionID: UUID) -> Task<Void, Never>? {
        guard activeExecution?.id == executionID, let reply = activeExecution?.codexReply else { return nil }
        activeExecution?.codexReply?.deferredNotifications.removeAll()
        activeExecution?.codexReply?.attempt.turnId = id
        if conversation.lastCodexSend?.clientId == reply.attempt.clientId,
           conversation.lastCodexSend?.turnId != id {
            conversation.lastCodexSend?.turnId = id
            saveCurrentState()
        }
        for notification in reply.deferredNotifications where activeExecution?.id == executionID {
            handleNotification(notification)
        }
        return dispatchCodexInterrupt(executionID: executionID)
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
            streamOptions.dispatch = { [weak self] request, fetch in
                guard let self else { throw CancellationError() }
                return try self.sync {
                    guard self.activeExecution?.id == executionID else { throw CancellationError() }
                    // Registering the request task commits this dispatch. Stop
                    // takes the same lock and cancels any committed request.
                    let task = Task {
                        try Task.checkCancellation()
                        return try await fetch(request)
                    }
                    self.activeExecution?.openRouter?.request = task
                    return task
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
            reply.request?.cancel()
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
        guard closeTask == nil else { return }
        if !text.isEmpty {
            emitTurnEvent(BridgeEvent(type: "message", itemId: reply.itemId, text: text), executionID: executionID) {
                onMessage?(reply.itemId, text)
            }
        } else if !reply.streamedText.isEmpty {
            emitTurnEvent(BridgeEvent(type: "replyPlaceholderRemoved", itemId: reply.itemId), executionID: executionID) {}
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
            guard execution.codexStop == nil else { return nil }
            activeExecution?.codexStop = .requested
            return dispatchCodexInterrupt(executionID: execution.id)
        }
    }

    private func dispatchCodexInterrupt(executionID: UUID) -> Task<Void, Never>? {
        guard activeExecution?.id == executionID, activeExecution?.codexStop == .requested,
              let attempt = activeExecution?.codexReply?.attempt,
              let currentTurn = attempt.turnId, conversation.attachedThreadId == attempt.threadId else { return nil }
        let currentThread = attempt.threadId
        activeExecution?.codexStop = .dispatched
        let isCurrent: @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.sync {
                self.activeExecution?.id == executionID &&
                    self.activeExecution?.codexReply?.attempt.turnId == currentTurn &&
                    self.activeExecution?.codexReply?.attempt.threadId == currentThread &&
                    self.conversation.attachedThreadId == currentThread
            }
        }
        return Task { [weak self, rpc] in
            do {
                _ = try await rpc.request(
                    method: "turn/interrupt",
                    params: ["threadId": currentThread, "turnId": currentTurn],
                    timeoutMs: 30_000, whileCurrent: isCurrent
                )
            } catch {
                guard let self else { return }
                self.sync {
                    guard isCurrent() else { return }
                    self.activeExecution?.codexStop = nil
                    self.emitCodexError(NSError(domain: "SpeedChat.Client", code: 12, userInfo: [
                        NSLocalizedDescriptionKey: "Couldn’t stop the Codex response. \(StateStore.friendlyError(error))",
                    ]), executionID: executionID, busy: true)
                }
            }
        }
    }

    public func interrupt() async {
        await requestStop()?.value
    }

    /// Settle accepted content and retire this client before the bridge releases its command queue.
    public func beginClose() -> Task<Void, Never> {
        sync {
            if let closeTask { return closeTask }
            rpc.retire()
            let dir = runtimeDir
            runtimeDir = nil
            let teardown = Task { [rpc] in
                await rpc.stop()
                if let dir {
                    try? FileManager.default.removeItem(at: dir)
                }
            }
            closeTask = teardown
            if let executionID = activeExecution?.id {
                finishOpenRouterTurn(executionID: executionID, outcome: .stopped)
            }
            activeExecution = nil
            uncheckedCodexReply = nil
            codexAvailable = false
            return teardown
        }
    }

    public func close() async {
        await beginClose().value
    }

    private func loadModels() async throws {
        let response = try await rpc.request(method: "model/list", params: ["limit": 100, "includeHidden": false], timeoutMs: 30_000)
        let rawList = (response["data"] as? [[String: Any]]) ?? []
        let filtered = Self.availableModels(from: rawList)
        let hasORKey = try sync { () -> Bool in
            try requireOpen()
            openAiModels = filtered
            return !openRouterConfig.key.isEmpty
        }

        if filtered.isEmpty && !hasORKey {
            throw NSError(domain: "SpeedChat.Client", code: 2, userInfo: [NSLocalizedDescriptionKey: "No available models support low reasoning effort."])
        }
    }

    private func handleNotification(_ notification: CodexNotification) {
        sync {
            let method = notification.method
            let params = notification.params
            if method == "speedchat/blockedRequest" {
                guard let execution = activeExecution, let attempt = execution.codexReply?.attempt else { return }
                if let threadID = params["threadId"] as? String, threadID != attempt.threadId { return }
                let reportedTurnID = params["turnId"] as? String
                if reportedTurnID != nil, attempt.turnId == nil {
                    activeExecution?.codexReply?.deferredNotifications.append(notification)
                    return
                }
                guard let boundTurn = attempt.turnId, reportedTurnID == nil || reportedTurnID == boundTurn else { return }
                requestStop(executionID: execution.id)
                emitCodexError(NSError(domain: "SpeedChat.Client", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "Blocked an unexpected client tool or local action request.",
                ]), executionID: execution.id, busy: true)
                return
            }

            guard let threadID = conversation.attachedThreadId, params["threadId"] as? String == threadID else { return }
            let turn = params["turn"] as? [String: Any]
            let wireTurnID = (method.hasPrefix("turn/") ? turn?["id"] : nil) ?? params["turnId"]
            guard let turnID = wireTurnID as? String, !turnID.isEmpty else { return }
            guard let executionID = activeExecution?.id, let reply = activeExecution?.codexReply,
                  reply.attempt.threadId == threadID, uncheckedCodexReply?.attempt.threadId != threadID else {
                captureLateCodexNotification(notification, threadID: threadID, turnID: turnID)
                return
            }

            if (method == "item/started" || method == "item/completed"),
               let item = params["item"] as? [String: Any], item["type"] as? String == "userMessage" {
                if !reply.receiptConfirmed, let input = CodexHistory.UserInput(item: item),
                   reply.attempt.matchesReceipt(threadId: threadID, turnId: turnID, input: input),
                   conversation.recordCodexReceipt(reply.attempt, turnId: turnID) {
                    activeExecution?.codexReply?.receiptConfirmed = true
                    if let error = codexStateSaveFailure() { emitCodexError(error, executionID: executionID, busy: true) }
                    if reply.attempt.turnId == nil { _ = bindCodexTurn(turnID, executionID: executionID) }
                }
                return
            }

            if method == "turn/completed", let turn,
               applyCodexTurnItems(CodexHistory(turns: [turn]), threadId: threadID, executionID: executionID) != nil,
               reply.attempt.turnId == nil {
                _ = bindCodexTurn(turnID, executionID: executionID)
            }
            guard activeExecution?.id == executionID, let boundReply = activeExecution?.codexReply else { return }
            guard let boundTurnID = boundReply.attempt.turnId else {
                activeExecution?.codexReply?.deferredNotifications.append(notification)
                return
            }
            guard turnID == boundTurnID else { return }

            switch method {
            case "item/agentMessage/delta":
                let rawDelta = (params["delta"] as? String) ?? ""
                let itemId = (params["itemId"] as? String) ?? ""
                guard !conversation.messages.contains(where: { $0.id == itemId && $0.role == "assistant" }) else { return }
                let citationDelta = citationStream.push(rawDelta, sources: orderedCitations())
                let delta = linkStream.push(citationDelta)
                if !delta.isEmpty {
                    emitTurnEvent(BridgeEvent(type: "delta", itemId: itemId, delta: delta),
                                  executionID: executionID) { onDelta?(delta, itemId) }
                }
            case "item/started", "item/completed":
                guard let item = params["item"] as? [String: Any],
                      let type = item["type"] as? String else { return }
                handleCodexItem(item, type: type, completed: method == "item/completed",
                                reply: boundReply, executionID: executionID)
            case "model/rerouted":
                if let actualModel = params["toModel"] as? String, !actualModel.isEmpty {
                    emitTurnEvent(BridgeEvent(type: "activeModel", model: actualModel), executionID: executionID) {
                        onModel?(actualModel)
                    }
                }
            case "turn/completed":
                activeExecution = nil
                saveCurrentState()
                if turn?["status"] as? String == "failed" {
                    let errDict = turn?["error"] as? [String: Any]
                    let errMsg = (errDict?["message"] as? String) ?? "The response failed."
                    emitCodexError(NSError(domain: "SpeedChat.Client", code: 10, userInfo: [
                        NSLocalizedDescriptionKey: errMsg,
                    ]), executionID: executionID, busy: false)
                } else {
                    emitTurnEvent(BridgeEvent(type: "done", codexRetry: codexRetryLocked()), executionID: executionID) {
                        onDone?()
                    }
                }
            case "error":
                let errDict = params["error"] as? [String: Any]
                let errMsg = (errDict?["message"] as? String) ?? (params["message"] as? String) ?? "Codex reported an error."
                emitCodexError(NSError(domain: "SpeedChat.Client", code: 11, userInfo: [
                    NSLocalizedDescriptionKey: errMsg,
                ]), executionID: executionID, busy: true)
            default:
                break
            }
        }
    }

    // A late exact input receipt is authoritative even when a by-ID read is
    // unavailable or stale. Keep the buffer available for the next delivery check.
    private func captureLateCodexNotification(_ notification: CodexNotification, threadID: String, turnID: String) {
        guard let attempt = uncheckedCodexReply?.attempt, attempt.threadId == threadID,
              attempt.turnId == nil || attempt.turnId == turnID else { return }
        uncheckedCodexReply?.deferredNotifications.append(notification)
        guard uncheckedCodexReply?.receiptConfirmed == false else { return }

        let verified: Bool
        switch notification.method {
        case "item/started", "item/completed":
            guard let item = notification.params["item"] as? [String: Any],
                  let input = CodexHistory.UserInput(item: item) else { return }
            verified = attempt.matchesReceipt(threadId: threadID, turnId: turnID, input: input)
        case "turn/completed":
            guard let turn = notification.params["turn"] as? [String: Any] else { return }
            verified = CodexHistory(turns: [turn]).matchingReceipt(for: attempt, threadId: threadID) != nil
        default:
            return
        }
        guard verified else { return }

        let preparedAttempt = conversation.lastCodexSend
        if let replacement = activeExecution?.codexReply?.attempt,
           preparedAttempt?.clientId == replacement.clientId {
            // A resend journal may have been saved while this notification
            // was queued. Its wire dispatch has yet to claim ownership.
            conversation.lastCodexSend = attempt
        }
        guard conversation.recordCodexReceipt(attempt, turnId: turnID) else {
            conversation.lastCodexSend = preparedAttempt
            return
        }
        uncheckedCodexReply?.receiptConfirmed = true
        uncheckedCodexReply?.attempt.turnId = turnID
        let saveFailure = codexStateSaveFailure()
        onTurnEvent?(BridgeEvent(
            type: "codexDeliveryUpdated", stateSaveError: saveFailure?.localizedDescription, codexRetry: codexRetryLocked()
        ))
    }

    private func handleCodexItem(
        _ item: [String: Any], type: String, completed: Bool, reply: CodexReply, executionID: UUID
    ) {
        if type == "webSearch" {
            if completed {
                for source in RenderNormalizer.citationSources(from: item["results"]) { recordCitation(source) }
            } else {
                emitTurnEvent(BridgeEvent(type: "searching"), executionID: executionID) { onSearching?() }
            }
            return
        }
        if type == "agentMessage", completed, item["phase"] as? String != "commentary",
           let text = item["text"] as? String {
            let itemId = (item["id"] as? String) ?? "assistant"
            citationStream.reset()
            linkStream.reset()
            let normalized = RenderNormalizer.normalizeAssistantText(text, sources: orderedCitations())
            guard !normalized.isEmpty else {
                if !conversation.messages.contains(where: { $0.id == itemId }) {
                    emitTurnEvent(BridgeEvent(type: "replyPlaceholderRemoved", itemId: itemId), executionID: executionID) {}
                }
                return
            }
            let changed = conversation.placeCodexReply(
                ChatMessage(id: itemId, role: "assistant", text: normalized),
                after: reply.attempt.userMessageId, followsConfirmedPrompt: reply.receiptConfirmed
            )
            if changed {
                saveCurrentState()
                emitTurnEvent(BridgeEvent(type: "message", itemId: itemId, text: normalized),
                              executionID: executionID) { onMessage?(itemId, normalized) }
            }
            return
        }

        let allowedTypes: Set<String> = ["userMessage", "agentMessage", "reasoning", "contextCompaction"]
        guard activeExecution?.codexToolBlocked == false,
              Self.toolItemTypes.contains(type) || !allowedTypes.contains(type) else { return }
        activeExecution?.codexToolBlocked = true
        requestStop(executionID: executionID)
        let itemId = (item["id"] as? String) ?? "blocked"
        let itemJSON = (try? JSONSerialization.data(withJSONObject: item)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let isImageAttempt = type == "imageGeneration" || type == "imageView" ||
            itemJSON.range(of: #"emitImage|image"#, options: [.regularExpression, .caseInsensitive]) != nil
        if isImageAttempt {
            let explanation = "I can’t generate or display images here—this quick-chat panel is text-only for fast conversation."
            conversation.messages.append(ChatMessage(id: itemId, role: "assistant", text: explanation))
            emitTurnEvent(BridgeEvent(type: "message", itemId: itemId, text: explanation), executionID: executionID) {
                onMessage?(itemId, explanation)
            }
        } else {
            emitCodexError(NSError(domain: "SpeedChat.Client", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "Blocked an unexpected \(type) request.",
            ]), executionID: executionID, busy: true)
        }
    }
}
