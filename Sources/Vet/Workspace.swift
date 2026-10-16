import Foundation
import Observation

/// One open project: its Review and Files state, sharing a single folder watcher.
@MainActor @Observable
final class Workspace {
    let review = ReviewModel()
    let files = FilesModel()
    let browser = BrowserModel()
    let run = RunModel()
    let link = ClaudeLink()
    /// Set when Claude finishes a reply in this project: unreviewed files for the Review badge.
    var onClaudeFinished: ((Int) -> Void)?
    private(set) var root: URL?
    private var watcher: RepoWatcher?

    func startLink() {
        review.link = link
        link.start()
        link.onTurnComplete = { [weak self] cwd in
            guard let self, let root = self.root, Self.same(cwd, root) else { return }
            Task {
                await self.review.refresh()
                let unreviewed = self.review.changes.filter { self.review.stage(of: $0) != .staged }.count
                self.onClaudeFinished?(unreviewed)
            }
        }
    }

    /// Whether Claude's folder is this project (or inside it).
    static func same(_ cwd: String, _ root: URL) -> Bool {
        let a = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path, b = root.resolvingSymlinksInPath().path
        return a == b || a.hasPrefix(b + "/")
    }

    func open(_ folder: URL?) {
        guard folder?.standardizedFileURL != root?.standardizedFileURL else {
            Task { await review.refresh() }
            return
        }
        root = folder
        review.open(folder)
        files.open(folder)
        browser.open(project: folder)
        run.open(folder)
        run.onLocalURL = { [weak self] url in self?.browser.openIfIdle(url) }
        // Claude edits files and stages/commits while you review: follow along.
        watcher = folder.map { f in
            RepoWatcher(root: f, gitDir: GitRepo.gitDir(of: f)) { [weak self] in
                guard let self else { return }
                Task { await self.review.refresh() }
                self.files.diskChanged()
            }
        }
    }
}
