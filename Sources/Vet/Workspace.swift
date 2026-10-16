import Foundation
import Observation

/// One open project: its Review and Files state, sharing a single folder watcher.
@MainActor @Observable
final class Workspace {
    let review = ReviewModel()
    let files = FilesModel()
    private(set) var root: URL?
    private var watcher: RepoWatcher?

    func open(_ folder: URL?) {
        guard folder?.standardizedFileURL != root?.standardizedFileURL else {
            Task { await review.refresh() }
            return
        }
        root = folder
        review.open(folder)
        files.open(folder)
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
