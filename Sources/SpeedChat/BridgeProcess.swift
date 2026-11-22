import Foundation
import ChatCore

/// In-process native chat backend that drives `ChatClient` and coalesces streaming token deltas at ~60fps (16ms).
final class BridgeProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SpeedChat.bridge", qos: .userInitiated)
    private var client: ChatClient?
    private var closing = false
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

    func start(
        codexOverride: String = "",
        options: ChatClientOptions = ChatClientOptions(),
        onEvent: @escaping @Sendable (BridgeEvent) -> Void
    ) {
        queue.async { [self] in
            self.onEvent = onEvent
            self.closing = false
            self.startup = .connecting(exitReason: nil)
            let rpc = JsonRpcProcess(codexOverride: codexOverride, env: options.env)
            let chatClient = ChatClient(rpc: rpc, options: options)
            self.client = chatClient

            chatClient.onTurnEvent = { [weak self] event in
                self?.enqueueReplyEvent(event)
            }
            chatClient.onDelta = { [weak self] delta, itemId in
                self?.enqueueReplyEvent(BridgeEvent(type: "delta", itemId: itemId, delta: delta))
            }
            chatClient.onMessage = { [weak self] itemId, text in
                self?.enqueueReplyEvent(BridgeEvent(type: "message", itemId: itemId, text: text))
            }
            chatClient.onHistoryRecovered = { [weak self] messages in
                self?.queue.async { [weak self] in
                    guard let self, !self.closing else { return }
                    self.flushDelta()
                    self.onEvent?(BridgeEvent(type: "historyRecovered", messages: messages))
                }
            }
            chatClient.onCodexReplyResumed = { [weak self] promptId, messages in
                self?.queue.async { [weak self] in
                    guard let self, !self.closing else { return }
                    self.onEvent?(BridgeEvent(type: "codexReplyResumed", messages: messages, itemId: promptId))
                }
            }
            chatClient.onDone = { [weak self, weak chatClient] in
                self?.enqueueReplyEvent(BridgeEvent(type: "done", codexRetry: chatClient?.codexRetry))
            }
            chatClient.onSearching = { [weak self] in
                self?.enqueueReplyEvent(BridgeEvent(type: "searching"))
            }
            chatClient.onModel = { [weak self] activeModel in
                self?.enqueueReplyEvent(BridgeEvent(type: "activeModel", model: activeModel))
            }
            chatClient.onError = { [weak self, weak chatClient] error in
                self?.enqueueReplyEvent(BridgeEvent(
                    type: "error",
                    message: StateStore.friendlyError(error),
                    busy: chatClient?.busy,
                    codexRetry: chatClient?.codexRetry
                ))
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

        if event.type == "message" || event.type == "error" || event.type == "done" {
            flushDelta()
        }
        if event.type == "done" {
            emitMetric("response", executionID: event.executionID)
        }
        if event.type == "done" || (event.type == "error" && event.busy != true) {
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
            if type == "send" {
                let text = (command["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                let executionID = requestedExecutionID ?? UUID()
                let userMessageId = command["itemId"] ?? UUID().uuidString.lowercased()
                do {
                    try chatClient.acceptSend(text, userMessageId: userMessageId, executionID: executionID)
                } catch {
                    onEvent?(BridgeEvent(type: "error", message: StateStore.friendlyError(error),
                                         busy: chatClient.busy, codexRetry: chatClient.codexRetry,
                                         executionID: requestedExecutionID))
                    return
                }
                activeExecutionID = executionID
                turnStartedAt = Date()
                firstTokenSeen = false
                Task { [weak self] in
                    do {
                        try await chatClient.startSend(executionID: executionID)
                    } catch {
                        self?.enqueueReplyEvent(BridgeEvent(
                            type: "error", message: StateStore.friendlyError(error), busy: chatClient.busy,
                            codexRetry: chatClient.codexRetry, executionID: requestedExecutionID
                        ))
                    }
                }
                return
            }
            if type == "retryCodex" || type == "resendCodex" {
                turnStartedAt = Date()
                firstTokenSeen = false
                Task { [weak self] in
                    do {
                        if let id = command["itemId"],
                           let checked = try await chatClient.retryCodexSend(userMessageId: id, resend: type == "resendCodex") {
                            self?.queue.async { [weak self] in
                                guard let self, !self.closing else { return }
                                self.onEvent?(BridgeEvent(
                                    type: "conversationUpdated",
                                    messages: checked.messages,
                                    notice: checked.codexRetry == nil ? "Codex received this message." : nil,
                                    stateSaveError: checked.stateSaveError,
                                    codexRetry: checked.codexRetry
                                ))
                            }
                        }
                    } catch {
                        self?.enqueueReplyEvent(BridgeEvent(
                            type: "error", message: StateStore.friendlyError(error),
                            busy: chatClient.busy, codexRetry: chatClient.codexRetry
                        ))
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
            if type == "interrupt" {
                chatClient.requestStop(executionID: requestedExecutionID ?? activeExecutionID)
                return
            }
            if type == "close" {
                close()
            }
        }
    }

    func close(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            guard !closing else {
                completion?()
                return
            }
            closing = true
            flushDelta()
            let activeClient = client
            client = nil
            guard let activeClient else {
                completion?()
                return
            }
            Task {
                await activeClient.close()
                completion?()
            }
        }
    }
}
