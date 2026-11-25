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
@Test(arguments: FocusedPanelHideScenario.allCases)
func globalShortcutHidesPanelWhenAlreadyFrontmostAndFocusedOnCurrentSpace(scenario: FocusedPanelHideScenario) {
    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    var showCount = 0
    var hideCount = 0
    let coordinator = WindowCoordinator(
        workspace: workspace,
        onShow: { showCount += 1 },
        onHide: { hideCount += 1 }
    )

    coordinator.showPanel()
    if scenario == .clickedNonActivatingPanel {
        workspace.otherAppTakesFocus()
        workspace.userClicksPanel()
        #expect(workspace.isPanelKey)
        #expect(!workspace.isAppActive)
    }

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
@Test(arguments: UnfocusedPanelScenario.allCases)
func globalShortcutRaisesAndFocusesUnfocusedPanelOnCurrentSpace(scenario: UnfocusedPanelScenario) {
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
    case .anotherApp:
        workspace.otherAppTakesFocus()
    case .secondaryWindow:
        workspace.secondaryWindowTakesFocus()
    }
    #expect(!workspace.isPanelKey)

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
@Test func secondaryWindowCollectionBehaviorUsesSingleSpaceWithoutAllSpaces() {
    let behavior = WindowCoordinator.secondaryWindowCollectionBehavior
    #expect(behavior.contains(.moveToActiveSpace))
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
@Test(arguments: SpaceLeaveOrdering.allCases)
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
@Test func slowMissionControlOrSwipeWithoutOtherAppActivationRestoresPanelOnReturn() {
    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    let coordinator = WindowCoordinator(workspace: workspace)

    coordinator.showPanel()
    // Mission Control or a slow trackpad swipe resigns panel key without activating
    // another app, and more than 1.0s elapses before activeSpaceDidChange arrives.
    workspace.resignPanelWithoutOtherApp()
    workspace.advanceTime(by: 1.5)
    workspace.switchSpace(to: .desktopB, ordering: .spaceChangeFirst)

    #expect(workspace.activeSpace == .desktopB)
    #expect(!workspace.isPanelOnActiveSpace)

    workspace.advanceTime(by: 3.0)
    workspace.switchSpace(to: .desktopA)

    #expect(workspace.activeSpace == .desktopA)
    #expect(workspace.isPanelVisible)
    #expect(workspace.panelSpace == .desktopA)
    #expect(workspace.isPanelFrontmost)
    #expect(workspace.isPanelKey)
    #expect(workspace.isAppActive)
    #expect(workspace.isComposerFocused)
}

@MainActor
@Test(arguments: SpaceFocusStealScenario.allCases)
func returningToPanelSpaceLeavesOtherActiveAppOrWindowFrontmost(scenario: SpaceFocusStealScenario) {
    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    let coordinator = WindowCoordinator(workspace: workspace)

    coordinator.showPanel()
    switch scenario {
    case .anotherApp:
        // Quick click on another app on Space A followed by a Space switch 0.3s later
        // (past the short WindowServer commit-race window) must NOT steal focus on return.
        workspace.otherAppTakesFocus()
        workspace.advanceTime(by: 0.3)
    case .anotherAppWithStalePanelKey:
        workspace.otherAppTakesFocus(retainStalePanelKey: true)
        workspace.advanceTime(by: 0.3)
    case .anotherAppFollowedBySecondAppSwitch:
        // Clicking a second app on Space A right before switching Spaces must not reopen
        // the commit-race window for the Panel.
        workspace.otherAppTakesFocus()
        workspace.advanceTime(by: 0.3)
        workspace.otherAppTakesFocus()
        workspace.advanceTime(by: 0.05)
    case .secondaryWindow:
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
@Test(arguments: PanelSummonTrigger.allCases)
func pullingPanelOntoAnotherSpaceClearsPriorSpaceRestoration(trigger: PanelSummonTrigger) {
    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    let coordinator = WindowCoordinator(workspace: workspace)

    coordinator.showPanel()
    workspace.switchSpace(to: .desktopB)

    switch trigger {
    case .hotkey:
        coordinator.togglePanelFromHotKey()
    case .menuShow:
        coordinator.showPanel()
    case .menuNewChat:
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
@Test(arguments: PanelHideScenario.allCases)
func hidingPanelClearsPendingSpaceReturnRestoration(scenario: PanelHideScenario) {
    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    let coordinator = WindowCoordinator(workspace: workspace)

    coordinator.showPanel()
    switch scenario {
    case .hideOnSpaceA:
        coordinator.hidePanel()
        workspace.switchSpace(to: .desktopB)
    case .smartToggleHideOnSpaceA:
        coordinator.togglePanelFromHotKey()
        workspace.switchSpace(to: .desktopB)
    case .hideWhileOffSpace:
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
        workspace.advanceTime(by: 0.3)
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
@Test(arguments: SecondaryWindow.allCases)
func reopeningSecondaryWindowOnAnotherSpaceMovesOnlyThatWindowWithoutDraggingPanel(window: SecondaryWindow) {
    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    var showCount = 0
    var hideCount = 0
    let coordinator = WindowCoordinator(
        workspace: workspace,
        onShow: { showCount += 1 },
        onHide: { hideCount += 1 }
    )

    // Open Panel and secondary window on Space A.
    coordinator.showPanel()
    coordinator.showSecondaryWindow(window)
    #expect(workspace.panelSpace == .desktopA)
    #expect(workspace.secondarySpace(for: window) == .desktopA)
    #expect(workspace.isSecondaryKey(window))

    // Switch to Space B: both stay on Space A.
    workspace.switchSpace(to: .desktopB)
    #expect(workspace.activeSpace == .desktopB)
    #expect(workspace.panelSpace == .desktopA)
    #expect(workspace.secondarySpace(for: window) == .desktopA)

    // Reopen the secondary window from Space B: moves only that window to Space B,
    // focuses it without bouncing back to Space A, and leaves the Panel on Space A.
    coordinator.showSecondaryWindow(window)
    #expect(workspace.activeSpace == .desktopB)
    #expect(workspace.isSecondaryVisible(window))
    #expect(workspace.secondarySpace(for: window) == .desktopB)
    #expect(workspace.isSecondaryFrontmost(window))
    #expect(workspace.isSecondaryKey(window))
    #expect(workspace.isAppActive)
    #expect(workspace.isPanelVisible)
    #expect(workspace.panelSpace == .desktopA)
    #expect(!workspace.isPanelKey)
    #expect(showCount == 1)
    #expect(hideCount == 0)
}

@MainActor
@Test(arguments: SecondaryWindow.allCases)
func openingClosedSecondaryWindowOnSpaceBLeavesOpenPanelOnSpaceA(window: SecondaryWindow) {
    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    let coordinator = WindowCoordinator(workspace: workspace)

    coordinator.showPanel()
    workspace.switchSpace(to: .desktopB)

    coordinator.showSecondaryWindow(window)

    #expect(workspace.activeSpace == .desktopB)
    #expect(workspace.isSecondaryVisible(window))
    #expect(workspace.secondarySpace(for: window) == .desktopB)
    #expect(workspace.isSecondaryFrontmost(window))
    #expect(workspace.isSecondaryKey(window))
    #expect(workspace.isAppActive)
    #expect(workspace.isPanelVisible)
    #expect(workspace.panelSpace == .desktopA)
    #expect(!workspace.isPanelKey)
}

@MainActor
@Test(arguments: SecondaryWindow.allCases)
func summoningPanelOnSpaceBWithSecondaryWindowOnSpaceANeverSwitchesSpaces(window: SecondaryWindow) {
    let workspace = FakeWindowWorkspace(activeSpace: .desktopA)
    let coordinator = WindowCoordinator(workspace: workspace)

    // Case 1: Panel is hidden while Settings/About is open on Space A.
    coordinator.showSecondaryWindow(window)
    #expect(workspace.isSecondaryVisible(window))
    #expect(workspace.secondarySpace(for: window) == .desktopA)
    #expect(!workspace.isPanelVisible)

    workspace.switchSpace(to: .desktopB)
    coordinator.togglePanelFromHotKey()

    #expect(workspace.activeSpace == .desktopB)
    #expect(workspace.isPanelVisible)
    #expect(workspace.panelSpace == .desktopB)
    #expect(workspace.isPanelFrontmost)
    #expect(workspace.isPanelKey)
    #expect(workspace.isAppActive)
    #expect(workspace.isComposerFocused)
    #expect(workspace.isSecondaryVisible(window))
    #expect(workspace.secondarySpace(for: window) == .desktopA)
    #expect(!workspace.isSecondaryKey(window))

    // Case 2: Both Panel and secondary window are open on Space A; summoning from Space B pulls only the Panel.
    workspace.switchSpace(to: .desktopA)
    coordinator.showPanel()
    #expect(workspace.panelSpace == .desktopA)
    #expect(workspace.secondarySpace(for: window) == .desktopA)

    workspace.switchSpace(to: .desktopB)
    coordinator.showPanel()

    #expect(workspace.activeSpace == .desktopB)
    #expect(workspace.panelSpace == .desktopB)
    #expect(workspace.isPanelFrontmost)
    #expect(workspace.isPanelKey)
    #expect(workspace.isComposerFocused)
    #expect(workspace.isSecondaryVisible(window))
    #expect(workspace.secondarySpace(for: window) == .desktopA)
}

@MainActor
@Test func summoningPanelOnAnotherDisplayRelocatesPreservingSizeAndClampingToVisibleBounds() {
    let laptop = DisplayBounds(
        id: "laptop",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 874)
    )
    let external = DisplayBounds(
        id: "external",
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415)
    )
    let initialFrame = CGRect(x: 2400, y: 400, width: 790, height: 740)
    let workspace = FakeWindowWorkspace(
        activeSpace: .desktopA,
        displays: [laptop, external],
        activeDisplay: external,
        panelFrame: initialFrame
    )
    let coordinator = WindowCoordinator(workspace: workspace)

    // Open Panel on the external display, then move to the laptop display and another Space.
    coordinator.showPanel()
    #expect(workspace.panelFrame == initialFrame)

    workspace.switchSpace(to: .desktopB)
    workspace.setActiveDisplay(laptop)
    coordinator.togglePanelFromHotKey()

    let moved = workspace.panelFrame
    #expect(moved.width == initialFrame.width)
    #expect(moved.height == initialFrame.height)
    #expect(moved.minX >= laptop.visibleFrame.minX)
    #expect(moved.maxX <= laptop.visibleFrame.maxX)
    #expect(moved.minY >= laptop.visibleFrame.minY)
    #expect(moved.maxY <= laptop.visibleFrame.maxY)
    #expect(workspace.panelSpace == .desktopB)
    #expect(workspace.isPanelVisible)
    #expect(workspace.isPanelKey)
    #expect(workspace.isComposerFocused)

    // Hide on laptop, move back to external display, and summon from hidden: relocates back to external.
    coordinator.hidePanel()
    workspace.setActiveDisplay(external)
    coordinator.showPanel()

    let returned = workspace.panelFrame
    #expect(returned.width == initialFrame.width)
    #expect(returned.height == initialFrame.height)
    #expect(returned.minX >= external.visibleFrame.minX)
    #expect(returned.maxX <= external.visibleFrame.maxX)
    #expect(returned.minY >= external.visibleFrame.minY)
    #expect(returned.maxY <= external.visibleFrame.maxY)
}

@MainActor
@Test(arguments: [FakeSpace.desktopB, .fullscreenApp])
func pullingVisiblePanelAcrossDisplaysDetachesBeforeMovingOntoTargetDisplaySpace(targetDisplaySpace: FakeSpace) {
    let display1 = DisplayBounds(
        id: "display-1",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 874)
    )
    let display2 = DisplayBounds(
        id: "display-2",
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415)
    )
    let initialFrame = CGRect(x: 360, y: 120, width: 790, height: 740)
    let workspace = FakeWindowWorkspace(
        activeSpace: .desktopA,
        displays: [display1, display2],
        activeDisplay: display1,
        panelFrame: initialFrame
    )
    var showCount = 0
    var hideCount = 0
    let coordinator = WindowCoordinator(
        workspace: workspace,
        onShow: { showCount += 1 },
        onHide: { hideCount += 1 }
    )

    // Panel is visible on Display 1's active Space.
    coordinator.showPanel()
    #expect(workspace.isPanelVisible)
    #expect(workspace.isPanelOnActiveSpace)
    #expect(workspace.panelSpace == .desktopA)

    // Under macOS "Displays have separate Spaces", switching focus to an app on Display 2
    // (including a fullscreen Space on Display 2) leaves Display 1's Space active, so the
    // visible Panel on Display 1 still reports isPanelOnActiveSpace == true.
    workspace.otherAppTakesFocus()
    workspace.focusDisplay(display2, activeSpace: targetDisplaySpace, keepOtherDisplaysActive: true)
    #expect(workspace.isPanelVisible)
    #expect(workspace.isPanelOnActiveSpace)
    #expect(!workspace.isPanelKey)

    workspace.clearRecordedPanelOperations()
    coordinator.togglePanelFromHotKey()

    let moved = workspace.panelFrame
    #expect(moved.width == initialFrame.width)
    #expect(moved.height == initialFrame.height)
    #expect(moved.minX >= display2.visibleFrame.minX)
    #expect(moved.maxX <= display2.visibleFrame.maxX)
    #expect(moved.minY >= display2.visibleFrame.minY)
    #expect(moved.maxY <= display2.visibleFrame.maxY)
    #expect(workspace.panelSpace == targetDisplaySpace)
    #expect(workspace.isPanelVisible)
    #expect(workspace.isPanelFrontmost)
    #expect(workspace.isPanelKey)
    #expect(workspace.isAppActive)
    #expect(workspace.isComposerFocused)
    #expect(workspace.recordedPanelOperations == [.orderOut, .setFrame, .orderFrontAndMakeKey])
    #expect(showCount == 2)
    #expect(hideCount == 0)
}

@MainActor
@Test func relocatingOversizedOrOffscreenPanelClampsWithinDestinationVisibleBounds() {
    let leftMonitor = DisplayBounds(
        id: "left",
        frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: -2560, y: 0, width: 2560, height: 1415)
    )
    let compactLaptop = DisplayBounds(
        id: "compact",
        frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
        visibleFrame: CGRect(x: 0, y: 64, width: 1280, height: 711)
    )

    // Oversized panel on left monitor summoned onto smaller laptop display.
    let oversized = CGRect(x: -2200, y: 200, width: 1400, height: 900)
    let oversizedWorkspace = FakeWindowWorkspace(
        activeSpace: .desktopA,
        displays: [leftMonitor, compactLaptop],
        activeDisplay: compactLaptop,
        panelFrame: oversized
    )
    WindowCoordinator(workspace: oversizedWorkspace).showPanel()
    #expect(oversizedWorkspace.panelFrame.width == compactLaptop.visibleFrame.width)
    #expect(oversizedWorkspace.panelFrame.height == compactLaptop.visibleFrame.height)
    #expect(oversizedWorkspace.panelFrame.minX == compactLaptop.visibleFrame.minX)
    #expect(oversizedWorkspace.panelFrame.minY == compactLaptop.visibleFrame.minY)

    // Panel hanging off the top-left of left monitor summoned onto laptop display keeps size and clamps inside visible bounds.
    let clipped = CGRect(x: -2700, y: 1000, width: 790, height: 600)
    let clippedWorkspace = FakeWindowWorkspace(
        activeSpace: .desktopA,
        displays: [leftMonitor, compactLaptop],
        activeDisplay: compactLaptop,
        panelFrame: clipped
    )
    WindowCoordinator(workspace: clippedWorkspace).showPanel()
    #expect(clippedWorkspace.panelFrame.width == 790)
    #expect(clippedWorkspace.panelFrame.height == 600)
    #expect(clippedWorkspace.panelFrame.minX >= compactLaptop.visibleFrame.minX)
    #expect(clippedWorkspace.panelFrame.maxX <= compactLaptop.visibleFrame.maxX)
    #expect(clippedWorkspace.panelFrame.minY >= compactLaptop.visibleFrame.minY)
    #expect(clippedWorkspace.panelFrame.maxY <= compactLaptop.visibleFrame.maxY)

    // Saved frame on a disconnected monitor relocates onto the active display cleanly.
    let disconnected = CGRect(x: 5000, y: 200, width: 790, height: 600)
    let disconnectedWorkspace = FakeWindowWorkspace(
        activeSpace: .desktopA,
        displays: [compactLaptop],
        activeDisplay: compactLaptop,
        panelFrame: disconnected
    )
    WindowCoordinator(workspace: disconnectedWorkspace).showPanel()
    #expect(disconnectedWorkspace.panelFrame.width == 790)
    #expect(disconnectedWorkspace.panelFrame.height == 600)
    #expect(disconnectedWorkspace.panelFrame.minX >= compactLaptop.visibleFrame.minX)
    #expect(disconnectedWorkspace.panelFrame.maxX <= compactLaptop.visibleFrame.maxX)
    #expect(disconnectedWorkspace.panelFrame.minY >= compactLaptop.visibleFrame.minY)
    #expect(disconnectedWorkspace.panelFrame.maxY <= compactLaptop.visibleFrame.maxY)
}

@MainActor
@Test func summoningOrPullingOnSameDisplayPreservesSavedFrameUntouched() {
    let laptop = DisplayBounds(
        id: "laptop",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 874)
    )
    let external = DisplayBounds(
        id: "external",
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415)
    )

    // Single-display Mac with an off-center custom saved frame.
    let singleDisplayFrame = CGRect(x: 42, y: 118, width: 640, height: 590)
    let singleWorkspace = FakeWindowWorkspace(
        activeSpace: .desktopA,
        displays: [laptop],
        activeDisplay: laptop,
        panelFrame: singleDisplayFrame
    )
    let singleCoordinator = WindowCoordinator(workspace: singleWorkspace)

    singleCoordinator.togglePanelFromHotKey()
    singleWorkspace.switchSpace(to: .desktopB)
    singleCoordinator.togglePanelFromHotKey()
    singleWorkspace.switchSpace(to: .fullscreenApp)
    singleCoordinator.newChatFromMenu()
    singleCoordinator.hidePanel()
    singleCoordinator.showPanel()

    #expect(singleWorkspace.panelFrame == singleDisplayFrame)
    #expect(singleWorkspace.frameUpdateCount == 0)

    // Multi-display Mac summoning/pulling while staying on the external display leaves frame untouched.
    let externalFrame = CGRect(x: 1620, y: 210, width: 820, height: 700)
    let multiWorkspace = FakeWindowWorkspace(
        activeSpace: .desktopA,
        displays: [laptop, external],
        activeDisplay: external,
        panelFrame: externalFrame
    )
    let multiCoordinator = WindowCoordinator(workspace: multiWorkspace)

    multiCoordinator.showPanel()
    multiWorkspace.switchSpace(to: .desktopB)
    multiCoordinator.togglePanelFromHotKey()

    #expect(multiWorkspace.panelFrame == externalFrame)
    #expect(multiWorkspace.frameUpdateCount == 0)

    // When already frontmost and focused, smart-toggle hides without relocating even if activeDisplay changed.
    multiWorkspace.setActiveDisplay(laptop)
    multiCoordinator.togglePanelFromHotKey()
    #expect(!multiWorkspace.isPanelVisible)
    #expect(multiWorkspace.panelFrame == externalFrame)
    #expect(multiWorkspace.frameUpdateCount == 0)
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

enum FocusedPanelHideScenario: String, Sendable, Equatable, CaseIterable {
    case activeApp
    case clickedNonActivatingPanel
}

enum UnfocusedPanelScenario: String, Sendable, Equatable, CaseIterable {
    case anotherApp
    case secondaryWindow
}

enum SpaceFocusStealScenario: String, Sendable, Equatable, CaseIterable {
    case anotherApp
    case anotherAppWithStalePanelKey
    case anotherAppFollowedBySecondAppSwitch
    case secondaryWindow
}

enum PanelSummonTrigger: String, Sendable, Equatable, CaseIterable {
    case hotkey
    case menuShow
    case menuNewChat
}

enum PanelHideScenario: String, Sendable, Equatable, CaseIterable {
    case hideOnSpaceA
    case smartToggleHideOnSpaceA
    case hideWhileOffSpace
}

enum FakeSpace: String, Sendable, Equatable {
    case desktopA
    case desktopB
    case desktopC
    case fullscreenApp
}

enum SpaceLeaveOrdering: String, Sendable, Equatable, CaseIterable {
    case spaceChangeFirst
    case resignAfterSpaceFlip
    case resignBeforeSpaceFlip
    case destinationAppActivatesBeforeSpaceFlip
    case destinationAppActivatesAfterSpaceFlip
}

enum PanelOperation: Equatable, Sendable {
    case orderOut
    case setFrame
    case orderFrontAndMakeKey
}

@MainActor
private final class FakeWindowWorkspace: WindowWorkspace {
    private static let defaultDisplay = DisplayBounds(
        id: "primary",
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 64, width: 1440, height: 811)
    )

    private struct SecondaryWindowState {
        var isVisible = false
        var space: FakeSpace?
        var isFrontmost = false
        var isKey = false
    }

    private(set) var activeSpace: FakeSpace
    private(set) var panelSpace: FakeSpace?
    private var visibleSpacesOnOtherDisplays: Set<FakeSpace> = []
    private(set) var isPanelVisible = false
    private(set) var isPanelFrontmost = false
    private(set) var isPanelKey = false
    private(set) var isAppActive = false
    private(set) var isComposerFocused = false
    private(set) var displays: [DisplayBounds]
    private(set) var activeDisplay: DisplayBounds?
    private(set) var panelFrame: CGRect
    private(set) var frameUpdateCount = 0
    private(set) var recordedPanelOperations: [PanelOperation] = []
    private var secondaryStates: [SecondaryWindow: SecondaryWindowState] = [:]
    private(set) var now: TimeInterval = 100.0
    var onEvent: ((WindowWorkspaceEvent) -> Void)?

    init(
        activeSpace: FakeSpace,
        displays: [DisplayBounds]? = nil,
        activeDisplay: DisplayBounds? = nil,
        panelFrame: CGRect = CGRect(x: 325, y: 100, width: 790, height: 740)
    ) {
        let resolvedDisplays = displays ?? [Self.defaultDisplay]
        self.activeSpace = activeSpace
        self.displays = resolvedDisplays
        self.activeDisplay = activeDisplay ?? resolvedDisplays.first
        self.panelFrame = panelFrame
    }

    func setActiveDisplay(_ display: DisplayBounds?) {
        activeDisplay = display
    }

    func focusDisplay(_ display: DisplayBounds, activeSpace targetSpace: FakeSpace, keepOtherDisplaysActive: Bool) {
        if keepOtherDisplaysActive {
            visibleSpacesOnOtherDisplays.insert(activeSpace)
        } else {
            visibleSpacesOnOtherDisplays.removeAll()
        }
        visibleSpacesOnOtherDisplays.remove(targetSpace)
        activeDisplay = display
        activeSpace = targetSpace
    }

    func clearRecordedPanelOperations() {
        recordedPanelOperations.removeAll()
    }

    func setPanelFrame(_ frame: CGRect) {
        panelFrame = frame
        frameUpdateCount += 1
        recordedPanelOperations.append(.setFrame)
    }

    var isPanelOnActiveSpace: Bool {
        guard isPanelVisible, let panelSpace else { return false }
        return panelSpace == activeSpace || visibleSpacesOnOtherDisplays.contains(panelSpace)
    }

    func isSecondaryVisible(_ window: SecondaryWindow) -> Bool {
        secondaryStates[window]?.isVisible ?? false
    }

    func secondarySpace(for window: SecondaryWindow) -> FakeSpace? {
        secondaryStates[window]?.space
    }

    func isSecondaryFrontmost(_ window: SecondaryWindow) -> Bool {
        secondaryStates[window]?.isFrontmost ?? false
    }

    func isSecondaryKey(_ window: SecondaryWindow) -> Bool {
        secondaryStates[window]?.isKey ?? false
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

        case .destinationAppActivatesBeforeSpaceFlip:
            if wasPanelKey {
                isPanelKey = false
                isComposerFocused = false
                onEvent?(.panelDidResignKey)
            }
            if wasAppActive {
                isAppActive = false
                onEvent?(.appDidResignActive)
            }
            onEvent?(.otherAppDidActivate)
            advanceTime(by: 0.05)
            activeSpace = destination
            if panelSpace != activeSpace {
                isPanelFrontmost = false
            }
            onEvent?(.activeSpaceDidChange)

        case .destinationAppActivatesAfterSpaceFlip:
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
            onEvent?(.otherAppDidActivate)
            onEvent?(.activeSpaceDidChange)
        }
        for window in SecondaryWindow.allCases {
            guard var state = secondaryStates[window] else { continue }
            state.isKey = false
            if state.space != activeSpace {
                state.isFrontmost = false
            }
            secondaryStates[window] = state
        }
    }

    func resignPanelWithoutOtherApp() {
        let wasPanelKey = isPanelKey
        let wasAppActive = isAppActive
        isAppActive = false
        isPanelKey = false
        isComposerFocused = false
        if wasPanelKey {
            onEvent?(.panelDidResignKey)
        }
        if wasAppActive {
            onEvent?(.appDidResignActive)
        }
    }

    func otherAppTakesFocus(retainStalePanelKey: Bool = false) {
        let wasPanelKey = isPanelKey
        let wasAppActive = isAppActive
        isAppActive = false
        isPanelFrontmost = false
        isComposerFocused = false
        isPanelKey = retainStalePanelKey
        for window in SecondaryWindow.allCases {
            guard var state = secondaryStates[window] else { continue }
            state.isFrontmost = false
            state.isKey = false
            secondaryStates[window] = state
        }
        if wasPanelKey && !retainStalePanelKey {
            onEvent?(.panelDidResignKey)
        }
        if wasAppActive {
            onEvent?(.appDidResignActive)
        }
        onEvent?(.otherAppDidActivate)
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
        recordedPanelOperations.append(.orderOut)
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
        recordedPanelOperations.append(.orderFrontAndMakeKey)
        // Model macOS AppKit behavior: an already-visible panel on another Space
        // (including another display's active Space under "Displays have separate Spaces")
        // stays stranded on its original Space unless detached via orderOut first.
        if isPanelVisible, let existingSpace = panelSpace, existingSpace != activeSpace {
            isPanelKey = false
            isPanelFrontmost = false
            return
        }
        clearSecondaryKeyAndFrontmost()
        let becameKey = !isPanelKey
        isPanelVisible = true
        panelSpace = activeSpace
        isPanelFrontmost = true
        isPanelKey = true
        if becameKey {
            onEvent?(.panelDidBecomeKey)
        }
    }

    func isSecondaryWindowVisible(_ window: SecondaryWindow) -> Bool {
        secondaryStates[window]?.isVisible ?? false
    }

    func isSecondaryWindowOnActiveSpace(_ window: SecondaryWindow) -> Bool {
        guard let state = secondaryStates[window] else { return false }
        return state.isVisible && state.space == activeSpace
    }

    func orderOutSecondaryWindow(_ window: SecondaryWindow) {
        secondaryStates[window] = SecondaryWindowState()
    }

    func orderFrontAndMakeSecondaryWindowKey(_ window: SecondaryWindow) {
        var state = secondaryStates[window] ?? SecondaryWindowState()
        // Model macOS AppKit behavior: an already-visible secondary window on another Space
        // stays stranded on its original Space unless detached via orderOut first.
        if state.isVisible, let existingSpace = state.space, existingSpace != activeSpace {
            state.isKey = false
            state.isFrontmost = false
            secondaryStates[window] = state
            return
        }
        let wasPanelKey = isPanelKey
        isPanelKey = false
        isPanelFrontmost = false
        isComposerFocused = false
        clearSecondaryKeyAndFrontmost()
        state.isVisible = true
        state.space = activeSpace
        state.isFrontmost = true
        state.isKey = true
        secondaryStates[window] = state
        if wasPanelKey {
            onEvent?(.panelDidResignKey)
        }
        onEvent?(.otherAppWindowDidBecomeKey)
    }

    func activateApp() {
        // Model macOS WindowServer behavior: activating the app when it has no visible
        // window on the active Space switches Spaces toward an existing visible window.
        let hasWindowOnActiveSpace = isPanelOnActiveSpace || SecondaryWindow.allCases.contains { isSecondaryWindowOnActiveSpace($0) }
        if !hasWindowOnActiveSpace {
            if isPanelVisible, let existingSpace = panelSpace {
                activeSpace = existingSpace
            } else if let otherSpace = SecondaryWindow.allCases.compactMap({ window -> FakeSpace? in
                guard let state = secondaryStates[window], state.isVisible else { return nil }
                return state.space
            }).first {
                activeSpace = otherSpace
            }
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

    private func clearSecondaryKeyAndFrontmost() {
        for window in SecondaryWindow.allCases {
            guard var state = secondaryStates[window] else { continue }
            state.isKey = false
            state.isFrontmost = false
            secondaryStates[window] = state
        }
    }
}
