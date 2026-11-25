import AppKit
import ChatCore
import Foundation
import Testing
@testable import SpeedChat

@MainActor
@Test func globalShortcutOpensHiddenPanelOnActiveSpaceWithComposerFocused() {
    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    var showCount = 0
    var hideCount = 0
    let coordinator = WindowCoordinator(
        workspace: workspace,
        onShow: { showCount += 1 },
        onHide: { hideCount += 1 }
    )

    coordinator.togglePanelFromHotKey()

    #expect(workspace.isPanelVisible)
    #expect(workspace.panelSpace == .desktopA)
    #expect(workspace.isPanelOnActiveSpace)
    #expect(workspace.isPanelFrontmost)
    #expect(workspace.isPanelKey)
    #expect(workspace.isAppActive)
    #expect(workspace.isComposerFocused)
    #expect(showCount == 1)
    #expect(hideCount == 0)
}

@MainActor
@Test func globalShortcutHidesPanelWhenAlreadyFrontmostAndFocusedOnCurrentSpace() {
    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    var showCount = 0
    var hideCount = 0
    let coordinator = WindowCoordinator(
        workspace: workspace,
        onShow: { showCount += 1 },
        onHide: { hideCount += 1 }
    )

    coordinator.showPanel()
    coordinator.togglePanelFromHotKey()

    #expect(!workspace.isPanelVisible)
    #expect(workspace.panelSpace == nil)
    #expect(!workspace.isPanelKey)
    #expect(!workspace.isComposerFocused)
    #expect(hideCount == 1)
    #expect(showCount == 1)

    coordinator.togglePanelFromHotKey()
    #expect(workspace.isPanelVisible)
    #expect(workspace.panelSpace == .desktopA)
    #expect(workspace.isPanelFrontmost)
    #expect(workspace.isComposerFocused)
    #expect(showCount == 2)
    #expect(hideCount == 1)
}

@MainActor
@Test(arguments: ["anotherApp", "anotherAppWithStalePanelKey", "secondaryWindow"])
func globalShortcutRaisesAndFocusesUnfocusedPanelOnCurrentSpace(scenario: String) {
    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    var showCount = 0
    var hideCount = 0
    let coordinator = WindowCoordinator(
        workspace: workspace,
        onShow: { showCount += 1 },
        onHide: { hideCount += 1 }
    )

    coordinator.showPanel()
    switch scenario {
    case "anotherApp":
        workspace.otherAppTakesFocus()
    case "anotherAppWithStalePanelKey":
        workspace.otherAppTakesFocus(retainStalePanelKey: true)
    default:
        workspace.secondaryWindowTakesFocus()
    }

    coordinator.togglePanelFromHotKey()

    #expect(workspace.isPanelVisible)
    #expect(workspace.panelSpace == .desktopA)
    #expect(workspace.isPanelFrontmost)
    #expect(workspace.isPanelKey)
    #expect(workspace.isAppActive)
    #expect(workspace.isComposerFocused)
    #expect(showCount == 2)
    #expect(hideCount == 0)
}

@MainActor
@Test(arguments: [FakeSpace.desktopB, .fullscreenApp])
func globalShortcutPullsOpenPanelFromAnotherSpaceWithoutHidingOrBouncingSpaces(destination: FakeSpace) {
    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    var showCount = 0
    var hideCount = 0
    let coordinator = WindowCoordinator(
        workspace: workspace,
        onShow: { showCount += 1 },
        onHide: { hideCount += 1 }
    )

    coordinator.showPanel()
    workspace.switchSpace(to: destination)

    #expect(workspace.isPanelVisible)
    #expect(workspace.panelSpace == .desktopA)
    #expect(!workspace.isPanelOnActiveSpace)

    coordinator.togglePanelFromHotKey()

    #expect(workspace.activeSpace == destination)
    #expect(workspace.isPanelVisible)
    #expect(workspace.panelSpace == destination)
    #expect(workspace.isPanelOnActiveSpace)
    #expect(workspace.isPanelFrontmost)
    #expect(workspace.isPanelKey)
    #expect(workspace.isAppActive)
    #expect(workspace.isComposerFocused)
    #expect(showCount == 2)
    #expect(hideCount == 0)
}

@MainActor
@Test func menuBarShowAndNewChatAlwaysShowOrPullWithoutTogglingClosed() {
    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    var showCount = 0
    var hideCount = 0
    var newChatCount = 0
    var panelVisibleDuringNewChat = false
    var panelSpaceDuringNewChat: FakeSpace?
    let coordinator = WindowCoordinator(
        workspace: workspace,
        onShow: { showCount += 1 },
        onHide: { hideCount += 1 },
        onNewChat: {
            newChatCount += 1
            panelVisibleDuringNewChat = workspace.isPanelVisible
            panelSpaceDuringNewChat = workspace.panelSpace
        }
    )

    // Hidden -> Show SpeedChat opens and focuses.
    coordinator.showPanel()
    #expect(workspace.isPanelVisible)
    #expect(workspace.panelSpace == .desktopA)
    #expect(workspace.isComposerFocused)

    // Already frontmost and focused -> Show SpeedChat never toggles closed.
    coordinator.showPanel()
    #expect(workspace.isPanelVisible)
    #expect(workspace.panelSpace == .desktopA)
    #expect(workspace.isPanelKey)
    #expect(workspace.isAppActive)
    #expect(workspace.isComposerFocused)
    #expect(hideCount == 0)

    // Open on Space A while user is on Space B -> Show SpeedChat pulls onto Space B.
    workspace.switchSpace(to: .desktopB)
    coordinator.showPanel()
    #expect(workspace.activeSpace == .desktopB)
    #expect(workspace.panelSpace == .desktopB)
    #expect(workspace.isPanelFrontmost)
    #expect(workspace.isComposerFocused)
    #expect(hideCount == 0)

    // Open on Space B while user is on Space A -> New Chat pulls onto Space A, focuses, and starts New Chat.
    workspace.switchSpace(to: .desktopA)
    coordinator.newChatFromMenu()
    #expect(workspace.activeSpace == .desktopA)
    #expect(workspace.panelSpace == .desktopA)
    #expect(workspace.isPanelVisible)
    #expect(workspace.isPanelFrontmost)
    #expect(workspace.isComposerFocused)
    #expect(newChatCount == 1)
    #expect(panelVisibleDuringNewChat)
    #expect(panelSpaceDuringNewChat == .desktopA)
    #expect(hideCount == 0)

    // Already frontmost and focused -> New Chat keeps Panel visible and starts New Chat.
    coordinator.newChatFromMenu()
    #expect(workspace.isPanelVisible)
    #expect(workspace.isPanelKey)
    #expect(workspace.isComposerFocused)
    #expect(newChatCount == 2)
    #expect(showCount == 5)
    #expect(hideCount == 0)
}

@MainActor
@Test func panelCollectionBehaviorUsesSingleSpaceMissionControlAndFullscreenAuxiliary() {
    let behavior = WindowCoordinator.panelCollectionBehavior
    #expect(behavior.contains(.moveToActiveSpace))
    #expect(behavior.contains(.managed))
    #expect(behavior.contains(.fullScreenAuxiliary))
    #expect(!behavior.contains(.canJoinAllSpaces))
}

@MainActor
@Test func hidingAndPullingPanelPreserveDraftAndActiveTurnInStore() {
    let store = ChatStore()
    store.fixtureMode = true
    store.session.receive(BridgeEvent(type: "ready", model: "gpt-6-luna"))
    store.draft = "First prompt"
    store.send()
    store.draft = "Unsent follow-up draft"
    #expect(store.session.streaming)

    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    let coordinator = WindowCoordinator(
        workspace: workspace,
        onShow: { store.show() },
        onHide: { store.hide() },
        onNewChat: { store.newChat() }
    )

    coordinator.showPanel()
    #expect(store.hiddenAt == nil)

    // Pull across Spaces while an Active turn is streaming: never hides the store or drops the Draft.
    workspace.switchSpace(to: .desktopB)
    coordinator.togglePanelFromHotKey()
    #expect(workspace.panelSpace == .desktopB)
    #expect(store.hiddenAt == nil)
    #expect(store.draft == "Unsent follow-up draft")
    #expect(store.session.streaming)

    // Smart-toggle hide on Space B: hides the Panel while preserving Draft and Active turn.
    coordinator.togglePanelFromHotKey()
    #expect(!workspace.isPanelVisible)
    #expect(store.hiddenAt != nil)
    #expect(store.draft == "Unsent follow-up draft")
    #expect(store.session.streaming)
    #expect(!store.fixtureCommands.contains { $0["type"] == "interrupt" })

    // Reopen and dismiss via explicit hidePanel (Esc / ⌘W / close button): also preserves Draft and Active turn.
    coordinator.togglePanelFromHotKey()
    #expect(workspace.isPanelVisible)
    #expect(store.hiddenAt == nil)
    coordinator.hidePanel()
    #expect(!workspace.isPanelVisible)
    #expect(store.hiddenAt != nil)
    #expect(store.draft == "Unsent follow-up draft")
    #expect(store.session.streaming)
    #expect(!store.fixtureCommands.contains { $0["type"] == "interrupt" })
    store.stop()
}

@MainActor
@Test(arguments: [
    SpaceLeaveOrdering.spaceChangeFirst,
    .resignAfterSpaceFlip,
    .resignBeforeSpaceFlip
])
func returningToPanelSpaceRestoresPanelFrontmostWithComposerFocused(ordering: SpaceLeaveOrdering) {
    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    var showCount = 0
    var hideCount = 0
    let coordinator = WindowCoordinator(
        workspace: workspace,
        onShow: { showCount += 1 },
        onHide: { hideCount += 1 }
    )

    coordinator.showPanel()
    #expect(showCount == 1)

    workspace.switchSpace(to: .desktopB, ordering: ordering)
    #expect(workspace.isPanelVisible)
    #expect(workspace.panelSpace == .desktopA)
    #expect(!workspace.isPanelOnActiveSpace)
    #expect(!workspace.isPanelKey)
    #expect(!workspace.isAppActive)
    #expect(!workspace.isComposerFocused)

    workspace.advanceTime(by: 5.0)
    workspace.switchSpace(to: .desktopA)

    #expect(workspace.activeSpace == .desktopA)
    #expect(workspace.isPanelVisible)
    #expect(workspace.panelSpace == .desktopA)
    #expect(workspace.isPanelOnActiveSpace)
    #expect(workspace.isPanelFrontmost)
    #expect(workspace.isPanelKey)
    #expect(workspace.isAppActive)
    #expect(workspace.isComposerFocused)
    #expect(showCount == 1)
    #expect(hideCount == 0)
}

@MainActor
@Test(arguments: ["anotherApp", "anotherAppWithStalePanelKey", "secondaryWindow"])
func returningToPanelSpaceLeavesOtherActiveAppOrWindowFrontmost(scenario: String) {
    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    let coordinator = WindowCoordinator(workspace: workspace)

    coordinator.showPanel()
    switch scenario {
    case "anotherApp":
        workspace.otherAppTakesFocus()
        workspace.advanceTime(by: WindowCoordinator.spaceSwitchResignGraceInterval + 0.5)
    case "anotherAppWithStalePanelKey":
        workspace.otherAppTakesFocus(retainStalePanelKey: true)
        workspace.advanceTime(by: WindowCoordinator.spaceSwitchResignGraceInterval + 0.5)
    default:
        // Focusing another SpeedChat window on Space A clears Panel ownership immediately,
        // even if the user switches Spaces right away.
        workspace.secondaryWindowTakesFocus()
    }

    workspace.switchSpace(to: .desktopB)
    workspace.advanceTime(by: 3.0)
    workspace.switchSpace(to: .desktopA)

    #expect(workspace.activeSpace == .desktopA)
    #expect(workspace.isPanelVisible)
    #expect(workspace.panelSpace == .desktopA)
    #expect(workspace.isPanelOnActiveSpace)
    #expect(!workspace.isPanelFrontmost)
    #expect(!workspace.isPanelKey)
    #expect(!workspace.isAppActive)
    #expect(!workspace.isComposerFocused)

    // Clicking back into the Panel on Space A re-arms restoration on the next departure.
    workspace.userClicksPanel()
    workspace.switchSpace(to: .desktopB)
    workspace.advanceTime(by: 2.0)
    workspace.switchSpace(to: .desktopA)

    #expect(workspace.isPanelFrontmost)
    #expect(workspace.isPanelKey)
    #expect(workspace.isAppActive)
    #expect(workspace.isComposerFocused)
}

@MainActor
@Test func visitingIntermediateSpacesPreservesPendingSpaceReturnRestoration() {
    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    let coordinator = WindowCoordinator(workspace: workspace)

    coordinator.showPanel()

    workspace.switchSpace(to: .desktopB)
    workspace.advanceTime(by: 2.0)
    // Visiting additional desktop/fullscreen Spaces and even focusing a secondary SpeedChat
    // window elsewhere must not clear Space A's pending restoration.
    workspace.switchSpace(to: .desktopC)
    workspace.advanceTime(by: 2.0)
    workspace.secondaryWindowTakesFocus()
    workspace.switchSpace(to: .fullscreenApp)
    workspace.advanceTime(by: 2.0)

    #expect(workspace.isPanelVisible)
    #expect(workspace.panelSpace == .desktopA)
    #expect(!workspace.isPanelOnActiveSpace)
    #expect(!workspace.isPanelKey)

    workspace.switchSpace(to: .desktopA)

    #expect(workspace.activeSpace == .desktopA)
    #expect(workspace.isPanelVisible)
    #expect(workspace.panelSpace == .desktopA)
    #expect(workspace.isPanelFrontmost)
    #expect(workspace.isPanelKey)
    #expect(workspace.isAppActive)
    #expect(workspace.isComposerFocused)

    // Leaving and returning a second time after restoration continues to restore.
    workspace.switchSpace(to: .desktopB)
    workspace.switchSpace(to: .desktopC)
    workspace.switchSpace(to: .desktopA)

    #expect(workspace.isPanelFrontmost)
    #expect(workspace.isPanelKey)
    #expect(workspace.isAppActive)
    #expect(workspace.isComposerFocused)
}

@MainActor
@Test(arguments: ["hotkey", "menuShow", "menuNewChat"])
func pullingPanelOntoAnotherSpaceClearsPriorSpaceRestoration(trigger: String) {
    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    let coordinator = WindowCoordinator(workspace: workspace)

    coordinator.showPanel()
    workspace.switchSpace(to: .desktopB)

    switch trigger {
    case "hotkey":
        coordinator.togglePanelFromHotKey()
    case "menuShow":
        coordinator.showPanel()
    default:
        coordinator.newChatFromMenu()
    }

    #expect(workspace.activeSpace == .desktopB)
    #expect(workspace.panelSpace == .desktopB)
    #expect(workspace.isPanelFrontmost)

    // Leave Space B (leaving Panel behind on Space B) and return to Space A.
    workspace.advanceTime(by: 2.0)
    workspace.switchSpace(to: .desktopA)

    #expect(workspace.activeSpace == .desktopA)
    #expect(workspace.isPanelVisible)
    #expect(workspace.panelSpace == .desktopB)
    #expect(!workspace.isPanelOnActiveSpace)
    #expect(!workspace.isPanelFrontmost)
    #expect(!workspace.isPanelKey)
    #expect(!workspace.isAppActive)
    #expect(!workspace.isComposerFocused)

    // Returning to Space B restores the Panel there because it was active when leaving Space B.
    workspace.advanceTime(by: 2.0)
    workspace.switchSpace(to: .desktopB)

    #expect(workspace.activeSpace == .desktopB)
    #expect(workspace.panelSpace == .desktopB)
    #expect(workspace.isPanelFrontmost)
    #expect(workspace.isPanelKey)
    #expect(workspace.isAppActive)
    #expect(workspace.isComposerFocused)
}

@MainActor
@Test(arguments: ["hideOnSpaceA", "smartToggleHideOnSpaceA", "hideWhileOffSpace"])
func hidingPanelClearsPendingSpaceReturnRestoration(scenario: String) {
    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    let coordinator = WindowCoordinator(workspace: workspace)

    coordinator.showPanel()
    switch scenario {
    case "hideOnSpaceA":
        coordinator.hidePanel()
        workspace.switchSpace(to: .desktopB)
    case "smartToggleHideOnSpaceA":
        coordinator.togglePanelFromHotKey()
        workspace.switchSpace(to: .desktopB)
    default:
        workspace.switchSpace(to: .desktopB)
        coordinator.hidePanel()
    }

    workspace.advanceTime(by: 2.0)
    workspace.switchSpace(to: .desktopA)

    #expect(workspace.activeSpace == .desktopA)
    #expect(!workspace.isPanelVisible)
    #expect(workspace.panelSpace == nil)
    #expect(!workspace.isPanelFrontmost)
    #expect(!workspace.isPanelKey)
    #expect(!workspace.isAppActive)
    #expect(!workspace.isComposerFocused)
}

@MainActor
@Test(arguments: [true, false])
func activeTurnCompletingOnAnotherSpaceDoesNotStealFocusOrSwitchSpaces(panelWasActiveBeforeLeaving: Bool) async throws {
    let backend = ControllableChatBackend()
    let store = ChatStore { backend }
    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    let coordinator = WindowCoordinator(
        workspace: workspace,
        onShow: { store.show() },
        onHide: { store.hide() },
        onNewChat: { store.newChat() }
    )
    store.shouldFocusComposer = { coordinator.canFocusComposerOnActiveSpace() }

    coordinator.showPanel()
    backend.emit(BridgeEvent(type: "ready", model: "gpt-6-luna"))
    try await waitUntil { store.session.phase == .ready }

    // While Panel is active on Space A, starting and completing a turn keeps Composer focus updates allowed.
    store.draft = "First prompt"
    store.send()
    #expect(store.session.streaming)
    let tokenBeforeOnSpaceDone = store.focusToken
    backend.emit(BridgeEvent(type: "message", itemId: "reply-1", text: "First reply."))
    backend.emit(BridgeEvent(type: "done"))
    try await waitUntil { !store.session.streaming }
    #expect(store.focusToken == tokenBeforeOnSpaceDone + 1)

    // Start a second Active turn, then switch to Space B before it completes.
    store.draft = "Background prompt"
    store.send()
    #expect(store.session.streaming)

    if !panelWasActiveBeforeLeaving {
        workspace.otherAppTakesFocus()
        workspace.advanceTime(by: WindowCoordinator.spaceSwitchResignGraceInterval + 0.5)
    }

    workspace.switchSpace(to: .desktopB)
    let tokenBeforeBackgroundDone = store.focusToken

    backend.emit(BridgeEvent(type: "delta", itemId: "reply-2", delta: "Background"))
    backend.emit(BridgeEvent(type: "message", itemId: "reply-2", text: "Background reply."))
    backend.emit(BridgeEvent(type: "done"))
    try await waitUntil { !store.session.streaming }

    #expect(store.session.messages.last?.text == "Background reply.")
    #expect(store.focusToken == tokenBeforeBackgroundDone)
    #expect(workspace.activeSpace == .desktopB)
    #expect(workspace.isPanelVisible)
    #expect(workspace.panelSpace == .desktopA)
    #expect(!workspace.isPanelOnActiveSpace)
    #expect(!workspace.isPanelFrontmost)
    #expect(!workspace.isPanelKey)
    #expect(!workspace.isAppActive)
    #expect(!workspace.isComposerFocused)

    // Returning to Space A still honors whether the Panel or another app owned Space A before departure.
    workspace.advanceTime(by: 2.0)
    workspace.switchSpace(to: .desktopA)
    #expect(workspace.activeSpace == .desktopA)
    #expect(workspace.isPanelFrontmost == panelWasActiveBeforeLeaving)
    #expect(workspace.isPanelKey == panelWasActiveBeforeLeaving)
    #expect(workspace.isAppActive == panelWasActiveBeforeLeaving)
    #expect(workspace.isComposerFocused == panelWasActiveBeforeLeaving)

    // Completing a turn while another app is active on Space A also does not steal focus.
    if panelWasActiveBeforeLeaving {
        workspace.otherAppTakesFocus()
    }
    store.draft = "Prompt while unfocused"
    store.send()
    let tokenWhileUnfocused = store.focusToken
    backend.emit(BridgeEvent(type: "message", itemId: "reply-3", text: "Quiet reply."))
    backend.emit(BridgeEvent(type: "done"))
    try await waitUntil { !store.session.streaming }
    #expect(store.focusToken == tokenWhileUnfocused)
    #expect(!workspace.isPanelKey)
    #expect(!workspace.isAppActive)

    store.stop()
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(2), condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}

private final class ControllableChatBackend: ChatBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (BridgeEvent) -> Void)?

    func start(codexOverride: String, options: ChatClientOptions, onEvent: @escaping @Sendable (BridgeEvent) -> Void) {
        lock.withLock { sink = onEvent }
    }

    func send(_ command: [String: String]) {}

    func close(completion: (@Sendable () -> Void)?) {
        lock.withLock { sink = nil }
        completion?()
    }

    func emit(_ event: BridgeEvent) {
        let sink = lock.withLock { self.sink }
        sink?(event)
    }
}

enum FakeSpace: String, Sendable, Equatable {
    case desktopA
    case desktopB
    case desktopC
    case fullscreenApp
}

enum SpaceLeaveOrdering: String, Sendable, Equatable {
    case spaceChangeFirst
    case resignAfterSpaceFlip
    case resignBeforeSpaceFlip
}

@MainActor
private final class FakeWindowWorkspace: WindowWorkspace {
    private(set) var activeSpace: FakeSpace
    private(set) var panelSpace: FakeSpace?
    private(set) var isPanelVisible = false
    private(set) var isPanelFrontmost = false
    private(set) var isPanelKey = false
    private(set) var isAppActive = false
    private(set) var isComposerFocused = false
    private(set) var now: TimeInterval = 100.0
    var onEvent: ((WindowWorkspaceEvent) -> Void)?

    init(activeSpace: FakeSpace) {
        self.activeSpace = activeSpace
    }

    var isPanelOnActiveSpace: Bool {
        isPanelVisible && panelSpace == activeSpace
    }

    func advanceTime(by seconds: TimeInterval) {
        now += seconds
    }

    func switchSpace(to destination: FakeSpace, ordering: SpaceLeaveOrdering = .resignBeforeSpaceFlip) {
        guard destination != activeSpace else { return }
        let wasPanelKey = isPanelKey
        let wasAppActive = isAppActive

        switch ordering {
        case .spaceChangeFirst:
            activeSpace = destination
            if panelSpace != activeSpace {
                isPanelFrontmost = false
            }
            onEvent?(.activeSpaceDidChange)
            if wasPanelKey {
                isPanelKey = false
                isComposerFocused = false
                onEvent?(.panelDidResignKey)
            }
            if wasAppActive {
                isAppActive = false
                onEvent?(.appDidResignActive)
            }

        case .resignAfterSpaceFlip:
            activeSpace = destination
            if panelSpace != activeSpace {
                isPanelFrontmost = false
            }
            if wasPanelKey {
                isPanelKey = false
                isComposerFocused = false
                onEvent?(.panelDidResignKey)
            }
            if wasAppActive {
                isAppActive = false
                onEvent?(.appDidResignActive)
            }
            onEvent?(.activeSpaceDidChange)

        case .resignBeforeSpaceFlip:
            if wasPanelKey {
                isPanelKey = false
                isComposerFocused = false
                onEvent?(.panelDidResignKey)
            }
            if wasAppActive {
                isAppActive = false
                onEvent?(.appDidResignActive)
            }
            if wasPanelKey || wasAppActive {
                advanceTime(by: 0.15)
            }
            activeSpace = destination
            if panelSpace != activeSpace {
                isPanelFrontmost = false
            }
            onEvent?(.activeSpaceDidChange)
        }
    }

    func otherAppTakesFocus(retainStalePanelKey: Bool = false) {
        let wasPanelKey = isPanelKey
        let wasAppActive = isAppActive
        isAppActive = false
        isPanelFrontmost = false
        isComposerFocused = false
        isPanelKey = retainStalePanelKey
        if wasPanelKey && !retainStalePanelKey {
            onEvent?(.panelDidResignKey)
        }
        if wasAppActive {
            onEvent?(.appDidResignActive)
        }
    }

    func secondaryWindowTakesFocus() {
        let wasPanelKey = isPanelKey
        isAppActive = true
        isPanelFrontmost = false
        isPanelKey = false
        isComposerFocused = false
        if wasPanelKey {
            onEvent?(.panelDidResignKey)
        }
        onEvent?(.otherAppWindowDidBecomeKey)
    }

    func userClicksPanel() {
        guard isPanelVisible, isPanelOnActiveSpace else { return }
        isPanelFrontmost = true
        isPanelKey = true
        onEvent?(.panelDidBecomeKey)
    }

    func orderOutPanel() {
        let wasPanelKey = isPanelKey
        isPanelVisible = false
        panelSpace = nil
        isPanelFrontmost = false
        isPanelKey = false
        isComposerFocused = false
        if wasPanelKey {
            onEvent?(.panelDidResignKey)
        }
    }

    func orderFrontAndMakePanelKey() {
        // Model macOS AppKit behavior: an already-visible panel on another Space
        // stays stranded on its original Space unless detached via orderOut first.
        if isPanelVisible, let existingSpace = panelSpace, existingSpace != activeSpace {
            isPanelKey = false
            isPanelFrontmost = false
            return
        }
        let becameKey = !isPanelKey
        isPanelVisible = true
        panelSpace = activeSpace
        isPanelFrontmost = true
        isPanelKey = true
        if becameKey {
            onEvent?(.panelDidBecomeKey)
        }
    }

    func activateApp() {
        // Model macOS WindowServer behavior: activating the app while its only visible
        // panel lives on another Space switches the user back to that Space.
        if isPanelVisible, let existingSpace = panelSpace, existingSpace != activeSpace {
            activeSpace = existingSpace
        }
        isAppActive = true
    }

    func focusComposer() {
        guard isPanelVisible, isPanelOnActiveSpace, isPanelKey else { return }
        isComposerFocused = true
    }

    func stopObserving() {
        onEvent = nil
    }
}
