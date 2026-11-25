import AppKit

enum SecondaryWindow: Sendable, Hashable, CaseIterable {
    case settings
    case about
}

struct DisplayBounds: Equatable, Sendable {
    let id: String
    let frame: CGRect
    let visibleFrame: CGRect

    static func displayContaining(_ frame: CGRect, in displays: [DisplayBounds]) -> DisplayBounds? {
        var bestDisplay: DisplayBounds?
        var bestArea: CGFloat = 0
        for display in displays {
            let intersection = frame.intersection(display.frame)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestDisplay = display
            }
        }
        return bestDisplay
    }

    static func relocatedFrame(
        for currentFrame: CGRect,
        from sourceDisplay: DisplayBounds?,
        to targetDisplay: DisplayBounds
    ) -> CGRect {
        let targetVisible = targetDisplay.visibleFrame
        let width = min(currentFrame.width, targetVisible.width)
        let height = min(currentFrame.height, targetVisible.height)

        let targetSlackX = max(0, targetVisible.width - width)
        let targetSlackY = max(0, targetVisible.height - height)

        let rawX: CGFloat
        let rawY: CGFloat
        if let sourceVisible = sourceDisplay?.visibleFrame {
            let sourceSlackX = sourceVisible.width - currentFrame.width
            let sourceSlackY = sourceVisible.height - currentFrame.height
            let ratioX = sourceSlackX > 0 ? (currentFrame.minX - sourceVisible.minX) / sourceSlackX : 0.5
            let ratioY = sourceSlackY > 0 ? (currentFrame.minY - sourceVisible.minY) / sourceSlackY : 0.5
            rawX = targetVisible.minX + ratioX * targetSlackX
            rawY = targetVisible.minY + ratioY * targetSlackY
        } else {
            rawX = targetVisible.minX + targetSlackX / 2
            rawY = targetVisible.minY + targetSlackY / 2
        }

        let clampedX = min(max(rawX.rounded(), targetVisible.minX), targetVisible.maxX - width)
        let clampedY = min(max(rawY.rounded(), targetVisible.minY), targetVisible.maxY - height)
        return CGRect(x: clampedX, y: clampedY, width: width, height: height)
    }
}

enum WindowWorkspaceEvent: Equatable, Sendable {
    case panelDidBecomeKey
    case panelDidResignKey
    case otherAppWindowDidBecomeKey
    case otherAppDidActivate
    case appDidResignActive
    case activeSpaceDidChange
}

@MainActor protocol WindowWorkspace: AnyObject {
    var isPanelVisible: Bool { get }
    var isPanelOnActiveSpace: Bool { get }
    var isPanelKey: Bool { get }
    var panelFrame: CGRect { get }
    var displays: [DisplayBounds] { get }
    var activeDisplay: DisplayBounds? { get }
    var now: TimeInterval { get }
    var onEvent: ((WindowWorkspaceEvent) -> Void)? { get set }

    func orderOutPanel()
    func setPanelFrame(_ frame: CGRect)
    func orderFrontAndMakePanelKey()
    func isSecondaryWindowVisible(_ window: SecondaryWindow) -> Bool
    func isSecondaryWindowOnActiveSpace(_ window: SecondaryWindow) -> Bool
    func orderOutSecondaryWindow(_ window: SecondaryWindow)
    func orderFrontAndMakeSecondaryWindowKey(_ window: SecondaryWindow)
    func activateApp()
    func focusComposer()
    func stopObserving()
}

@MainActor final class WindowCoordinator {
    static let panelCollectionBehavior: NSWindow.CollectionBehavior = [
        .moveToActiveSpace,
        .managed,
        .fullScreenAuxiliary
    ]
    static let spaceSwitchAppActivationRaceInterval: TimeInterval = 0.15

    static let secondaryWindowCollectionBehavior: NSWindow.CollectionBehavior = [
        .moveToActiveSpace
    ]

    private enum PanelSpaceOwnership {
        case none
        case activeOnSpace
        case resignedWithoutOtherApp
    }

    private let workspace: any WindowWorkspace
    private let onShow: () -> Void
    private let onHide: () -> Void
    private let onNewChat: () -> Void
    private var panelOwnership: PanelSpaceOwnership = .none
    private var otherAppActivatedAt: TimeInterval?
    private var shouldRestoreOnSpaceReturn = false

    init(
        workspace: any WindowWorkspace,
        onShow: @escaping () -> Void = {},
        onHide: @escaping () -> Void = {},
        onNewChat: @escaping () -> Void = {}
    ) {
        self.workspace = workspace
        self.onShow = onShow
        self.onHide = onHide
        self.onNewChat = onNewChat
        self.workspace.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        workspace.stopObserving()
        workspace.onEvent = nil
    }

    func togglePanelFromHotKey() {
        if workspace.isPanelVisible && workspace.isPanelOnActiveSpace && workspace.isPanelKey {
            hidePanel()
            return
        }
        showPanel()
    }

    func showPanel() {
        let crossDisplayTargetFrame = targetFrameForCrossDisplayRelocation()
        if workspace.isPanelVisible && (!workspace.isPanelOnActiveSpace || crossDisplayTargetFrame != nil) {
            // Detach from the non-active Space or other display's active Space
            // without treating relocation as a hide so AppKit enters the active
            // Space cleanly (including another display's fullscreen Space).
            workspace.orderOutPanel()
        }
        if let crossDisplayTargetFrame {
            workspace.setPanelFrame(crossDisplayTargetFrame)
        }
        clearRestorationState()
        onShow()
        focusPanelOnActiveSpace()
    }

    func hidePanel() {
        clearRestorationState()
        workspace.orderOutPanel()
        onHide()
    }

    static func canFocusComposer(isVisible: Bool, isOnActiveSpace: Bool, isKey: Bool) -> Bool {
        isVisible && isOnActiveSpace && isKey
    }

    func canFocusComposerOnActiveSpace() -> Bool {
        Self.canFocusComposer(
            isVisible: workspace.isPanelVisible,
            isOnActiveSpace: workspace.isPanelOnActiveSpace,
            isKey: workspace.isPanelKey
        )
    }

    func newChatFromMenu() {
        showPanel()
        onNewChat()
    }

    func showSecondaryWindow(_ window: SecondaryWindow) {
        if workspace.isSecondaryWindowVisible(window) && !workspace.isSecondaryWindowOnActiveSpace(window) {
            // Detach from the non-active Space first so ordering front moves only
            // this window onto the active Space without switching Spaces.
            workspace.orderOutSecondaryWindow(window)
        }
        workspace.orderFrontAndMakeSecondaryWindowKey(window)
        workspace.activateApp()
    }

    private func targetFrameForCrossDisplayRelocation() -> CGRect? {
        guard let targetDisplay = workspace.activeDisplay, !targetDisplay.visibleFrame.isEmpty else { return nil }
        let currentFrame = workspace.panelFrame
        guard !currentFrame.isEmpty else { return nil }
        let sourceDisplay = DisplayBounds.displayContaining(currentFrame, in: workspace.displays)
        if sourceDisplay?.id == targetDisplay.id {
            return nil
        }
        return DisplayBounds.relocatedFrame(for: currentFrame, from: sourceDisplay, to: targetDisplay)
    }

    private func handle(_ event: WindowWorkspaceEvent) {
        switch event {
        case .panelDidBecomeKey:
            guard workspace.isPanelVisible, workspace.isPanelOnActiveSpace else { return }
            panelOwnership = .activeOnSpace
            otherAppActivatedAt = nil
            shouldRestoreOnSpaceReturn = false

        case .otherAppWindowDidBecomeKey:
            if workspace.isPanelOnActiveSpace {
                clearRestorationState()
            }

        case .otherAppDidActivate:
            guard workspace.isPanelVisible else {
                clearRestorationState()
                return
            }
            if !workspace.isPanelOnActiveSpace {
                recordPanelLeftActiveSpace()
                return
            }
            if panelOwnership != .none {
                panelOwnership = .none
                otherAppActivatedAt = workspace.now
            }

        case .panelDidResignKey, .appDidResignActive:
            guard workspace.isPanelVisible else {
                clearRestorationState()
                return
            }
            if !workspace.isPanelOnActiveSpace {
                recordPanelLeftActiveSpace()
                return
            }
            if panelOwnership == .activeOnSpace {
                panelOwnership = .resignedWithoutOtherApp
            }

        case .activeSpaceDidChange:
            guard workspace.isPanelVisible else {
                clearRestorationState()
                return
            }
            if !workspace.isPanelOnActiveSpace {
                recordPanelLeftActiveSpace()
                return
            }
            if shouldRestoreOnSpaceReturn {
                focusPanelOnActiveSpace()
            }
        }
    }

    private var panelOwnedActiveSpace: Bool {
        panelOwnership != .none || isWithinOtherAppActivationRaceWindow()
    }

    private func isWithinOtherAppActivationRaceWindow() -> Bool {
        guard let otherAppActivatedAt else { return false }
        let elapsed = workspace.now - otherAppActivatedAt
        return elapsed >= 0 && elapsed <= Self.spaceSwitchAppActivationRaceInterval
    }

    private func recordPanelLeftActiveSpace() {
        if panelOwnedActiveSpace {
            shouldRestoreOnSpaceReturn = true
        }
        panelOwnership = .none
        otherAppActivatedAt = nil
    }

    private func focusPanelOnActiveSpace() {
        shouldRestoreOnSpaceReturn = false
        otherAppActivatedAt = nil
        workspace.orderFrontAndMakePanelKey()
        workspace.activateApp()
        workspace.focusComposer()
        panelOwnership = (workspace.isPanelVisible && workspace.isPanelOnActiveSpace) ? .activeOnSpace : .none
    }

    private func clearRestorationState() {
        shouldRestoreOnSpaceReturn = false
        panelOwnership = .none
        otherAppActivatedAt = nil
    }
}

@MainActor final class AppKitWindowWorkspace: WindowWorkspace {
    private weak var panel: NSPanel?
    private let secondaryWindowProvider: (SecondaryWindow) -> NSWindow?
    private let focusAction: () -> Void
    private var defaultCenterObservers = [NSObjectProtocol]()
    private var workspaceCenterObservers = [NSObjectProtocol]()

    var onEvent: ((WindowWorkspaceEvent) -> Void)? {
        didSet {
            stopObserving()
            if onEvent != nil {
                startObserving()
            }
        }
    }

    init(
        panel: NSPanel,
        secondaryWindow: @escaping (SecondaryWindow) -> NSWindow? = { _ in nil },
        focusComposer: @escaping () -> Void
    ) {
        self.panel = panel
        self.secondaryWindowProvider = secondaryWindow
        self.focusAction = focusComposer
    }

    var isPanelVisible: Bool { panel?.isVisible ?? false }
    var isPanelOnActiveSpace: Bool { panel?.isOnActiveSpace ?? false }
    var isPanelKey: Bool { panel?.isKeyWindow ?? false }
    var panelFrame: CGRect { panel?.frame ?? .zero }
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var displays: [DisplayBounds] {
        NSScreen.screens.enumerated().map { index, screen in
            Self.displayBounds(for: screen, fallbackIndex: index)
        }
    }

    var activeDisplay: DisplayBounds? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let pointer = NSEvent.mouseLocation
        if let index = screens.firstIndex(where: { $0.frame.contains(pointer) }) {
            return Self.displayBounds(for: screens[index], fallbackIndex: index)
        }
        if let index = screens.firstIndex(where: {
            pointer.x >= $0.frame.minX && pointer.x <= $0.frame.maxX &&
            pointer.y >= $0.frame.minY && pointer.y <= $0.frame.maxY
        }) {
            return Self.displayBounds(for: screens[index], fallbackIndex: index)
        }
        if let main = NSScreen.main, let index = screens.firstIndex(of: main) {
            return Self.displayBounds(for: main, fallbackIndex: index)
        }
        return Self.displayBounds(for: screens[0], fallbackIndex: 0)
    }

    func orderOutPanel() {
        panel?.orderOut(nil)
    }

    func setPanelFrame(_ frame: CGRect) {
        panel?.setFrame(frame, display: true)
    }

    func orderFrontAndMakePanelKey() {
        panel?.makeKeyAndOrderFront(nil)
    }

    func isSecondaryWindowVisible(_ window: SecondaryWindow) -> Bool {
        secondaryWindowProvider(window)?.isVisible ?? false
    }

    func isSecondaryWindowOnActiveSpace(_ window: SecondaryWindow) -> Bool {
        secondaryWindowProvider(window)?.isOnActiveSpace ?? false
    }

    func orderOutSecondaryWindow(_ window: SecondaryWindow) {
        secondaryWindowProvider(window)?.orderOut(nil)
    }

    func orderFrontAndMakeSecondaryWindowKey(_ window: SecondaryWindow) {
        secondaryWindowProvider(window)?.makeKeyAndOrderFront(nil)
    }

    func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func focusComposer() {
        panel?.contentView?.layoutSubtreeIfNeeded()
        focusAction()
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible, panel.isKeyWindow else { return }
            self.focusAction()
        }
    }

    func stopObserving() {
        for observer in defaultCenterObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        defaultCenterObservers.removeAll()
        for observer in workspaceCenterObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceCenterObservers.removeAll()
    }

    private func startObserving() {
        guard let panel else { return }
        let defaultCenter = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        defaultCenterObservers.append(
            defaultCenter.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onEvent?(.panelDidBecomeKey)
                }
            }
        )
        defaultCenterObservers.append(
            defaultCenter.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.panel?.isKeyWindow != true else { return }
                    self.onEvent?(.otherAppWindowDidBecomeKey)
                }
            }
        )
        defaultCenterObservers.append(
            defaultCenter.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onEvent?(.panelDidResignKey)
                }
            }
        )
        defaultCenterObservers.append(
            defaultCenter.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onEvent?(.appDidResignActive)
                }
            }
        )
        workspaceCenterObservers.append(
            workspaceCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                let activatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    guard let activatedPID, activatedPID != NSRunningApplication.current.processIdentifier else { return }
                    self?.onEvent?(.otherAppDidActivate)
                }
            }
        )
        workspaceCenterObservers.append(
            workspaceCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onEvent?(.activeSpaceDidChange)
                }
            }
        )
    }

    private static func displayBounds(for screen: NSScreen, fallbackIndex: Int) -> DisplayBounds {
        let id: String
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            id = number.stringValue
        } else {
            id = "screen-\(fallbackIndex)"
        }
        return DisplayBounds(id: id, frame: screen.frame, visibleFrame: screen.visibleFrame)
    }
}
