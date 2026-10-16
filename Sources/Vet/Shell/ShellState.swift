import Observation
import VetCore

enum DockMessage: Equatable {
    case needsPermission
    case claudeMissing
}

/// UI state shared by the rail, the content area and the coordinators.
@MainActor @Observable
final class ShellState {
    var selected: RailTab = .claude
    var badges: [RailTab: Int] = [:]
    var dockMessage: DockMessage?
    /// Folder of the Claude session that's showing, reported by the bridge mod.
    var claudeCwd: String?
}
