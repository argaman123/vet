import AppKit
import Observation
import VetCore

/// State of the Review tab for one project.
@MainActor @Observable
final class ReviewModel {
    private(set) var root: URL?
    private(set) var repo: GitRepo?
    private(set) var changes: [FileChange] = []
    private(set) var tree: [FileTreeNode] = []
    /// Bumped on every refresh so the outline view knows to reload.
    private(set) var version = 0
    var selectedPath: String?
    /// Folders the user has expanded (repo-relative paths).
    var expanded: Set<String> = []
    private(set) var error: String?
    private(set) var isGitRepo = true
    /// Paths staged/unstaged optimistically while git runs.
    private var pending: [String: StageState] = [:]

    var reviewedCount: Int { changes.filter { stage(of: $0) == .staged }.count }

    func open(_ folder: URL?) {
        root = folder
        selectedPath = nil
        changes = []
        tree = []
        expanded = []
        guard let folder else { repo = nil; return }
        isGitRepo = GitRepo.root(containing: folder) != nil
        repo = isGitRepo ? GitRepo(root: folder) : nil
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
            // New files open their folders, even if they appeared while Vet was closed.
            for c in fresh where !known.contains(c.path) { expandAncestors(of: c.path) }
            if let sel = selectedPath, !fresh.contains(where: { $0.path == sel }) { selectedPath = nil }
            error = nil
            version += 1
        } catch {
            self.error = "\(error)"
        }
    }

    func stage(of change: FileChange) -> StageState { pending[change.path] ?? change.stage }

    func stage(of node: FileTreeNode) -> StageState {
        let states = Set(node.fileChanges.map { stage(of: $0) })
        if states == [.staged] { return .staged }
        if states == [.unstaged] || states.isEmpty { return .unstaged }
        return .partial
    }

    /// Stages (or unstages) every file at or under `node`. The checkbox flips at once; git runs in order.
    func setStaged(_ node: FileTreeNode, _ staged: Bool) {
        let targets = node.fileChanges.filter { staged ? stage(of: $0) != .staged : stage(of: $0) != .unstaged }
        guard let repo, !targets.isEmpty else { return }
        for c in targets { pending[c.path] = staged ? .staged : .unstaged }
        version += 1
        Task {
            do {
                for c in targets {
                    if staged { try await repo.stageFile(c) } else { try await repo.unstageFile(c) }
                }
            } catch {
                self.error = "Couldn't \(staged ? "stage" : "unstage"): \(error)"
            }
            await refresh() // shows git's real state, success or not
        }
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
