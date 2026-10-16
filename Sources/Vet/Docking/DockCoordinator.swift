import AppKit
import ApplicationServices
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
    /// The tab to show when Vet is brought forward some other way than the rail (Stage Manager strip, Cmd-Tab, Dock).
    private var lastNonClaudeTab: RailTab = .review
    /// Ignore Claude's window movement while Stage Manager animates a stage switch.
    private var ignoreClaudeMovesUntil = Date.distantPast
    private var claudeWasFullScreen = false
    /// Vet's own activation at launch shouldn't count as "came forward some other way".
    private var ignoreVetActivationUntil = Date.distantPast

    init(state: ShellState, main: MainWindowController) {
        self.state = state
        self.main = main
    }

    func start() {
        ignoreVetActivationUntil = Date().addingTimeInterval(2)
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
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                let isVet = bundleID == Bundle.main.bundleIdentifier
                let isClaude = bundleID == ClaudeWindow.bundleID
                self.main.setRailFloating(isVet || isClaude)
                if isVet || isClaude { self.ignoreClaudeMovesUntil = Date().addingTimeInterval(0.8) }
                if isClaude {
                    // Cmd-Tab, Stage Manager or a click that brings Claude forward means the Claude tab is showing.
                    self.state.selected = .claude
                    self.scheduleRedock(after: 0.35) // Stage Manager may re-place the window while switching stages
                } else if isVet, self.state.selected == .claude, Date() >= self.ignoreVetActivationUntil {
                    // Vet came forward some other way than the rail: show Vet, don't bounce back to Claude.
                    self.state.selected = self.lastNonClaudeTab
                }
            }
        }
        checkPermission(prompt: true)
    }

    func select(_ tab: RailTab) {
        state.selected = tab
        if tab != .claude { lastNonClaudeTab = tab }
        if tab == .claude {
            redock()
            claude?.raise()
        } else {
            // A click on the non-activating rail doesn't count as activating Vet, so macOS's
            // cooperative activation refuses NSApp.activate(). Setting AXFrontmost on ourselves
            // through Accessibility (which Vet already has) does bring Vet to the front.
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(getpid()), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
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
            if found.isFullScreen {
                claudeWasFullScreen = true
                claudeFullScreenChanged(true, atLaunch: true)
            }
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

    /// Claude's window moved or resized. If the user did it, Vet follows Claude instead of snapping it back.
    private func claudeMoved() {
        guard let claude else { return }
        let full = claude.isFullScreen
        if full != claudeWasFullScreen {
            claudeWasFullScreen = full
            claudeFullScreenChanged(full)
            return
        }
        guard !full, Date() >= ignoreClaudeMovesUntil else { return }
        // Only the user's own drags: Claude must be in front, and not a Stage Manager thumbnail.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ClaudeWindow.bundleID,
              let ax = claude.axFrame, ax.width > 300, ax.height > 200 else { return }
        let claudeFrame = DockGeometry.cocoaRect(fromAX: ax, primaryScreenHeight: NSScreen.screens[0].frame.height)
        let target = DockGeometry.claudeTargetFrame(mainWindowFrame: main.window.frame)
        guard !DockGeometry.isDocked(claudeFrame: claudeFrame, target: target) else { return }
        main.window.setFrame(DockGeometry.mainWindowFrame(forClaudeFrame: claudeFrame), display: true)
    }

    // MARK: Full screen

    /// Claude's own green button puts it in macOS full screen (a separate Space). Undo that and
    /// toggle Vet's "fill the screen" instead, so both stay together on the desktop.
    /// `atLaunch`: Claude was already full screen when Vet started, so just fill.
    private func claudeFullScreenChanged(_ full: Bool, atLaunch: Bool = false) {
        guard full, claude != nil else { return } // leaving full screen is us undoing it
        ignoreClaudeMovesUntil = Date().addingTimeInterval(5)
        Task { [weak self] in
            // AX ignores the change while the enter animation runs, so keep asking until it takes.
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(400))
                guard let claude = self?.claude else { return }
                if !claude.isFullScreen { break }
                claude.setFullScreen(false)
            }
            try? await Task.sleep(for: .milliseconds(900)) // let the exit animation finish
            guard let self else { return }
            self.claudeWasFullScreen = false
            if atLaunch { self.main.fill() } else { self.main.toggleFill() }
            self.ignoreClaudeMovesUntil = Date().addingTimeInterval(0.5)
            self.redock()
            if self.state.selected == .claude { self.claude?.raise() }
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
