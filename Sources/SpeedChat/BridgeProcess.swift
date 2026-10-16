import Foundation
import ChatCore

/// In-process native chat backend that drives `ChatClient` and coalesces streaming token deltas at ~60fps (16ms).
final class BridgeProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SpeedChat.bridge", qos: .userInitiated)
    private var client: ChatClient?
    private var closing = false
    private var onEvent: (@Sendable (BridgeEvent) -> Void)?
    private var turnStartedAt: Date?
    private var firstTokenSeen = false
    private var pendingDelta = ""
    private var pendingItemId = ""
    private var deltaTimer: DispatchWorkItem?

    func start(
        codexOverride: String = "",
        options: ChatClientOptions = ChatClientOptions(),
        onEvent: @escaping @Sendable (BridgeEvent) -> Void
    ) {
        queue.async { [self] in
            self.onEvent = onEvent
            self.closing = false
            let rpc = JsonRpcProcess(codexOverride: codexOverride, env: options.env)
            let chatClient = ChatClient(rpc: rpc, options: options)
            self.client = chatClient

            chatClient.onDelta = { [weak self] delta, itemId in
                self?.queue.async { [weak self] in
                    guard let self, !self.closing else { return }
                    if !self.pendingItemId.isEmpty && self.pendingItemId != itemId {
                        self.flushDelta()
                    }
                    self.pendingItemId = itemId
                    self.pendingDelta += delta
                    if self.deltaTimer == nil {
                        let work = DispatchWorkItem { [weak self] in
                            self?.flushDelta()
                        }
                        self.deltaTimer = work
                        self.queue.asyncAfter(deadline: .now() + .milliseconds(16), execute: work)
                    }
                }
            }
            chatClient.onMessage = { [weak self] itemId, text in
                self?.queue.async { [weak self] in
                    guard let self, !self.closing else { return }
                    self.flushDelta()
                    self.onEvent?(BridgeEvent(type: "message", itemId: itemId, text: text))
                }
            }
            chatClient.onDone = { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self, !self.closing else { return }
                    self.flushDelta()
                    self.emitMetric("response")
                    self.onEvent?(BridgeEvent(type: "done"))
                }
            }
            chatClient.onSearching = { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self, !self.closing else { return }
                    self.onEvent?(BridgeEvent(type: "searching"))
                }
            }
            chatClient.onModel = { [weak self] activeModel in
                self?.queue.async { [weak self] in
                    guard let self, !self.closing else { return }
                    self.onEvent?(BridgeEvent(type: "activeModel", model: activeModel))
                }
            }
            chatClient.onError = { [weak self] error in
                self?.queue.async { [weak self] in
                    guard let self, !self.closing else { return }
                    self.flushDelta()
                    self.onEvent?(BridgeEvent(
                        type: "error",
                        message: StateStore.friendlyError(error),
                        busy: chatClient.busy
                    ))
                }
            }
            chatClient.onFatal = { [weak self] error in
                self?.queue.async { [weak self] in
                    guard let self, !self.closing else { return }
                    self.flushDelta()
                    self.onEvent?(BridgeEvent(type: "fatal", message: StateStore.friendlyError(error)))
                }
            }

            Task { [weak self] in
                do {
                    let ready = try await chatClient.connect()
                    self?.queue.async { [weak self] in
                        guard let self, !self.closing else { return }
                        let notice = (ready.resumed && !ready.messages.isEmpty) ? "Resumed previous chat" : "Ready"
                        self.onEvent?(BridgeEvent(
                            type: "ready",
                            messages: ready.messages,
                            models: ready.models,
                            model: ready.model,
                            notice: notice
                        ))
                    }
                } catch {
                    self?.queue.async { [weak self] in
                        guard let self, !self.closing else { return }
                        self.onEvent?(BridgeEvent(type: "fatal", message: StateStore.friendlyError(error)))
                    }
                }
            }
        }
    }

    private func emitMetric(_ name: String) {
        guard let started = turnStartedAt else { return }
        let ms = max(0, round(Date().timeIntervalSince(started) * 1000))
        onEvent?(BridgeEvent(type: "metric", name: name, durationMs: ms))
    }

    private func flushDelta() {
        deltaTimer?.cancel()
        deltaTimer = nil
        guard !pendingDelta.isEmpty else { return }
        if !firstTokenSeen {
            firstTokenSeen = true
            emitMetric("first-token")
        }
        onEvent?(BridgeEvent(type: "delta", itemId: pendingItemId, delta: pendingDelta))
        pendingDelta = ""
        pendingItemId = ""
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
            if type == "send" {
                let text = (command["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                turnStartedAt = Date()
                firstTokenSeen = false
                Task { [weak self] in
                    do {
                        try await chatClient.send(text)
                    } catch {
                        self?.queue.async { [weak self] in
                            guard let self, !self.closing else { return }
                            self.onEvent?(BridgeEvent(type: "error", message: StateStore.friendlyError(error), busy: chatClient.busy))
                        }
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
                            self.onEvent?(BridgeEvent(type: "error", message: StateStore.friendlyError(error), busy: chatClient.busy))
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
                            self.onEvent?(BridgeEvent(type: "modelSelected", model: ready.model))
                        }
                    } catch {
                        self?.queue.async { [weak self] in
                            guard let self, !self.closing else { return }
                            self.onEvent?(BridgeEvent(type: "error", message: StateStore.friendlyError(error), busy: chatClient.busy))
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
                        self.onEvent?(BridgeEvent(type: "modelsUpdated", models: ready.models, model: ready.model))
                    }
                }
                return
            }
            if type == "interrupt" {
                Task {
                    await chatClient.interrupt()
                }
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
