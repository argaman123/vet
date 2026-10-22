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
    /// The declarations around the top of the diff's new side (for a header that shows them),
    /// and how to scroll to one.
    var scope: [(line: Int, text: NSAttributedString)] = []
    @ObservationIgnored var scopeJump: ((Int) -> Void)?
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
    /// Your review marks, kept by Vet (git's index is never touched for them).
    private(set) var store: ReviewStore?
    /// Per changed file, what marks attach to: its sections' fingerprints (or one for the whole
    /// file), in order. Worked out in the background after each refresh.
    private(set) var units: [String: [String]] = [:]
    private var scanSerial = 0

    /// Claude's suggested review order (via Vet's MCP tool), and whether the list follows it.
    private(set) var plan: ReviewPlan?
    var followPlan = UserDefaults.standard.object(forKey: "followPlan") as? Bool ?? true {
        didSet { UserDefaults.standard.set(followPlan, forKey: "followPlan") }
    }

    func setPlan(_ p: ReviewPlan?) {
        plan = p
        guard let root else { return }
        if let p { p.save(root: root) } else { try? FileManager.default.removeItem(at: ReviewPlan.url(root: root)) }
        followPlan = p != nil
        version += 1
    }

    /// The reviewed fraction of a file or folder, by sections (nil when unknown).
    func reviewedFraction(_ node: FileTreeNode) -> Double? {
        var total = 0, done = 0
        for c in node.fileChanges {
            guard let u = units[c.path] else { continue }
            total += u.count
            done += store?.reviewedCount(c.path, of: u) ?? 0
        }
        return total == 0 ? nil : Double(done) / Double(total)
    }

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
            let tidy = summary.split(whereSeparator: \.isWhitespace).joined(separator: " ").replacingOccurrences(of: "->", with: "→")
            link?.flash(tidy.isEmpty ? "Committed and pushed" : "Committed and pushed · \(tidy)")
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

    /// A new theme rebuilds the diff's colored text.
    @ObservationIgnored private lazy var themeObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: .vetThemeChanged, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.diffVersion += 1 }
    }

    func open(_ folder: URL?) {
        _ = themeObserver
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
        plan = isGitRepo ? ReviewPlan.load(root: folder) : nil
        repo = isGitRepo ? GitRepo(root: folder) : nil
        marks = isGitRepo ? MarkStore(root: folder) : nil
        store?.save()
        store = isGitRepo ? ReviewStore(root: folder) : nil
        units = [:]
        notes = NoteStore(root: folder)
        // A note left without text (Vet quit while it was being written) isn't a note.
        if let notes { for n in notes.notes where n.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { notes.delete(n.id) } }
        Task { await refresh() }
    }

    func refresh() async {
        guard let repo else { return }
        do {
            let fresh = try await repo.status()
            let known = Set(changes.map(\.path))
            changes = fresh
            tree = FileTreeNode.build(fresh)
            // New files open their folders, even if they appeared while Vet was closed;
            // unimportant ones don't.
            for c in fresh where !known.contains(c.path) && !(marks?.isMarked(c.path) ?? false) { expandAncestors(of: c.path) }
            // A file that left the list (say Claude committed it) closes, unless you're editing it.
            if let sel = selectedPath, !fresh.contains(where: { $0.path == sel }), !diffDirty { selectedPath = nil }
            version += 1
            await loadDiff()
            await scanUnits()
            await refreshBranches()
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

    /// Reviewed, partly reviewed or not, from Vet's own marks.
    func stage(of change: FileChange) -> StageState {
        guard let u = units[change.path], let store, !u.isEmpty else { return .unstaged }
        let n = store.reviewedCount(change.path, of: u)
        return n == 0 ? .unstaged : n == u.count ? .staged : .partial
    }

    /// The open file's sections: which are reviewed (the diff draws these).
    var hunkStates: [Int: StageState] {
        guard let doc = diff, let staging = doc.staging, let store else { return [:] }
        var out: [Int: StageState] = [:]
        for (h, fp) in zip(staging.hunks, staging.fingerprints()) { out[h.id] = store.isReviewed(doc.change.path, fp) ? .staged : .unstaged }
        return out
    }

    /// Works out every changed file's sections (in the background, file by file) and, the first
    /// time Vet opens a project, takes what git already has staged as reviewed.
    private func scanUnits() async {
        guard let repo, let store, let root else { return }
        let started = Date()
        scanSerial += 1
        let serial = scanSerial
        let seed = store.isNew && units.isEmpty
        let cache = UnitsCache(root: root)
        let keys = await repo.unitKeys(changes)
        guard serial == scanSerial else { return }
        // Files unchanged since last time: their sections at once, so your marks show on open.
        var fresh: [String: [String]] = [:]
        var stale: [FileChange] = []
        for c in changes {
            if !seed, let key = keys[c.path], let hit = cache.units(c.path, key: key) { fresh[c.path] = hit } else { stale.append(c) }
        }
        if !fresh.isEmpty {
            for (path, u) in fresh { units[path] = u }
            version += 1
            autoReviewUnimportant()
        }
        // The rest, one by one, each showing as soon as it's known.
        var lastShown = Date()
        for c in stale {
            let (u, staged) = await repo.reviewUnits(c)
            guard serial == scanSerial else { return } // a newer refresh took over
            fresh[c.path] = u
            units[c.path] = u
            if let key = keys[c.path] { cache.set(c.path, key: key, units: u) }
            if seed, !staged.isEmpty { store.set(c.path, Array(staged), reviewed: true) }
            store.prune(c.path, keeping: u)
            if Date().timeIntervalSince(lastShown) > 0.12 { version += 1; lastShown = Date() }
        }
        units = fresh
        version += 1
        cache.save(keeping: Set(changes.map(\.path)))
        if seed { store.save() }
        autoReviewUnimportant()
        if SnapshotHook.isTesting, let dir = ProcessInfo.processInfo.environment["VET_SNAPSHOT_DIR"] {
            try? "scan: \(changes.count) files (\(stale.count) diffed) in \(Int(Date().timeIntervalSince(started) * 1000)) ms".write(toFile: dir + "/scan.txt", atomically: true, encoding: .utf8)
        }
    }

    /// Marks (or unmarks) whole files: every section in them.
    private func mark(_ files: [FileChange], reviewed: Bool) async {
        guard let repo, let store else { return }
        for c in files {
            if units[c.path] == nil { units[c.path] = await repo.reviewUnits(c).units }
            store.set(c.path, units[c.path] ?? [], reviewed: reviewed)
        }
        version += 1
        if files.contains(where: { $0.path == diff?.change.path }) { diffVersion += 1 }
    }

    func stage(of node: FileTreeNode) -> StageState {
        let states = Set(node.fileChanges.map { stage(of: $0) })
        if states == [.staged] { return .staged }
        if states == [.unstaged] || states.isEmpty { return .unstaged }
        return .partial
    }

    /// Marks every file at or under `node` reviewed (or not). Instant: only Vet's own marks change.
    func setStaged(_ node: FileTreeNode, _ staged: Bool) {
        error = nil
        let targets = node.fileChanges.filter { $0.kind != .conflicted && (staged ? stage(of: $0) != .staged : stage(of: $0) != .unstaged) }
        guard let root, !targets.isEmpty else { return }
        // Unchecking an unimportant file holds it unreviewed until it changes again.
        for c in targets where marks?.isMarked(c.path) ?? false {
            if staged { marks?.releaseHold(c.path) } else { marks?.hold(c.path, hash: MarkStore.contentHash(root: root, path: c.path)) }
        }
        Task { await mark(targets, reviewed: staged) }
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

    /// Every unchanged region folded, none opened by hand. (Reviewed changes never fold: they're
    /// the code as it now is, so they stay, only quieter.)
    var allCollapsed: Bool { folding && expandedFolds.isEmpty }

    /// Folds every unchanged region, or opens them all.
    func setAllCollapsed(_ collapsed: Bool) {
        folding = collapsed
        expandedFolds = []
        diffVersion += 1
    }

    func expandFold(_ id: Int) {
        expandedFolds.insert(id)
        diffVersion += 1
    }

    func jumpToChange(forward: Bool) { jump = (jump.serial + 1, forward) }

    /// Bumped to approve the change in view and move to the next one (the diff view does it).
    private(set) var approveSerial = 0
    func approveAndNext() {
        guard diff?.staging != nil else { nextUnreviewed(); return }
        approveSerial += 1
    }

    /// Marks one section of the open file reviewed (or not). Instant: only Vet's own marks change.
    func setHunk(_ id: Int, staged: Bool, snapshot: String) {
        guard let root, let store, let doc = diff, let staging = doc.staging, staging.snapshotID == snapshot,
              let i = staging.hunks.firstIndex(where: { $0.id == id }) else { return }
        let path = doc.change.path
        error = nil
        // Unchecking part of an unimportant file holds it, just like unchecking the whole file.
        if isMarked(path) {
            if staged { marks?.releaseHold(path) } else { marks?.hold(path, hash: MarkStore.contentHash(root: root, path: path)) }
        }
        Timing.selectionStarted = Date() // logTiming: how long until the diff shows the mark
        let fps = staging.fingerprints()
        store.set(path, [fps[i]], reviewed: staged)
        if units[path] == nil { units[path] = fps }
        version += 1
        diffVersion += 1
    }

    /// Asks Claude to commit the files you've fully reviewed: the request, with the list, goes on
    /// the clipboard and Claude comes forward to paste it into.
    func askClaudeToCommit() {
        let reviewed = changes.filter { stage(of: $0) == .staged }.map(\.path)
        guard !reviewed.isEmpty else { show("Nothing is fully reviewed yet."); return }
        let list = reviewed.map { "- \($0)" }.joined(separator: "\n")
        let text = "Commit the files I've reviewed in Vet (only these; leave everything else as it is), with a message that says what changed:\n\(list)\n"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ClaudeReference.bringClaudeForward()
    }

    // MARK: Review notes

    /// Notes on the open file: yours and Claude's (each re-found by its line's text if the file
    /// moved under it), and Claude's explanations of its changes from the review order.
    func notesForOpenFile() -> [ReviewNote] {
        guard let doc = diff, let staging = doc.staging else { return [] }
        return storedNotesForOpenFile() + explanations(doc.change.path, staging.work)
    }

    /// The review order's notes on a file's functions and lines, as Claude's notes beside them.
    /// A note with only a symbol goes on the first line that names it.
    func explanations(_ path: String, _ work: TextLines) -> [ReviewNote] {
        guard let file = plan?.file(path), let notes = file.notes else { return [] }
        return notes.enumerated().compactMap { i, n in
            let line = n.line.flatMap { $0 >= 0 && $0 < work.count ? $0 : nil } ?? n.symbol.flatMap { sym in
                work.lines.firstIndex { $0.text.contains(sym) }
            }
            guard let line else { return nil }
            var note = ReviewNote(path: path, left: false, line: line, lineText: String(work.lines[line].text),
                                  text: n.symbol.map { "\($0): \(n.text)" } ?? n.text)
            note.id = "plan:\(path):\(i)"
            note.fromClaude = true
            return note
        }
    }

    private func storedNotesForOpenFile() -> [ReviewNote] {
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
        return (notes?.notes ?? []).filter { !$0.sent && !$0.text.isEmpty && !$0.isClaude }
    }

    /// A note written in the popover beside a working-file line of the open diff; its id.
    @discardableResult
    func createNote(line: Int, lineText: String, text: String) -> String? {
        guard let notes, let path = diff?.change.path else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let note = ReviewNote(path: path, left: false, line: line, lineText: lineText, text: trimmed)
        notes.upsert(note)
        noteChanged()
        return note.id
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

    /// Your notes for Claude (get_notes): each with the line it's on now in the working file.
    func notesForClaude() -> [ReviewNote] {
        guard let notes, let root else { return [] }
        var files: [String: [String]] = [:]
        return notes.notes.filter { !$0.isClaude && !$0.text.isEmpty }.map { n in
            guard !n.left else { return n }
            var n = n
            let lines = files[n.path] ?? ((try? String(contentsOf: root.appendingPathComponent(n.path), encoding: .utf8))?
                .components(separatedBy: "\n") ?? [])
            files[n.path] = lines
            if n.line >= lines.count || lines[n.line] != n.lineText {
                if let near = lines.indices.filter({ lines[$0] == n.lineText }).min(by: { abs($0 - n.line) < abs($1 - n.line) }) { n.line = near }
            }
            return n
        }
    }

    /// Claude's notes that are still showing (point_at_code keeps them few).
    var claudeNotes: [ReviewNote] { (notes?.notes ?? []).filter(\.isClaude) }

    /// Claude points at lines of a changed file: a card under them in the diff, until you dismiss it.
    func addClaudeNote(path: String, line: Int, lineText: String, text: String) -> ReviewNote? {
        guard let notes else { return nil }
        var note = ReviewNote(path: path, left: false, line: line, lineText: lineText, text: text)
        note.fromClaude = true
        notes.upsert(note)
        noteChanged()
        return note
    }

    /// Claude's answers to your notes: each of those notes becomes Claude's reply on the same line
    /// (you read it in Vet and dismiss it). Returns how many it found, and the replies made.
    func replyToNotes(_ replies: [String: String]) -> (count: Int, made: [ReviewNote]) {
        guard let notes else { return (0, []) }
        var n = 0, made: [ReviewNote] = []
        for (id, text) in replies {
            guard let mine = notes.notes.first(where: { $0.id == id && !$0.isClaude }) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            notes.delete(id)
            if !trimmed.isEmpty {
                var reply = ReviewNote(path: mine.path, left: mine.left, line: mine.line, lineText: mine.lineText, text: trimmed)
                reply.fromClaude = true
                reply.question = mine.text
                notes.upsert(reply)
                made.append(reply)
            }
            n += 1
        }
        if editingNoteID.map({ replies[$0] != nil }) == true { editingNoteID = nil }
        noteChanged()
        return (n, made)
    }

    /// Notes Claude handled (or pointers it takes back): gone from the diff.
    func removeNotes(_ ids: [String]) -> Int {
        guard let notes else { return 0 }
        let found = ids.filter { id in notes.notes.contains { $0.id == id } }
        for id in found { notes.delete(id) }
        if let editing = editingNoteID, found.contains(editing) { editingNoteID = nil }
        noteChanged()
        return found.count
    }

    private func noteChanged() {
        notesVersion += 1
        diffVersion += 1
    }

    /// File summaries you closed this session (file, summary and contents): they stay closed.
    @ObservationIgnored var closedSummaries: Set<String> = []

    /// The key a file's summary is remembered by: the file, the summary and the file's contents.
    static func summaryKey(_ path: String, _ summary: String, _ snapshot: String) -> String { "\(path)|\(summary)|\(snapshot)" }

    /// The open file's summary will open by itself (you haven't closed it since it last changed).
    func summaryWillOpen() -> Bool {
        guard let doc = diff, let file = plan?.file(doc.change.path) else { return false }
        return !closedSummaries.contains(Self.summaryKey(doc.change.path, file.summary, doc.staging?.snapshotID ?? ""))
    }

    /// Wakes the Claude chat listening on this project (true), or nil/false when none is.
    @ObservationIgnored var onNotesSent: (() -> Bool)?

    /// Your notes go to Claude to fix: marked sent, and the Claude chat listening on this project
    /// (see MCPServer's waiting chats) is woken to read them with get_notes. With no chat
    /// listening they wait, and the next one to listen gets them at once. `ids` picks notes (sent
    /// before or not); nil sends every unsent one.
    func sendNotes(ids: [String]? = nil) {
        guard let notes else { return }
        let chosen = ids.map { ids in notes.notes.filter { ids.contains($0.id) && !$0.isClaude && !$0.text.isEmpty } } ?? unsentNotes
        guard !chosen.isEmpty else { return }
        for var n in chosen { n.sent = true; notes.upsert(n) }
        noteChanged()
        let woke = onNotesSent?() ?? false
        let what = chosen.count == 1 ? "Note" : "\(chosen.count) notes"
        link?.flash(woke ? "\(what) sent to Claude." : "\(what) waiting for Claude. No Claude chat is listening: type \u{201C}vet\u{201D} once in your Claude chat.")
    }

    /// What a listening chat is told when your notes are waiting for it; nil when none are.
    func wakeMessage() -> String? {
        let waiting = (notes?.notes ?? []).filter { $0.sent && !$0.isClaude && !$0.text.isEmpty }
        guard !waiting.isEmpty, let root else { return nil }
        let count = waiting.count == 1 ? "a review note" : "\(waiting.count) review notes"
        return """
            Vet: the user sent you \(count) in \(root.path). Call get_notes, handle the ones marked sent \
            (fix the code, or answer if it's a question), then call resolve_notes with a short reply for each \
            (Vet shows it beside the line). Then start this same listener again in the background.
            """
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
    /// Loads reading aids into the diff's working-file pane once it shows a file.
    var readingAids: ((RibbonDiffNSView) -> Void)?

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

    // MARK: Unimportant

    func isMarked(_ path: String) -> Bool { marks?.isMarked(path) ?? false }
    func isDirectlyMarked(_ path: String) -> Bool { marks?.isDirectlyMarked(path) ?? false }

    /// The rules dialog: every mark and rule as editable text.
    var markRules: (marks: [String], rules: [String]) { (marks?.data.marks ?? [], marks?.data.rules ?? []) }

    func setMarkRules(marks: [String], rules: [String]) {
        self.marks?.setRules(marks: marks, rules: rules)
        version += 1
        autoReviewUnimportant()
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
        autoReviewUnimportant()
    }

    /// Marks unimportant files reviewed, except ones you unchecked that haven't changed since.
    private func autoReviewUnimportant() {
        guard let root, let marks else { return }
        let due = changes.filter { c in
            guard c.kind != .conflicted, marks.isMarked(c.path), units[c.path] != nil, stage(of: c) != .staged else { return false }
            if let held = marks.heldHash(c.path) {
                if held == MarkStore.contentHash(root: root, path: c.path) { return false }
                marks.releaseHold(c.path) // it changed since you unchecked it
            }
            return true
        }
        guard let store, !due.isEmpty else { return }
        for c in due { store.set(c.path, units[c.path] ?? [], reviewed: true) }
        version += 1
        if due.contains(where: { $0.path == diff?.change.path }) { diffVersion += 1 }
    }

    /// The changed files as the sidebar lists them right now (review order first, then its
    /// sections), set by the sidebar: ⌘↩ moves through files in this order.
    @ObservationIgnored var sidebarOrder: [String] = []

    /// The next file with changes left to review, after the open one in the sidebar's order,
    /// wrapping around (so after you check a fix up the list, you're taken back down to where you were).
    /// ⌘↑ at the first change or ⌘↓ at the last, pressed twice: the previous or next file in the
    /// sidebar's order, at its last or first change.
    func stepFile(forward: Bool) {
        let paths = sidebarOrder.filter { p in changes.contains { $0.path == p } }
        guard let here = selectedPath.flatMap({ paths.firstIndex(of: $0) }) else { return }
        let next = here + (forward ? 1 : -1)
        guard paths.indices.contains(next) else { link?.flash(forward ? "That was the last file." : "That was the first file."); return }
        diffView.landOnLast = !forward
        if select(paths[next]) { expandAncestors(of: paths[next]); version += 1 }
    }

    /// Whether the change you're on has a note from Claude (⌘← shows it, ⌘→ hides it).
    var claudeNoteHere = false

    func nextUnreviewed() {
        let byPath = Dictionary(changes.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let listed = sidebarOrder.compactMap { byPath[$0] }
        let shown = Set(listed.map(\.path))
        let files = listed + FileTreeNode.filesInOrder(tree).filter { !shown.contains($0.path) }
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

    /// Every folder in the tree is open.
    var allExpanded: Bool {
        var folders: [String] = []
        func walk(_ nodes: [FileTreeNode]) { for n in nodes where n.isFolder { folders.append(n.path); walk(n.children) } }
        walk(tree)
        return !folders.isEmpty && folders.allSatisfy(expanded.contains)
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
