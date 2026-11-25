@testable import ChatCore
import Foundation
import Testing
@testable import SpeedChat

@MainActor
func waitForHistoryCondition(timeout: Duration = .seconds(2), _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !predicate(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(predicate())
}

final class RecordingHistoryBackend: ChatBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (BridgeEvent) -> Void)?
    private var recorded = [[String: String]]()
    private var capturedOptions: ChatClientOptions?

    var commands: [[String: String]] { lock.withLock { recorded } }
    var startedOptions: ChatClientOptions? { lock.withLock { capturedOptions } }

    func start(codexOverride: String, options: ChatClientOptions, onEvent: @escaping @Sendable (BridgeEvent) -> Void) {
        lock.withLock {
            capturedOptions = options
            sink = onEvent
        }
    }

    func send(_ command: [String: String]) {
        lock.withLock { recorded.append(command) }
    }

    func close(completion: (@Sendable () -> Void)?) {
        lock.withLock { sink = nil }
        completion?()
    }

    func emit(_ event: BridgeEvent) {
        let sink = lock.withLock { self.sink }
        sink?(event)
    }
}
