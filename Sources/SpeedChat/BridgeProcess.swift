import Foundation
import ChatCore

protocol ChatBackend: AnyObject, Sendable {
    func start(codexOverride: String, options: ChatClientOptions, onEvent: @escaping @Sendable (BridgeEvent) -> Void)
    func send(_ command: [String: String])
    func close(completion: (@Sendable () -> Void)?)
}

/// In-process native chat backend that drives `ChatClient` and coalesces streaming token deltas at ~60fps (16ms).
final class BridgeProcess: ChatBackend, @unchecked Sendable {
    typealias TurnOperation = @Sendable () async -> Void

    private let launchTurn: @Sendable (@escaping TurnOperation) -> Void
    private let queue = DispatchQueue(label: "SpeedChat.bridge", qos: .userInitiated)
    private var client: ChatClient?
    private var closing = false
    private var closeCallbacks: [@Sendable () -> Void]?
    private enum Startup {
        case connecting(exitReason: String?)
        case finished
    }
    private var startup = Startup.connecting(exitReason: nil)
    private var onEvent: (@Sendable (BridgeEvent) -> Void)?
    private var turnStartedAt: Date?
    private var firstTokenSeen = false
    private var activeExecutionID: UUID?
    private var pendingDelta: BridgeEvent?
    private var deltaTimer: DispatchWorkItem?

    init(launchTurn: @escaping @Sendable (@escaping TurnOperation) -> Void = { operation in
        Task { await operation() }
    }) {
        self.launchTurn = launchTurn
    }

    func start(
        codexOverride: String = "",
        options: ChatClientOptions = ChatClientOptions(),
        onEvent: @escaping @Sendable (BridgeEvent) -> Void
    ) {
        queue.async { [self] in
            guard !closing, client == nil else { return }
            self.onEvent = onEvent
            self.startup = .connecting(exitReason: nil)
            let rpc = JsonRpcProcess(codexOverride: codexOverride, env: options.env)
            let chatClient = ChatClient(rpc: rpc, options: options)
            self.client = chatClient

            chatClient.onTurnEvent = { [weak self] event in
                self?.enqueueReplyEvent(event)
            }
            chatClient.onFatal = { [weak self] error in
                self?.queue.async { [weak self] in
                    guard let self, !self.closing else { return }
                    let reason = StateStore.friendlyError(error)
                    if case .connecting = self.startup {
                        // The connection attempt still has to load the saved conversation.
                        self.startup = .connecting(exitReason: reason)
                        return
                    }
                    self.flushDelta()
                    self.onEvent?(BridgeEvent(type: "fatal", message: reason))
                }
            }

            Task { [weak self] in
                do {
                    let ready = try await chatClient.connect()
                    self?.queue.async { [weak self] in
                        guard let self, !self.closing else { return }
                        let startup = self.startup
                        self.startup = .finished
                        var offlineReason = ready.offlineReason
                        if case .connecting(let exitReason?) = startup {
                            guard ready.resumed else {
                                self.onEvent?(BridgeEvent(type: "fatal", message: exitReason))
                                return
                            }
                            offlineReason = offlineReason ?? exitReason
                        }
                        let notice = (ready.resumed && !ready.messages.isEmpty) ? "Resumed previous chat" : "Ready"
                        self.onEvent?(BridgeEvent(
                            type: offlineReason == nil ? "ready" : "offlineConversation",
                            conversationId: ready.conversationId,
                            messages: ready.messages,
                            models: offlineReason == nil ? ready.models : [],
                            model: ready.model,
                            notice: offlineReason.map { "Offline · \($0)" } ?? notice,
                            stateSaveError: ready.stateSaveError,
                            codexRetry: ready.codexRetry
                        ))
                    }
                } catch {
                    self?.queue.async { [weak self] in
                        guard let self, !self.closing else { return }
                        self.startup = .finished
                        self.onEvent?(BridgeEvent(type: "fatal", message: StateStore.friendlyError(error)))
                    }
                }
            }
        }
    }

    private func enqueueReplyEvent(_ event: BridgeEvent) {
        queue.async { [weak self] in
            self?.receiveReplyEvent(event)
        }
    }

    private func receiveReplyEvent(_ event: BridgeEvent) {
        guard !closing, event.executionID == nil || event.executionID == activeExecutionID else { return }
        if event.type == "delta" {
            if let pending = pendingDelta,
               pending.itemId != event.itemId || pending.executionID != event.executionID {
                flushDelta()
            }
            if let pending = pendingDelta {
                pendingDelta?.delta = (pending.delta ?? "") + (event.delta ?? "")
            } else {
                pendingDelta = event
            }
            if deltaTimer == nil {
                let work = DispatchWorkItem { [weak self] in self?.flushDelta() }
                deltaTimer = work
                queue.asyncAfter(deadline: .now() + .milliseconds(16), execute: work)
            }
            return
        }

        switch event.type {
        case "message", "replyPlaceholderRemoved", "historyRecovered", "conversationUpdated", "error", "done", "fatal":
            flushDelta()
        default:
            break
        }
        if event.type == "done" {
            emitMetric("response", executionID: event.executionID)
        }
        if event.type == "done" || event.type == "conversationUpdated" || event.type == "fatal" ||
            (event.type == "error" && event.busy != true) {
            activeExecutionID = nil
        }
        onEvent?(event)
    }

    private func emitMetric(_ name: String, executionID: UUID? = nil) {
        guard let started = turnStartedAt else { return }
        let ms = max(0, round(Date().timeIntervalSince(started) * 1000))
        onEvent?(BridgeEvent(type: "metric", name: name, durationMs: ms, executionID: executionID))
    }

    private func flushDelta() {
        deltaTimer?.cancel()
        deltaTimer = nil
        guard let pending = pendingDelta else { return }
        pendingDelta = nil
        if !firstTokenSeen {
            firstTokenSeen = true
            emitMetric("first-token", executionID: pending.executionID)
        }
        onEvent?(pending)
    }

    func send(_ command: [String: String]) {
        queue.async { [self] in
            guard !closing, let chatClient = client else {
                if !closing {
                    onEvent?(BridgeEvent(type: "fatal", message: "The backend is not running. Reconnect to resume."))
                }
                return
            }
            let type = command["type"] ?? ""
            let requestedExecutionID = command["executionID"].flatMap(UUID.init(uuidString:))
            if type == "send" || type == "retryCodex" || type == "resendCodex" {
                let executionID = requestedExecutionID ?? UUID()
                do {
                    if type == "send" {
                        let text = (command["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        let userMessageId = command["itemId"] ?? UUID().uuidString.lowercased()
                        try chatClient.acceptSend(text, userMessageId: userMessageId, executionID: executionID)
                    } else {
                        guard let userMessageId = command["itemId"] else { return }
                        try chatClient.acceptCodexRetry(userMessageId: userMessageId, resend: type == "resendCodex",
                                                        executionID: executionID)
                    }
                } catch {
                    onEvent?(BridgeEvent(type: "error", message: StateStore.friendlyError(error),
                                         busy: chatClient.busy, codexRetry: chatClient.codexRetry,
                                         executionID: requestedExecutionID))
                    return
                }
                activeExecutionID = executionID
                turnStartedAt = Date()
                firstTokenSeen = false
                launchTurn {
                    // ChatCore publishes failures with the execution that
                    // produced them and the resulting retry state.
                    if type == "send" {
                        try? await chatClient.startSend(executionID: executionID)
                    } else {
                        _ = try? await chatClient.startCodexRetry(executionID: executionID)
                    }
                }
                return
            }
            if type == "newChat" {
                Task { [weak self] in
                    do {
                        let ready = try await chatClient.newChat()
                        self?.queue.async { [weak self] in
                            guard let self, !self.closing else { return }
                            self.onEvent?(BridgeEvent(
                                type: "ready",
                                conversationId: ready.conversationId,
                                messages: ready.messages,
                                models: ready.models,
                                model: ready.model,
                                notice: "New chat"
                            ))
                        }
                    } catch {
                        self?.queue.async { [weak self] in
                            guard let self, !self.closing else { return }
                            self.onEvent?(BridgeEvent(type: "error", message: StateStore.friendlyError(error), busy: chatClient.busy, codexRetry: chatClient.codexRetry))
                        }
                    }
                }
                return
            }
            if type == "selectModel" {
                let model = command["model"] ?? ""
                Task { [weak self] in
                    do {
                        let ready = try await chatClient.selectModel(model)
                        self?.queue.async { [weak self] in
                            guard let self, !self.closing else { return }
                            self.onEvent?(BridgeEvent(type: "modelSelected", model: ready.model, codexRetry: ready.codexRetry))
                        }
                    } catch {
                        self?.queue.async { [weak self] in
                            guard let self, !self.closing else { return }
                            self.onEvent?(BridgeEvent(type: "error", message: StateStore.friendlyError(error), busy: chatClient.busy, codexRetry: chatClient.codexRetry))
                        }
                    }
                }
                return
            }
            if type == "reloadConfig" {
                Task { [weak self] in
                    let ready = await chatClient.reloadOpenRouter()
                    self?.queue.async { [weak self] in
                        guard let self, !self.closing else { return }
                        self.onEvent?(BridgeEvent(type: "modelsUpdated", models: ready.models, model: ready.model, codexRetry: ready.codexRetry))
                    }
                }
                return
            }
            if type == "listHistory" {
                let query = command["query"] ?? ""
                let entries = chatClient.listHistory(query: query)
                onEvent?(BridgeEvent(type: "history", history: entries, query: query))
                return
            }
            if type == "openConversation" {
                guard let id = command["conversationId"], !id.isEmpty else { return }
                let scrollToMessageId = command["scrollToMessageId"].flatMap { $0.isEmpty ? nil : $0 }
                do {
                    let ready = try chatClient.openConversation(id: id)
                    let offlineReason = ready.offlineReason
                    onEvent?(BridgeEvent(
                        type: offlineReason == nil ? "ready" : "offlineConversation",
                        conversationId: ready.conversationId,
                        messages: ready.messages,
                        models: offlineReason == nil ? ready.models : [],
                        model: ready.model,
                        notice: offlineReason.map { "Offline · \($0)" } ?? "Ready",
                        stateSaveError: ready.stateSaveError,
                        codexRetry: ready.codexRetry,
                        scrollToMessageId: scrollToMessageId
                    ))
                } catch {
                    onEvent?(BridgeEvent(
                        type: "error",
                        message: StateStore.friendlyError(error),
                        busy: chatClient.busy,
                        codexRetry: chatClient.codexRetry
                    ))
                }
                return
            }
            if type == "deleteConversation" {
                guard let id = command["conversationId"], !id.isEmpty else { return }
                let query = command["query"] ?? ""
                do {
                    let result = try chatClient.deleteConversation(id: id)
                    if result.clearedActiveConversation, let ready = result.readyState {
                        let offlineReason = ready.offlineReason
                        onEvent?(BridgeEvent(
                            type: offlineReason == nil ? "ready" : "offlineConversation",
                            conversationId: ready.conversationId,
                            messages: ready.messages,
                            models: offlineReason == nil ? ready.models : [],
                            model: ready.model,
                            notice: offlineReason.map { "Offline · \($0)" } ?? "New chat",
                            stateSaveError: ready.stateSaveError,
                            codexRetry: ready.codexRetry,
                            clearedActiveConversation: true
                        ))
                    }
                    onEvent?(BridgeEvent(
                        type: "history",
                        history: chatClient.listHistory(query: query),
                        clearedActiveConversation: result.clearedActiveConversation,
                        query: query
                    ))
                } catch {
                    onEvent?(BridgeEvent(
                        type: "error",
                        message: StateStore.friendlyError(error),
                        busy: chatClient.busy,
                        codexRetry: chatClient.codexRetry
                    ))
                }
                return
            }
            if type == "applyRetention" {
                let policy = command["retention"].flatMap(HistoryRetention.init(rawValue:)) ?? .defaultPolicy
                let query = command["query"] ?? ""
                do {
                    let result = try chatClient.applyHistoryRetention(policy)
                    if result.clearedActiveConversation, let ready = result.readyState {
                        let offlineReason = ready.offlineReason
                        onEvent?(BridgeEvent(
                            type: offlineReason == nil ? "ready" : "offlineConversation",
                            conversationId: ready.conversationId,
                            messages: ready.messages,
                            models: offlineReason == nil ? ready.models : [],
                            model: ready.model,
                            notice: offlineReason.map { "Offline · \($0)" } ?? "New chat",
                            stateSaveError: ready.stateSaveError,
                            codexRetry: ready.codexRetry,
                            clearedActiveConversation: true
                        ))
                    }
                    onEvent?(BridgeEvent(
                        type: "history",
                        history: chatClient.listHistory(query: query),
                        clearedActiveConversation: result.clearedActiveConversation,
                        query: query
                    ))
                } catch {
                    onEvent?(BridgeEvent(
                        type: "error",
                        message: StateStore.friendlyError(error),
                        busy: chatClient.busy,
                        codexRetry: chatClient.codexRetry
                    ))
                }
                return
            }
            if type == "clearHistory" {
                do {
                    let result = try chatClient.clearHistory()
                    if result.clearedActiveConversation, let ready = result.readyState {
                        let offlineReason = ready.offlineReason
                        onEvent?(BridgeEvent(
                            type: offlineReason == nil ? "ready" : "offlineConversation",
                            conversationId: ready.conversationId,
                            messages: ready.messages,
                            models: offlineReason == nil ? ready.models : [],
                            model: ready.model,
                            notice: offlineReason.map { "Offline · \($0)" } ?? "New chat",
                            stateSaveError: ready.stateSaveError,
                            codexRetry: ready.codexRetry,
                            clearedActiveConversation: true
                        ))
                    }
                    onEvent?(BridgeEvent(
                        type: "history",
                        history: [],
                        clearedActiveConversation: result.clearedActiveConversation
                    ))
                } catch {
                    onEvent?(BridgeEvent(
                        type: "error",
                        message: StateStore.friendlyError(error),
                        busy: chatClient.busy,
                        codexRetry: chatClient.codexRetry
                    ))
                }
                return
            }
            if type == "interrupt" {
                if let executionID = requestedExecutionID ?? activeExecutionID {
                    chatClient.requestStop(executionID: executionID)
                }
                return
            }
            if type == "close" {
                closeOnQueue(completion: nil)
            }
        }
    }

    func close(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in closeOnQueue(completion: completion) }
    }

    private func closeOnQueue(completion: (@Sendable () -> Void)?) {
        if closing {
            guard let completion else { return }
            if closeCallbacks != nil { closeCallbacks?.append(completion) }
            else { completion() }
            return
        }
        closing = true
        onEvent = nil
        pendingDelta = nil
        flushDelta()
        let activeClient = client
        client = nil
        guard let activeClient else {
            completion?()
            return
        }
        closeCallbacks = completion.map { [$0] } ?? []
        let teardown = activeClient.beginClose()
        Task { [self] in
            await teardown.value
            queue.async { [self] in
                let callbacks = closeCallbacks ?? []
                closeCallbacks = nil
                for callback in callbacks { callback() }
            }
        }
    }
}
