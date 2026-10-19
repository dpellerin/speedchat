import Foundation
import Darwin

public struct CodexPayload: @unchecked Sendable {
    public var value: [String: Any]
    public init(_ value: [String: Any] = [:]) {
        self.value = value
    }
}

public struct CodexNotification: @unchecked Sendable {
    public var method: String
    public var params: [String: Any]

    public init(method: String, params: [String: Any] = [:]) {
        self.method = method
        self.params = params
    }
}

public protocol CodexTransport: AnyObject, Sendable {
    var onNotification: (@Sendable (CodexNotification) -> Void)? { get set }
    var onExit: (@Sendable () -> Void)? { get set }
    func start(cwd: URL?) async throws
    func request(method: String, params: [String: Any], timeoutMs: Int) async throws -> [String: Any]
    func stop() async
}

public enum CodexProtocol {
    public static let disabledFeatures: [String] = [
        "shell_tool",
        "unified_exec",
        "apps",
        "browser_use",
        "browser_use_external",
        "computer_use",
        "image_generation",
        "view_image",
        "plugins",
        "memories",
        "multi_agent",
        "goals",
        "skill_mcp_dependency_install",
        "skill_search",
        "hooks",
        "code_mode",
        "sleep_tool",
        "remote_plugin",
        "workspace_dependencies",
        "in_app_local_automation",
        "realtime_conversation",
        "multi_agent_v2",
        "browser_annotation_api",
        "in_app_browser",
        "tool_suggest",
        "auth_elicitation",
    ]

    public static func arguments() -> [String] {
        var args = ["app-server", "--stdio"]
        // CLI --disable rejects flags absent from older Codex versions. Config
        // overrides keep known features disabled and tolerate unavailable ones.
        for feature in disabledFeatures {
            args.append(contentsOf: ["-c", "features.\(feature)=false"])
        }
        args.append(contentsOf: [
            "--enable", "skip_host_skill_discovery",
            "-c", "forced_login_method=\"chatgpt\"",
            "-c", "model_provider=\"openai\"",
            "-c", "analytics.enabled=false",
            "--enable", "standalone_web_search",
            "-c", "mcp_servers={}",
            "-c", "web_search=\"live\"",
        ])
        return args
    }
}

public final class JsonRpcProcess: CodexTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SpeedChat.codex-rpc", qos: .userInitiated)
    private var child: Process?
    private var input: FileHandle?
    private var framer = JSONLFramer()
    private var nextId = 1
    private var stderr = ""
    private var codexOverride: String
    private var envOverride: [String: String]?

    private struct PendingRequest {
        var resolve: (CodexPayload) -> Void
        var reject: (Error) -> Void
        var timer: DispatchWorkItem
    }

    private var pending = [Int: PendingRequest]()
    public var onNotification: (@Sendable (CodexNotification) -> Void)?
    public var onExit: (@Sendable () -> Void)?

    public init(codexOverride: String = "", env: [String: String]? = nil) {
        self.codexOverride = codexOverride
        self.envOverride = env
    }

    public func start(cwd: URL? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if self.child != nil {
                    continuation.resume()
                    return
                }
                do {
                    let sourceEnv = self.envOverride ?? ProcessInfo.processInfo.environment
                    let home = sourceEnv["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
                    let override = !self.codexOverride.isEmpty ? self.codexOverride : (sourceEnv["SPEEDCHAT_CODEX"] ?? "")
                    let codexPath = try RuntimeDiscovery.find(
                        name: "codex",
                        override: override,
                        home: home,
                        path: sourceEnv["PATH"] ?? ""
                    )
                    var env = RuntimeDiscovery.environment(sourceEnv, home: home)
                    let hermesEntries = (try? FileManager.default.contentsOfDirectory(atPath: home + "/.hermes/tools")) ?? []
                    if let nodeBin = try? RuntimeDiscovery.find(name: "node", override: "", home: home, path: env["PATH"] ?? "", hermesEntries: hermesEntries) {
                        let nodeDir = URL(fileURLWithPath: nodeBin).deletingLastPathComponent().path
                        let currentPath = env["PATH"] ?? ""
                        if !currentPath.split(separator: ":").contains(Substring(nodeDir)) {
                            env["PATH"] = nodeDir + ":" + currentPath
                        }
                    }

                    let proc = Process()
                    let stdinPipe = Pipe()
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()

                    proc.executableURL = URL(fileURLWithPath: codexPath)
                    proc.arguments = CodexProtocol.arguments()
                    if let cwd { proc.currentDirectoryURL = cwd }
                    proc.environment = env
                    proc.standardInput = stdinPipe
                    proc.standardOutput = stdoutPipe
                    proc.standardError = stderrPipe

                    _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                    self.input = stdinPipe.fileHandleForWriting
                    self.child = proc
                    self.framer = JSONLFramer()
                    self.stderr = ""

                    stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                        let data = handle.availableData
                        self?.queue.async { [weak self] in
                            self?.handleStdout(data, handle: handle)
                        }
                    }
                    stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                        let data = handle.availableData
                        if data.isEmpty {
                            handle.readabilityHandler = nil
                            return
                        }
                        if let text = String(data: data, encoding: .utf8) {
                            self?.queue.async { [weak self] in
                                guard let self else { return }
                                self.stderr = String((self.stderr + text).suffix(4000))
                            }
                        }
                    }
                    proc.terminationHandler = { [weak self] terminated in
                        self?.queue.async { [weak self] in
                            guard let self else { return }
                            stdoutPipe.fileHandleForReading.readabilityHandler = nil
                            stderrPipe.fileHandleForReading.readabilityHandler = nil
                            let detail = self.stderr
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .components(separatedBy: "\n")
                                .last?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            let msg = detail.isEmpty
                                ? "Codex app-server exited (\(terminated.terminationStatus))."
                                : detail
                            let wasRunning = self.child != nil
                            self.child = nil
                            self.input = nil
                            self.failAll(NSError(domain: "SpeedChat.Codex", code: Int(terminated.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg]))
                            if wasRunning {
                                self.onExit?()
                            }
                        }
                    }

                    try proc.run()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        _ = try await request(
            method: "initialize",
            params: [
                "clientInfo": ["name": "speedchat", "title": "SpeedChat", "version": "1.0.0"],
                "capabilities": ["experimentalApi": true],
            ],
            timeoutMs: 30_000
        )
        notify(method: "initialized", params: [:])
    }

    public func request(method: String, params: [String: Any], timeoutMs: Int = 30_000) async throws -> [String: Any] {
        let boxed = CodexPayload(params)
        let response: CodexPayload = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CodexPayload, Error>) in
            queue.async { [self] in
                guard self.child != nil, self.input != nil else {
                    continuation.resume(throwing: NSError(domain: "SpeedChat.Codex", code: -1, userInfo: [NSLocalizedDescriptionKey: "Codex app-server is not running."]))
                    return
                }
                let id = self.nextId
                self.nextId += 1
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, let pending = self.pending.removeValue(forKey: id) else { return }
                    pending.reject(NSError(domain: "SpeedChat.Codex", code: -2, userInfo: [NSLocalizedDescriptionKey: "\(method) timed out."]))
                }
                self.pending[id] = PendingRequest(
                    resolve: { continuation.resume(returning: $0) },
                    reject: { continuation.resume(throwing: $0) },
                    timer: timer
                )
                self.queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: timer)
                self.write(["id": id, "method": method, "params": boxed.value])
            }
        }
        return response.value
    }

    public func notify(method: String, params: [String: Any]) {
        let boxed = CodexPayload(params)
        queue.async { [self] in
            self.write(["method": method, "params": boxed.value])
        }
    }

    public func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                let activeChild = self.child
                self.child = nil
                try? self.input?.close()
                self.input = nil
                self.failAll(NSError(domain: "SpeedChat.Codex", code: -3, userInfo: [NSLocalizedDescriptionKey: "Codex app-server stopped."]))
                guard let activeChild, activeChild.isRunning else {
                    continuation.resume()
                    return
                }
                let pid = activeChild.processIdentifier
                activeChild.terminate()
                self.queue.asyncAfter(deadline: .now() + .milliseconds(1500)) {
                    if activeChild.isRunning {
                        kill(pid, SIGKILL)
                    }
                }
                DispatchQueue.global(qos: .utility).async {
                    activeChild.waitUntilExit()
                    continuation.resume()
                }
            }
        }
    }

    private func write(_ object: [String: Any]) {
        guard let input,
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        try? input.write(contentsOf: data)
    }

    private func handleStdout(_ data: Data, handle: FileHandle) {
        if data.isEmpty {
            handle.readabilityHandler = nil
            return
        }
        guard let lines = try? framer.push(data) else { return }
        for line in lines {
            receiveLine(line)
        }
    }

    private func receiveLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let method = message["method"] as? String, let reqId = message["id"] {
            write([
                "id": reqId,
                "error": [
                    "code": -32601,
                    "message": "SpeedChat does not permit client tools or local actions.",
                ],
            ])
            onNotification?(CodexNotification(method: "speedchat/blockedRequest", params: ["method": method]))
            return
        }
        if let id = message["id"] as? Int, let entry = pending.removeValue(forKey: id) {
            entry.timer.cancel()
            if let errorDict = message["error"] as? [String: Any] {
                let errMsg = (errorDict["message"] as? String) ?? "RPC error"
                let code = (errorDict["code"] as? Int) ?? -1
                entry.reject(NSError(domain: "SpeedChat.Codex", code: code, userInfo: [NSLocalizedDescriptionKey: "\(errMsg) (\(code))"]))
            } else {
                let result = (message["result"] as? [String: Any]) ?? [:]
                entry.resolve(CodexPayload(result))
            }
            return
        }
        if let method = message["method"] as? String {
            let params = (message["params"] as? [String: Any]) ?? [:]
            onNotification?(CodexNotification(method: method, params: params))
        }
    }

    private func failAll(_ error: Error) {
        let entries = pending.values
        pending.removeAll()
        for entry in entries {
            entry.timer.cancel()
            entry.reject(error)
        }
    }
}
