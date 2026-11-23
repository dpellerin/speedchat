import ChatCore
import Foundation
import Testing
@testable import SpeedChat

@MainActor
@Test(arguments: [false, true])
func reconnectAndQuitWaitForTheOutgoingBackend(quit: Bool) async throws {
    let outgoing = HeldChatBackend()
    let replacement = HeldChatBackend()
    var created = 0
    var quitReplies = 0
    let store = ChatStore {
        created += 1
        return created == 1 ? outgoing : replacement
    }
    store.connect()
    #expect(created == 1)
    store.codexOverride = "superseded"
    store.connect()
    store.codexOverride = "latest"
    store.connect()
    if quit {
        store.quit { quitReplies += 1 }
        store.connect()
    }

    #expect(created == 1)
    #expect(quitReplies == 0)
    outgoing.finishClosing()

    let deadline = ContinuousClock.now + .seconds(2)
    while (quit ? quitReplies == 0 : created == 1), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    if quit {
        #expect(quitReplies == 1)
        #expect(created == 1)
        #expect(store.bridge == nil)
    } else {
        #expect(created == 2)
        #expect(replacement.codexOverride == "latest")
        store.stop()
        replacement.finishClosing()
    }
}

private final class HeldChatBackend: ChatBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable () -> Void)?
    private var override: String?

    var codexOverride: String? { lock.withLock { override } }

    func start(codexOverride: String, options: ChatClientOptions, onEvent: @escaping @Sendable (BridgeEvent) -> Void) {
        lock.withLock { override = codexOverride }
    }

    func send(_ command: [String: String]) {}

    func close(completion: (@Sendable () -> Void)?) {
        lock.withLock { self.completion = completion }
    }

    func finishClosing() {
        let reply = lock.withLock {
            let reply = completion
            completion = nil
            return reply
        }
        reply?()
    }
}
