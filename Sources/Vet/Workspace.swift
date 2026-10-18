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
    private(set) var navigator: CodeNavigator?
    /// "Find references" (or several definitions): the list to pick from.
    var navResults: (title: String, locations: [CodeLocation])?
    /// Shown while a language server answers ("Finding definition…").
    private(set) var navBusy: String?
    /// Shows a file in the editor after navigation (set by the app; records history).
    var onOpenFile: ((URL, Int) -> Void)?
    /// Asked to open another project (Review follows the Claude chat you're working in).
    var onOpenProject: ((URL) -> Void)?
    /// Set when Claude finishes a reply in this project: unreviewed files for the Review badge.
    var onClaudeFinished: ((Int) -> Void)?
    private(set) var root: URL?
    private var watcher: RepoWatcher?
    /// What Search Everywhere currently suggests.
    var searchResults = SearchResults()

    // MARK: Code navigation

    /// Go to definition / implementation, or find references, from (line, column) in `url`
    /// (whose current text, unsaved edits included, is `text`).
    func navigate(_ kind: CodeTextView.Navigation, url: URL, text: String, line: Int, character: Int) {
        guard let navigator else { return }
        guard navigator.isSupported(url) else {
            link.flash("Go to definition works in TypeScript, JavaScript, Python and Kotlin files.")
            return
        }
        let title: String = switch kind {
        case .definition: "Definition"
        case .implementation: "Implementations"
        case .references: "References"
        }
        navBusy = "Finding \(title.lowercased())…"
        Task {
            var found: [CodeLocation] = switch kind {
            case .definition: await navigator.definition(of: url, text: text, line: line, character: character)
            case .implementation: await navigator.implementation(of: url, text: text, line: line, character: character)
            case .references: await navigator.references(of: url, text: text, line: line, character: character)
            }
            // Like VS Code: a definition that lands on an import of the symbol follows it to the
            // real declaration (the TypeScript server sometimes answers with the alias).
            if kind == .definition, found.count == 1, let hop = await followImport(found[0], navigator: navigator) {
                found = hop
            }
            navBusy = nil
            if found.isEmpty {
                link.flash("No \(title.lowercased()) found.")
            } else if found.count == 1 && kind != .references {
                open(found[0])
            } else {
                navResults = (title, found)
            }
        }
    }

    private func followImport(_ loc: CodeLocation, navigator: CodeNavigator) async -> [CodeLocation]? {
        guard let text = try? String(contentsOf: loc.url, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard loc.startLine < lines.count else { return nil }
        let line = lines[loc.startLine].trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("import ") || line.hasPrefix("export {") || line.hasPrefix("from ") else { return nil }
        let next = await navigator.definition(of: loc.url, text: text, line: loc.startLine, character: loc.startCharacter)
        return next.isEmpty || next == [loc] ? nil : next
    }

    /// Opens a location in the Files tab, caret on it.
    func open(_ location: CodeLocation) {
        navResults = nil
        files.show(location.url, line: location.startLine, character: location.startCharacter)
        if files.openURL == location.url { onOpenFile?(location.url, location.startLine) }
    }

    func startLink() {
        review.link = link
        link.onFolderChanged = { [weak self] cwd in
            // Never pull the project out from under unsaved edits or a running app.
            guard let self, !self.hasUnsavedEdits, !self.run.isRunning else { return }
            let folder = URL(fileURLWithPath: cwd, isDirectory: true)
            let target = GitRepo.root(containing: folder) ?? folder
            if let root = self.root, Self.same(target.path, root), Self.same(root.path, target) { return }
            self.onOpenProject?(target)
        }
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

    /// Unsaved edits anywhere in this project (Files or the diff).
    var hasUnsavedEdits: Bool { files.isDirty || review.diffDirty }

    /// Before switching projects or quitting: asks about unsaved edits. False means stay.
    func confirmLeave() -> Bool { files.confirmLeave() && review.confirmLeaveDiff() }

    func open(_ folder: URL?) {
        guard folder?.standardizedFileURL != root?.standardizedFileURL else {
            Task { await review.refresh() }
            return
        }
        root = folder
        navigator?.shutdown()
        navigator = folder.map { CodeNavigator(root: $0) }
        review.navigator = { [weak self] kind, url, text, line, character in self?.navigate(kind, url: url, text: text, line: line, character: character) }
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
