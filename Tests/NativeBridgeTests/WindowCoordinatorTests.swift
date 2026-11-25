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

enum FakeSpace: String, Sendable, Equatable {
    case desktopA
    case desktopB
    case fullscreenApp
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

    init(activeSpace: FakeSpace) {
        self.activeSpace = activeSpace
    }

    var isPanelOnActiveSpace: Bool {
        isPanelVisible && panelSpace == activeSpace
    }

    func switchSpace(to destination: FakeSpace) {
        guard destination != activeSpace else { return }
        activeSpace = destination
        isPanelKey = false
        isAppActive = false
        isComposerFocused = false
        if panelSpace != activeSpace {
            isPanelFrontmost = false
        }
    }

    func otherAppTakesFocus(retainStalePanelKey: Bool = false) {
        isAppActive = false
        isPanelFrontmost = false
        isComposerFocused = false
        isPanelKey = retainStalePanelKey
    }

    func secondaryWindowTakesFocus() {
        isAppActive = true
        isPanelFrontmost = false
        isPanelKey = false
        isComposerFocused = false
    }

    func orderOutPanel() {
        isPanelVisible = false
        panelSpace = nil
        isPanelFrontmost = false
        isPanelKey = false
        isComposerFocused = false
    }

    func orderFrontAndMakePanelKey() {
        // Model macOS AppKit behavior: an already-visible panel on another Space
        // stays stranded on its original Space unless detached via orderOut first.
        if isPanelVisible, let existingSpace = panelSpace, existingSpace != activeSpace {
            isPanelKey = false
            isPanelFrontmost = false
            return
        }
        isPanelVisible = true
        panelSpace = activeSpace
        isPanelFrontmost = true
        isPanelKey = true
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
}
