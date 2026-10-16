import CoreGraphics

public enum PermissionState: Sendable, Equatable {
    case unknown, granted, denied
}

/// What Vet currently knows about Claude Desktop and its main window.
public struct ClaudeSnapshot: Sendable, Equatable {
    public var isRunning: Bool
    public var hasWindow: Bool
    public var isMinimized: Bool
    public var isFullScreen: Bool
    /// Window frame in Accessibility (top-left origin) coordinates.
    public var frame: CGRect?

    public init(isRunning: Bool, hasWindow: Bool, isMinimized: Bool, isFullScreen: Bool, frame: CGRect?) {
        self.isRunning = isRunning
        self.hasWindow = hasWindow
        self.isMinimized = isMinimized
        self.isFullScreen = isFullScreen
        self.frame = frame
    }
}

public enum DockAction: Equatable, Sendable {
    case launchClaude
    case waitForWindow
    case unminimize
    case setFrame(CGRect)
    case none
}

/// Gives up auto-launching Claude after this many tries and shows "Open Claude" instead.
public let maxClaudeLaunchAttempts = 3

/// Decides the next docking step. `target` is in Accessibility coordinates.
public func dockAction(claude: ClaudeSnapshot, permission: PermissionState, target: CGRect, launchAttempts: Int) -> DockAction {
    guard permission == .granted else { return .none }
    guard claude.isRunning else { return launchAttempts < maxClaudeLaunchAttempts ? .launchClaude : .none }
    guard claude.hasWindow else { return .waitForWindow }
    if claude.isMinimized { return .unminimize }
    if claude.isFullScreen { return .none } // the user chose full screen; Vet mirrors it instead of undoing it
    if let frame = claude.frame, DockGeometry.isDocked(claudeFrame: frame, target: target) { return .none }
    return .setFrame(target)
}
