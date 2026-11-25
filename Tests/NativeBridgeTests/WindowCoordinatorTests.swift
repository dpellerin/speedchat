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

enum FakeSpace: String, Sendable, Equatable {
    case desktopA
    case desktopB
    case fullscreenApp
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
    private(set) var isPanelVisible = false
    private(set) var isPanelFrontmost = false
    private(set) var isPanelKey = false
    private(set) var isAppActive = false
    private(set) var isComposerFocused = false
    private(set) var displays: [DisplayBounds]
    private(set) var activeDisplay: DisplayBounds?
    private(set) var panelFrame: CGRect
    private(set) var frameUpdateCount = 0
    private var secondaryStates: [SecondaryWindow: SecondaryWindowState] = [:]

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

    func setPanelFrame(_ frame: CGRect) {
        panelFrame = frame
        frameUpdateCount += 1
    }

    var isPanelOnActiveSpace: Bool {
        isPanelVisible && panelSpace == activeSpace
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

    func switchSpace(to destination: FakeSpace) {
        guard destination != activeSpace else { return }
        activeSpace = destination
        isPanelKey = false
        isAppActive = false
        isComposerFocused = false
        if panelSpace != activeSpace {
            isPanelFrontmost = false
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

    func otherAppTakesFocus(retainStalePanelKey: Bool = false) {
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
        clearSecondaryKeyAndFrontmost()
        isPanelVisible = true
        panelSpace = activeSpace
        isPanelFrontmost = true
        isPanelKey = true
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
        isPanelKey = false
        isPanelFrontmost = false
        isComposerFocused = false
        clearSecondaryKeyAndFrontmost()
        state.isVisible = true
        state.space = activeSpace
        state.isFrontmost = true
        state.isKey = true
        secondaryStates[window] = state
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

    private func clearSecondaryKeyAndFrontmost() {
        for window in SecondaryWindow.allCases {
            guard var state = secondaryStates[window] else { continue }
            state.isKey = false
            state.isFrontmost = false
            secondaryStates[window] = state
        }
    }
}
