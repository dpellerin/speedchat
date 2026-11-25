import AppKit

@MainActor protocol WindowWorkspace: AnyObject {
    var isPanelVisible: Bool { get }
    var isPanelOnActiveSpace: Bool { get }
    var isPanelKey: Bool { get }
    var isAppActive: Bool { get }

    func orderOutPanel()
    func orderFrontAndMakePanelKey()
    func activateApp()
    func focusComposer()
}

@MainActor final class WindowCoordinator {
    static let panelCollectionBehavior: NSWindow.CollectionBehavior = [
        .moveToActiveSpace,
        .managed,
        .fullScreenAuxiliary
    ]

    private let workspace: any WindowWorkspace
    private let onShow: () -> Void
    private let onHide: () -> Void
    private let onNewChat: () -> Void

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
        onShow()
        workspace.orderFrontAndMakePanelKey()
        workspace.activateApp()
        workspace.focusComposer()
    }

    func hidePanel() {
        workspace.orderOutPanel()
        onHide()
    }

    func newChatFromMenu() {
        showPanel()
        onNewChat()
    }
}

@MainActor final class AppKitWindowWorkspace: WindowWorkspace {
    private weak var panel: NSPanel?
    private let focusAction: () -> Void

    init(panel: NSPanel, focusComposer: @escaping () -> Void) {
        self.panel = panel
        self.focusAction = focusComposer
    }

    var isPanelVisible: Bool { panel?.isVisible ?? false }
    var isPanelOnActiveSpace: Bool { panel?.isOnActiveSpace ?? false }
    var isPanelKey: Bool { panel?.isKeyWindow ?? false }
    var isAppActive: Bool { NSApp.isActive }

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
}
