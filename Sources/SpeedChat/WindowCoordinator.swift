import AppKit

enum WindowWorkspaceEvent: Equatable, Sendable {
    case panelDidBecomeKey
    case panelDidResignKey
    case otherAppWindowDidBecomeKey
    case appDidResignActive
    case activeSpaceDidChange
}

@MainActor protocol WindowWorkspace: AnyObject {
    var isPanelVisible: Bool { get }
    var isPanelOnActiveSpace: Bool { get }
    var isPanelKey: Bool { get }
    var isAppActive: Bool { get }
    var now: TimeInterval { get }
    var onEvent: ((WindowWorkspaceEvent) -> Void)? { get set }

    func orderOutPanel()
    func orderFrontAndMakePanelKey()
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
    static let spaceSwitchResignGraceInterval: TimeInterval = 0.5

    private let workspace: any WindowWorkspace
    private let onShow: () -> Void
    private let onHide: () -> Void
    private let onNewChat: () -> Void
    private var panelIsActiveOnItsSpace = false
    private var recentResignAt: TimeInterval?
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
        if workspace.isPanelVisible && workspace.isPanelOnActiveSpace && workspace.isPanelKey && workspace.isAppActive {
            hidePanel()
            return
        }
        showPanel()
    }

    func showPanel() {
        if workspace.isPanelVisible && !workspace.isPanelOnActiveSpace {
            // Detach from the non-active Space without treating relocation as a hide
            // so AppKit enters the active Space cleanly without bouncing Spaces.
            workspace.orderOutPanel()
        }
        shouldRestoreOnSpaceReturn = false
        recentResignAt = nil
        onShow()
        workspace.orderFrontAndMakePanelKey()
        workspace.activateApp()
        workspace.focusComposer()
        panelIsActiveOnItsSpace = workspace.isPanelVisible && workspace.isPanelOnActiveSpace
    }

    func hidePanel() {
        shouldRestoreOnSpaceReturn = false
        panelIsActiveOnItsSpace = false
        recentResignAt = nil
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

    private func handle(_ event: WindowWorkspaceEvent) {
        switch event {
        case .panelDidBecomeKey:
            guard workspace.isPanelVisible, workspace.isPanelOnActiveSpace else { return }
            panelIsActiveOnItsSpace = true
            recentResignAt = nil
            shouldRestoreOnSpaceReturn = false

        case .otherAppWindowDidBecomeKey:
            if workspace.isPanelOnActiveSpace {
                panelIsActiveOnItsSpace = false
                recentResignAt = nil
                shouldRestoreOnSpaceReturn = false
            }

        case .panelDidResignKey, .appDidResignActive:
            guard workspace.isPanelVisible else {
                clearRestorationState()
                return
            }
            if !workspace.isPanelOnActiveSpace {
                if panelIsActiveOnItsSpace || isWithinResignGraceWindow() {
                    shouldRestoreOnSpaceReturn = true
                }
                panelIsActiveOnItsSpace = false
                recentResignAt = nil
                return
            }
            if panelIsActiveOnItsSpace {
                panelIsActiveOnItsSpace = false
                recentResignAt = workspace.now
            }

        case .activeSpaceDidChange:
            guard workspace.isPanelVisible else {
                clearRestorationState()
                return
            }
            if !workspace.isPanelOnActiveSpace {
                if panelIsActiveOnItsSpace || isWithinResignGraceWindow() {
                    shouldRestoreOnSpaceReturn = true
                }
                panelIsActiveOnItsSpace = false
                recentResignAt = nil
                return
            }
            if shouldRestoreOnSpaceReturn {
                shouldRestoreOnSpaceReturn = false
                recentResignAt = nil
                workspace.orderFrontAndMakePanelKey()
                workspace.activateApp()
                workspace.focusComposer()
                panelIsActiveOnItsSpace = workspace.isPanelVisible && workspace.isPanelOnActiveSpace
            }
        }
    }

    private func isWithinResignGraceWindow() -> Bool {
        guard let recentResignAt else { return false }
        let elapsed = workspace.now - recentResignAt
        return elapsed >= 0 && elapsed <= Self.spaceSwitchResignGraceInterval
    }

    private func clearRestorationState() {
        shouldRestoreOnSpaceReturn = false
        panelIsActiveOnItsSpace = false
        recentResignAt = nil
    }
}

@MainActor final class AppKitWindowWorkspace: WindowWorkspace {
    private weak var panel: NSPanel?
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

    init(panel: NSPanel, focusComposer: @escaping () -> Void) {
        self.panel = panel
        self.focusAction = focusComposer
    }

    var isPanelVisible: Bool { panel?.isVisible ?? false }
    var isPanelOnActiveSpace: Bool { panel?.isOnActiveSpace ?? false }
    var isPanelKey: Bool { panel?.isKeyWindow ?? false }
    var isAppActive: Bool { NSApp.isActive }
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func orderOutPanel() {
        panel?.orderOut(nil)
    }

    func orderFrontAndMakePanelKey() {
        panel?.makeKeyAndOrderFront(nil)
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
            workspaceCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onEvent?(.activeSpaceDidChange)
                }
            }
        )
    }
}
