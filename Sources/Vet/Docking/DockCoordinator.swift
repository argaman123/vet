import AppKit
import VetCore

/// Keeps the real Claude Desktop window docked right of the rail and handles tab switching.
@MainActor
final class DockCoordinator {
    private let state: ShellState
    private let main: MainWindowController
    private var claude: ClaudeWindow?
    private var permission: PermissionState = .unknown
    private var launchAttempts = 0
    private var permissionTimer: Timer?
    private var retry: Task<Void, Never>?
    private var claudeMoveDebounce: Task<Void, Never>?

    init(state: ShellState, main: MainWindowController) {
        self.state = state
        self.main = main
    }

    func start() {
        main.onFrameChange = { [weak self] in self?.redock() }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard Self.isClaude(note) else { return }
            MainActor.assumeIsolated { self?.scheduleRedock(after: 0.5) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard Self.isClaude(note) else { return }
            MainActor.assumeIsolated { self?.claudeQuit() }
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard Self.isClaude(note) else { return }
            // Cmd-Tab or a click that brings Claude forward means the Claude tab is showing.
            MainActor.assumeIsolated { self?.state.selected = .claude }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Activating Vet any other way while on the Claude tab should still show Claude.
                guard let self, self.state.selected == .claude, self.claude != nil else { return }
                self.claude?.raise()
            }
        }
        checkPermission(prompt: true)
    }

    func select(_ tab: RailTab) {
        state.selected = tab
        if tab == .claude {
            redock()
            claude?.raise()
        } else {
            NSApp.activate()
            main.window.makeKeyAndOrderFront(nil)
            main.window.orderFrontRegardless()
        }
    }

    func openClaude() {
        launchAttempts = 0
        state.dockMessage = nil
        redock()
    }

    func grantPermission() {
        _ = AccessibilityPermission.isTrusted(prompt: true)
        AccessibilityPermission.openSettings()
    }

    // MARK: Docking

    func redock() {
        guard permission == .granted else { return }
        if let current = claude, !current.isAlive {
            current.stopObserving()
            claude = nil
        }
        if claude == nil, let found = ClaudeWindow.find() {
            claude = found
            found.observeMoves { [weak self] in self?.claudeMoved() }
        }
        let running = ClaudeWindow.runningApp() != nil
        let snapshot = ClaudeSnapshot(isRunning: running, hasWindow: claude != nil,
                                      isMinimized: claude?.isMinimized ?? false,
                                      isFullScreen: claude?.isFullScreen ?? false,
                                      frame: claude?.axFrame)
        let target = DockGeometry.axRect(fromCocoa: DockGeometry.claudeTargetFrame(mainWindowFrame: main.window.frame),
                                         primaryScreenHeight: NSScreen.screens[0].frame.height)

        switch dockAction(claude: snapshot, permission: permission, target: target, launchAttempts: launchAttempts) {
        case .launchClaude:
            launchAttempts += 1
            let config = NSWorkspace.OpenConfiguration()
            config.activates = state.selected == .claude
            NSWorkspace.shared.openApplication(at: ClaudeWindow.appURL, configuration: config) { _, _ in }
            scheduleRedock(after: 1.5)
        case .waitForWindow:
            scheduleRedock(after: 0.5)
        case .unminimize:
            claude?.unminimize()
            scheduleRedock(after: 0.4)
        case .exitFullScreen:
            claude?.exitFullScreen()
            scheduleRedock(after: 1.0)
        case .setFrame(let frame):
            claude?.setAXFrame(frame)
            state.dockMessage = nil
        case .none:
            state.dockMessage = running ? nil : .claudeMissing
        }
    }

    private func scheduleRedock(after seconds: Double) {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.redock()
            if self?.state.selected == .claude { self?.claude?.raise() }
        }
    }

    /// The user dragged or resized Claude's window: snap it back once they stop.
    private func claudeMoved() {
        claudeMoveDebounce?.cancel()
        claudeMoveDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.redock()
        }
    }

    private func claudeQuit() {
        claude?.stopObserving()
        claude = nil
        launchAttempts = maxClaudeLaunchAttempts // don't relaunch on our own after the user quit it
        state.dockMessage = .claudeMissing
    }

    // MARK: Permission

    private func checkPermission(prompt: Bool) {
        let trusted = AccessibilityPermission.isTrusted(prompt: prompt)
        permission = trusted ? .granted : .denied
        if trusted {
            permissionTimer?.invalidate()
            permissionTimer = nil
            if state.dockMessage == .needsPermission { state.dockMessage = nil }
            redock()
            if state.selected == .claude { scheduleRedock(after: 0.2) }
        } else {
            state.dockMessage = .needsPermission
            guard permissionTimer == nil else { return }
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkPermission(prompt: false) }
            }
        }
    }

    nonisolated private static func isClaude(_ note: Notification) -> Bool {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == ClaudeWindow.bundleID
    }
}
