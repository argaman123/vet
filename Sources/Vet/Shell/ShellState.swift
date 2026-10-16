import Observation
import VetCore

/// UI state shared by the rail and the content area.
@MainActor @Observable
final class ShellState {
    var selected: RailTab = .review
    var badges: [RailTab: Int] = [:]
    /// Folder of the Claude session that's showing, reported by the bridge mod.
    var claudeCwd: String?
}
