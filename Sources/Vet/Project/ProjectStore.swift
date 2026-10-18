import AppKit
import Observation

/// The project folder Vet is reviewing, plus recently opened ones.
@MainActor @Observable
final class ProjectStore {
    private(set) var current: URL?
    private(set) var recent: [URL] = []
    private let defaults = UserDefaults.standard
    /// Asked before switching away from the current project (unsaved edits). False means stay.
    @ObservationIgnored var mayLeave: () -> Bool = { true }

    init() {
        recent = (defaults.stringArray(forKey: "recentProjects") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        // A test run (VET_PROJECT) never opens your last real project, even for a moment.
        if !SnapshotHook.isTesting, let last = recent.first, FileManager.default.fileExists(atPath: last.path) { current = last }
    }

    func open(_ url: URL) {
        let folder = GitRepo.root(containing: url) ?? url
        if folder.standardizedFileURL != current?.standardizedFileURL { guard mayLeave() else { return } }
        current = folder
        guard !SnapshotHook.isTesting else { return } // tests leave your recent projects alone
        recent.removeAll { $0.standardizedFileURL == folder.standardizedFileURL }
        recent.insert(folder, at: 0)
        recent = Array(recent.prefix(8))
        defaults.set(recent.map(\.path), forKey: "recentProjects")
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a project folder to review"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
}
