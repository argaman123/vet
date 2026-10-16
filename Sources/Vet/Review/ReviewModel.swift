import AppKit
import Observation
import VetCore

/// Debug timing: `defaults write dev.vet.Vet logTiming -bool YES` appends how long each diff took to show
/// to `$TMPDIR/vet-timing.log`.
@MainActor enum Timing {
    static var selectionStarted: Date?
    static let enabled = UserDefaults.standard.bool(forKey: "logTiming")
    static func note(_ text: String) {
        guard enabled else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vet-timing.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data((text + "\n").utf8)); try? h.close() }
    }

    static func diffShown(_ path: String) {
        guard enabled, let start = selectionStarted else { return }
        let line = String(format: "diff %@ %.0f ms\n", path, Date().timeIntervalSince(start) * 1000)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vet-timing.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
        selectionStarted = nil
    }
}

/// State of the Review tab for one project.
@MainActor @Observable
final class ReviewModel {
    private(set) var root: URL?
    private(set) var repo: GitRepo?
    private(set) var changes: [FileChange] = []
    private(set) var tree: [FileTreeNode] = []
    /// Bumped on every refresh so the outline view knows to reload.
    private(set) var version = 0
    var selectedPath: String? {
        didSet {
            guard oldValue != selectedPath else { return }
            expandedFolds = []
            Timing.selectionStarted = Date()
            Task { await loadDiff() }
        }
    }
    /// The open file's diff.
    private(set) var diff: DiffDocument?
    private(set) var diffVersion = 0
    /// Fold unchanged regions (remembered across files and launches).
    var folding = UserDefaults.standard.object(forKey: "foldUnchanged") as? Bool ?? true {
        didSet { UserDefaults.standard.set(folding, forKey: "foldUnchanged"); expandedFolds = []; diffVersion += 1 }
    }
    /// Folds the user opened in the current file (by the region's first HEAD line).
    var expandedFolds: Set<Int> = []
    /// The right pane has unsaved edits.
    var diffDirty = false
    /// Bumped to make the diff view throw away unsaved edits.
    private(set) var revertSerial = 0
    /// Bumped to ask the diff view to jump to the previous/next section.
    private(set) var jump: (serial: Int, forward: Bool) = (0, true)
    /// Folders the user has expanded (repo-relative paths).
    var expanded: Set<String> = []
    /// The last problem, shown under the sidebar header until it's dismissed or times out.
    private(set) var error: String?
    private var errorSerial = 0
    /// Guards against diff loads landing out of order.
    private var loadSerial = 0
    private(set) var isGitRepo = true
    private(set) var marks: MarkStore?
    private var autoStaging = false
    /// Paths staged/unstaged optimistically while git runs.
    private var pending: [String: StageState] = [:]

    var reviewedCount: Int { changes.filter { stage(of: $0) == .staged }.count }

    func open(_ folder: URL?) {
        // Coming back to the Review tab shouldn't reset your place in the same project.
        if let folder, folder.standardizedFileURL == root?.standardizedFileURL {
            Task { await refresh() }
            return
        }
        root = folder
        selectedPath = nil
        changes = []
        tree = []
        expanded = []
        guard let folder else { repo = nil; return }
        isGitRepo = GitRepo.root(containing: folder) != nil
        repo = isGitRepo ? GitRepo(root: folder) : nil
        marks = isGitRepo ? MarkStore(root: folder) : nil
        Task { await refresh() }
    }

    func refresh() async {
        guard let repo else { return }
        do {
            let fresh = try await repo.status()
            let known = Set(changes.map(\.path))
            changes = fresh
            pending = [:]
            tree = FileTreeNode.build(fresh)
            // New files open their folders, even if they appeared while Vet was closed;
            // unimportant ones don't.
            for c in fresh where !known.contains(c.path) && !(marks?.isMarked(c.path) ?? false) { expandAncestors(of: c.path) }
            if let sel = selectedPath, !fresh.contains(where: { $0.path == sel }) { selectedPath = nil }
            version += 1
            await loadDiff()
            await autoStageUnimportant()
        } catch {
            show("Couldn't read git status: \(error)")
        }
    }

    /// Shows a problem for 10 seconds (or until the next one).
    func show(_ message: String) {
        error = message
        errorSerial += 1
        let serial = errorSerial
        Task {
            try? await Task.sleep(for: .seconds(10))
            if self.errorSerial == serial { self.error = nil }
        }
    }

    func dismissError() { error = nil }

    func stage(of change: FileChange) -> StageState { pending[change.path] ?? change.stage }

    func stage(of node: FileTreeNode) -> StageState {
        let states = Set(node.fileChanges.map { stage(of: $0) })
        if states == [.staged] { return .staged }
        if states == [.unstaged] || states.isEmpty { return .unstaged }
        return .partial
    }

    /// Stages (or unstages) every file at or under `node`. The checkbox flips at once; git runs in order.
    func setStaged(_ node: FileTreeNode, _ staged: Bool) {
        error = nil
        let targets = node.fileChanges.filter {
            $0.kind != .conflicted && (staged ? stage(of: $0) != .staged : stage(of: $0) != .unstaged)
        }
        guard let repo, let root, !targets.isEmpty else { return }
        // Unchecking an unimportant file holds it unstaged until it changes again.
        for c in targets where marks?.isMarked(c.path) ?? false {
            if staged { marks?.releaseHold(c.path) } else { marks?.hold(c.path, hash: MarkStore.contentHash(root: root, path: c.path)) }
        }
        for c in targets { pending[c.path] = staged ? .staged : .unstaged }
        version += 1
        Task {
            do {
                // One git command for the whole folder: it either applies or it doesn't.
                if staged { try await repo.stageFiles(targets) } else { try await repo.unstageFiles(targets) }
            } catch {
                show("Couldn't \(staged ? "stage" : "unstage"): \(error)")
            }
            await refresh() // shows git's real state, success or not
        }
    }

    func loadDiff() async {
        loadSerial += 1
        let serial = loadSerial
        guard let repo, let path = selectedPath, let change = changes.first(where: { $0.path == path }) else {
            if diff != nil { diff = nil; diffVersion += 1 }
            return
        }
        // Same file and same bytes as what's on screen: nothing to redo.
        let previous = diff?.change == change ? diff?.staging?.snapshotID : nil
        let result = await repo.loadDiff(change, previousSnapshot: previous)
        guard serial == loadSerial, selectedPath == path else { return } // a newer load or selection won
        guard case .document(let doc) = result else { return }
        diff = doc
        diffVersion += 1
    }

    /// Writes edits made in the diff's right pane to the working file (atomically).
    func saveDiffEdits(_ text: String) {
        guard let root, let change = diff?.change else { return }
        do {
            try Data(text.utf8).write(to: root.appendingPathComponent(change.path), options: .atomic)
            diffDirty = false
            revertSerial += 1 // drop the edit buffer; the refresh below shows the saved file
            Task { await refresh() }
        } catch {
            show("Couldn't save: \(error.localizedDescription)")
        }
    }

    func revertDiffEdits() {
        diffDirty = false
        revertSerial += 1
        diffVersion += 1
    }

    func expandFold(_ id: Int) {
        expandedFolds.insert(id)
        diffVersion += 1
    }

    func jumpToChange(forward: Bool) { jump = (jump.serial + 1, forward) }

    /// Stages or unstages one section of the open file. `snapshot` is the snapshot the clicked
    /// checkbox was drawn from; if HEAD, the index or the file changed since, the click is refused.
    func setHunk(_ id: Int, staged: Bool, snapshot: String) {
        guard let repo, let root, let change = diff?.change else { return }
        error = nil
        // Unchecking part of an unimportant file holds it, just like unchecking the whole file.
        if isMarked(change.path) {
            if staged { marks?.releaseHold(change.path) } else { marks?.hold(change.path, hash: MarkStore.contentHash(root: root, path: change.path)) }
        }
        Task {
            do {
                let outcome = try await repo.setSection(change, hunkID: id, staged: staged, expectedSnapshot: snapshot)
                if outcome == .stale { show("The file changed, so the diff was refreshed. Check it and click again.") }
            } catch {
                show("Couldn't \(staged ? "stage" : "unstage") the section: \(error)")
            }
            await refresh()
        }
    }

    // MARK: Unimportant

    func isMarked(_ path: String) -> Bool { marks?.isMarked(path) ?? false }
    func isDirectlyMarked(_ path: String) -> Bool { marks?.isDirectlyMarked(path) ?? false }

    func toggleMark(_ node: FileTreeNode) {
        guard let marks else { return }
        if marks.isDirectlyMarked(node.path) {
            marks.unmark(node.path)
        } else {
            marks.mark(node.path)
            if node.isFolder { expanded = expanded.filter { $0 != node.path && !$0.hasPrefix(node.path + "/") } } // marked folders fold away
        }
        version += 1
        Task { await autoStageUnimportant() }
    }

    /// Stages saved changes to unimportant files, except ones you unchecked that haven't changed since.
    private func autoStageUnimportant() async {
        guard !autoStaging, let repo, let root, let marks else { return }
        let due = changes.filter { c in
            guard c.kind != .conflicted, marks.isMarked(c.path), c.stage != .staged else { return false }
            if let held = marks.heldHash(c.path) {
                if held == MarkStore.contentHash(root: root, path: c.path) { return false }
                marks.releaseHold(c.path) // it changed since you unchecked it
            }
            return true
        }
        guard !due.isEmpty else { return }
        autoStaging = true
        defer { autoStaging = false }
        // Check the holds once more right before staging: you may have unchecked one meanwhile.
        let stillDue = due.filter { c in marks.heldHash(c.path).map { $0 != MarkStore.contentHash(root: root, path: c.path) } ?? true }
        do {
            try await repo.stageFiles(stillDue)
        } catch {
            show("Couldn't auto-stage an unimportant file: \(error)")
        }
        await refresh()
    }

    func nextUnreviewed() {
        let files = FileTreeNode.filesInOrder(tree)
        guard !files.isEmpty else { return }
        let start = files.firstIndex { $0.path == selectedPath }.map { $0 + 1 } ?? 0
        let ordered = files[start...] + files[..<start]
        if let next = ordered.first(where: { stage(of: $0) != .staged }) {
            expandAncestors(of: next.path)
            selectedPath = next.path
            version += 1
        }
    }

    func expandAll() {
        func walk(_ nodes: [FileTreeNode]) { for n in nodes where n.isFolder { expanded.insert(n.path); walk(n.children) } }
        walk(tree)
        version += 1
    }

    func collapseAll() {
        expanded = []
        version += 1
    }

    func expandAncestors(of path: String) {
        var p = (path as NSString).deletingLastPathComponent
        while !p.isEmpty {
            expanded.insert(p)
            p = (p as NSString).deletingLastPathComponent
        }
    }

    func url(for path: String) -> URL? { root?.appendingPathComponent(path) }
}
