import Foundation
import Observation

/// What the window shows: the sidebar tool, the main area's content and its history.
@MainActor @Observable
final class UIState {
    /// What the sidebar shows: the changes (always, by default) or the project's files (⌘2).
    enum Tool: String, CaseIterable, Identifiable {
        case changes, project
        var id: String { rawValue }
        var title: String { self == .changes ? "Changes" : "Project" }
    }

    /// The main area's content. Navigation history is a list of these.
    enum Location: Hashable {
        case diff(path: String)
        case file(url: URL, line: Int)
        case browser
    }

    var tool: Tool = .changes
    private(set) var location: Location?
    private(set) var back: [Location] = []
    private(set) var forward: [Location] = []
    var search = ""
    var focusSearch = false
    var showCommit = false
    var editingRules = false
    var editingRunConfigs = false

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Shows `new`, remembering where you were (a new place clears Forward, as in Safari).
    func show(_ new: Location) {
        guard new != location else { return }
        if let location { back.append(location); if back.count > 100 { back.removeFirst() } }
        forward = []
        location = new
    }

    /// Replaces the current place without a history entry (the same file at another line).
    func replace(_ new: Location) { location = new }

    func goBack() -> Location? {
        guard let target = back.popLast() else { return nil }
        if let location { forward.append(location) }
        location = target
        return target
    }

    func goForward() -> Location? {
        guard let target = forward.popLast() else { return nil }
        if let location { back.append(location) }
        location = target
        return target
    }

    func reset() { location = nil; back = []; forward = [] }

    private func sameFile(_ a: Location, _ b: Location) -> Bool {
        if case .file(let u, _) = a, case .file(let v, _) = b { return u == v }
        return false
    }
}
