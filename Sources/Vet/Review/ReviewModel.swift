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
    private(set) var notes: NoteStore?
    /// The note being written or edited (shown as an editable card).
    private(set) var editingNoteID: String?
    private(set) var notesVersion = 0
    /// Where drafts go (set by the workspace).
    var link: ClaudeLink?
    private var autoStaging = false
    /// Paths staged/unstaged optimistically while git runs.
    private var pending: [String: StageState] = [:]

    var reviewedCount: Int { changes.filter { stage(of: $0) == .staged }.count }

    // MARK: Branch, layout and commit (wired to GitRepo's branch/commit operations)

    /// The checked-out branch (nil when detached or not a repo).
    private(set) var branch: String?
    /// Branches for the title menu: local ones first (current at the top), then remote ones no
    /// local branch tracks.
    private(set) var branches: [GitBranch] = []
    /// A branch switch or commit is running.
    private(set) var gitBusy = false
    /// Unified (one column) instead of side by side.
    var unified = UserDefaults.standard.bool(forKey: "unifiedDiff") {
        didSet { UserDefaults.standard.set(unified, forKey: "unifiedDiff"); diffVersion += 1 }
    }

    func refreshBranches() async {
        guard let repo else { branch = nil; branches = []; return }
        branch = (try? await repo.currentBranch()) ?? nil
        branches = (try? await repo.branches()) ?? []
    }

    /// Switches branches (never forced). Unsaved diff edits are asked about first; files git
    /// would overwrite are listed instead of being touched.
    func checkout(_ name: String) {
        guard let repo, !gitBusy, name != branch, confirmLeaveDiff() else { return }
        gitBusy = true
        Task {
            defer { gitBusy = false }
            do {
                switch try await repo.checkout(name) {
                case .done:
                    selectedPath = nil
                case .wouldOverwrite(let paths):
                    Self.alert("Can't switch to \(name)",
                               "Switching would overwrite your changes to:\n\(paths.prefix(12).joined(separator: "\n"))\(paths.count > 12 ? "\n…" : "")\n\nCommit or stash them first.")
                case .failed(let message):
                    Self.alert("Can't switch to \(name)", message)
                }
            } catch {
                show("Couldn't switch branches: \(error)")
            }
            await refresh()
        }
    }

    func lastCommitMessage() async -> String? {
        guard let repo else { return nil }
        return (try? await repo.lastCommitMessage()) ?? nil
    }

    /// Commits what's staged (reviewed); optionally pushes. Returns whether the commit worked.
    func commit(message: String, amend: Bool, push: Bool) async -> Bool {
        guard let repo, !gitBusy else { return false }
        gitBusy = true
        defer { gitBusy = false }
        do {
            _ = try await repo.commit(message: message, amend: amend)
        } catch let e as GitActionError {
            Self.alert(e.message, e.output)
            await refresh()
            return false
        } catch {
            Self.alert("The commit failed.", "\(error)")
            return false
        }
        await refresh()
        guard push else { link?.flash("Committed"); return true }
        do {
            let summary = try await repo.push()
            link?.flash(summary.isEmpty ? "Committed and pushed" : "Pushed: \(summary)")
        } catch let e as GitActionError {
            Self.alert("Committed, but the push failed. \(e.message)", e.output)
        } catch {
            Self.alert("Committed, but the push failed.", "\(error)")
        }
        await refreshBranches()
        return true
    }

    /// A git refusal with its own output (a hook's output included) as the details.
    private static func alert(_ title: String, _ details: String) {
        let a = NSAlert()
        a.messageText = title
        let text = details.trimmingCharacters(in: .whitespacesAndNewlines)
        a.informativeText = text.count > 3000 ? String(text.prefix(3000)) + "\n…" : text
        a.runModal()
    }

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
        notes = NoteStore(root: folder)
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
            // A file that left the list (say Claude committed it) closes, unless you're editing it.
            if let sel = selectedPath, !fresh.contains(where: { $0.path == sel }), !diffDirty { selectedPath = nil }
            version += 1
            await refreshBranches()
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
            if diff != nil && !diffDirty { diff = nil; diffVersion += 1 }
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

    /// The edited right pane's text as file contents (set by the diff view), for save prompts.
    var diffEditedText: (() -> String?)?

    /// Saves the diff's unsaved edits (set by the diff view).
    var diffSave: (() -> Void)?

    /// The diff view lives as long as the model (as the Browser's web view does): switching tabs
    /// must not throw away the text you're editing in it, or its scroll position.
    @ObservationIgnored lazy var diffView = RibbonDiffNSView()

    /// The bytes the diff's edit buffer was built from (to detect changes on disk meanwhile).
    var diffEditBase: (() -> Data?)?

    /// Before leaving the diff's file: asks to save unsaved edits. False means stay.
    func confirmLeaveDiff() -> Bool {
        guard diffDirty, let name = diff?.change.path else { return true }
        switch Alerts.unsaved((name as NSString).lastPathComponent) {
        case .save: return diffEditedText?().map { saveDiffEdits($0, path: name) } ?? false
        case .discard: revertDiffEdits(); return true
        case .cancel: return false
        }
    }

    /// Selects a file in the tree (asking about unsaved edits first). False means it stayed.
    @discardableResult
    func select(_ path: String?) -> Bool {
        guard path != selectedPath else { return true }
        guard confirmLeaveDiff() else { version += 1; return false } // puts the tree selection back
        selectedPath = path
        return true
    }

    /// Writes edits made in the diff's right pane to `path` (atomically), asking first if the
    /// file changed on disk since editing began. Returns whether it was saved.
    @discardableResult
    func saveDiffEdits(_ text: String, path: String) -> Bool {
        guard let root, !path.isEmpty else { return false }
        let url = root.appendingPathComponent(path)
        if let base = diffEditBase?(), (try? Data(contentsOf: url)) != base, // changed, or moved away
           !Alerts.changedOnDisk((path as NSString).lastPathComponent) {
            return false
        }
        do {
            let bytes = Data(text.utf8)
            try bytes.write(to: url, options: .atomic)
            // The pane already shows what was saved: keep it (you may go on typing before the
            // refresh lands) and compare the next save against these bytes.
            diffView.markSaved(bytes)
            Task { await refresh() }
            return true
        } catch {
            show("Couldn't save: \(error.localizedDescription)")
            return false
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

    // MARK: Review notes

    /// Notes on the open file, each re-found by its line's text if the file moved under it.
    func notesForOpenFile() -> [ReviewNote] {
        guard let notes, let doc = diff, let staging = doc.staging else { return [] }
        return notes.notes.filter { $0.path == doc.change.path }.map { n in
            var n = n
            let lines = n.left ? staging.head : staging.work
            if n.line >= lines.count || String(lines.lines[n.line].text) != n.lineText {
                for delta in 1...max(1, min(2_000, lines.count)) {
                    if n.line + delta < lines.count, String(lines.lines[n.line + delta].text) == n.lineText { n.line += delta; break }
                    if n.line - delta >= 0, n.line - delta < lines.count, String(lines.lines[n.line - delta].text) == n.lineText { n.line -= delta; break }
                }
                n.line = min(n.line, max(0, lines.count - 1))
            }
            return n
        }
    }

    var unsentNotes: [ReviewNote] {
        _ = notesVersion // so views showing the count update when notes change
        return (notes?.notes ?? []).filter { !$0.sent && !$0.text.isEmpty }
    }

    func addNote(left: Bool, line: Int, lineText: String) {
        guard let notes, let path = diff?.change.path else { return }
        if let id = editingNoteID, notes.notes.first(where: { $0.id == id })?.text.isEmpty == true { notes.delete(id) }
        let note = ReviewNote(path: path, left: left, line: line, lineText: lineText, text: "")
        notes.upsert(note)
        editingNoteID = note.id
        noteChanged()
    }

    func saveNote(_ id: String, text: String) {
        guard let notes, var note = notes.notes.first(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { notes.delete(id) } else { note.text = trimmed; note.sent = false; notes.upsert(note) }
        editingNoteID = nil
        noteChanged()
    }

    func cancelNote(_ id: String) {
        if let note = notes?.notes.first(where: { $0.id == id }), note.text.isEmpty { notes?.delete(id) }
        editingNoteID = nil
        noteChanged()
    }

    func editNote(_ id: String) {
        editingNoteID = id
        noteChanged()
    }

    func deleteNote(_ id: String) {
        notes?.delete(id)
        if editingNoteID == id { editingNoteID = nil }
        noteChanged()
    }

    private func noteChanged() {
        notesVersion += 1
        diffVersion += 1
    }

    /// All unsent notes, as one draft for Claude: file, line, the line itself, and what you wrote.
    func sendNotes() {
        guard let notes, let link else { return }
        let pending = unsentNotes.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
        guard !pending.isEmpty else { return }
        var text = "Review notes on the current changes:\n"
        for (i, n) in pending.enumerated() {
            text += "\n\(i + 1). \(n.path):\(n.line + 1)\(n.left ? " (old version)" : "")\n"
            text += "   > \(n.lineText.trimmingCharacters(in: .whitespaces))\n"
            text += n.text.split(separator: "\n", omittingEmptySubsequences: false).map { "   " + $0 }.joined(separator: "\n") + "\n"
        }
        link.sendDraft(text)
        for var n in pending { n.sent = true; notes.upsert(n) }
        noteChanged()
    }

    /// Asks Claude about some lines: the location and the code go in as a draft for you to finish.
    func askClaude(path: String, lines: ClosedRange<Int>, code: String, old: Bool) {
        let where_ = lines.count == 1 ? "line \(lines.lowerBound + 1)" : "lines \(lines.lowerBound + 1)–\(lines.upperBound + 1)"
        let lang = (path as NSString).pathExtension
        link?.sendDraft("About \(path) \(where_)\(old ? " (the old version)" : ""):\n```\(lang)\n\(code)\n```\n")
    }

    func askClaude(aboutFile path: String) {
        link?.sendDraft("About \(path): ")
    }

    // MARK: Code navigation (wired to the language servers by the workspace)

    var navigator: ((CodeTextView.Navigation, URL, String, Int, Int) -> Void)?
    var hoverer: ((URL, String, Int, Int) -> Void)?

    /// Hover info for a working-file line of the open diff.
    func hover(line: Int, character: Int) {
        guard let root, let doc = diff, let staging = doc.staging else { return }
        hoverer?(root.appendingPathComponent(doc.change.path), staging.work.joinedString(), line, character)
    }

    /// ⌘-click or a navigation menu item in the diff. Only the working file (right side) is a real
    /// file on disk; on the HEAD side the same line of the working file is used if it's unchanged.
    func navigate(_ kind: CodeTextView.Navigation, left: Bool, line: Int, character: Int) {
        guard let root, let doc = diff, let staging = doc.staging else { return }
        let url = root.appendingPathComponent(doc.change.path)
        let text = staging.work.joinedString()
        guard !left else {
            show("Go to definition works on the right (current) side.")
            return
        }
        navigator?(kind, url, text, line, character)
    }

    // MARK: Stage selected lines

    func stageLines(_ lines: Range<Int>, snapshot: String) {
        guard let repo, let change = diff?.change else { return }
        error = nil
        Task {
            do {
                let outcome = try await repo.stageLines(change, lines: lines, expectedSnapshot: snapshot)
                if outcome == .stale { show("The file changed, so the diff was refreshed. Check it and try again.") }
            } catch {
                show("Couldn't stage the lines: \(error)")
            }
            await refresh()
        }
    }

    // MARK: Unimportant

    func isMarked(_ path: String) -> Bool { marks?.isMarked(path) ?? false }
    func isDirectlyMarked(_ path: String) -> Bool { marks?.isDirectlyMarked(path) ?? false }

    /// The rules dialog: every mark and rule as editable text.
    var markRules: (marks: [String], rules: [String]) { (marks?.data.marks ?? [], marks?.data.rules ?? []) }

    func setMarkRules(marks: [String], rules: [String]) {
        self.marks?.setRules(marks: marks, rules: rules)
        version += 1
        Task { await autoStageUnimportant() }
    }

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
        if let next = ordered.first(where: { stage(of: $0) != .staged }), select(next.path) {
            expandAncestors(of: next.path)
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
