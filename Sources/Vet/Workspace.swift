import Foundation
import Observation
import VetCore

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
            link.flash("Code navigation works in TypeScript, JavaScript, Python and Kotlin files.")
            return
        }
        let symbol = Self.word(in: text, line: line, character: character) ?? "Symbol"
        navBusy = kind == .references ? "Finding usages of \(symbol)…" : kind == .implementation ? "Finding implementations…" : "Finding declaration…"
        Task {
            var kind = kind
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
            // Like WebStorm: go to declaration on the declaration itself shows its usages.
            if kind == .definition, found.count == 1, found[0].url.standardizedFileURL == url.standardizedFileURL,
               found[0].startLine == line, (found[0].startCharacter...max(found[0].endCharacter, found[0].startCharacter)).contains(character) {
                kind = .references
                navBusy = "Finding usages of \(symbol)…"
                found = await navigator.references(of: url, text: text, line: line, character: character)
            }
            navBusy = nil
            if found.isEmpty {
                link.flash(kind == .references ? "No usages of \(symbol) found." : kind == .implementation ? "No implementations found." : "No declaration found.")
            } else if found.count == 1 && kind != .references {
                open(found[0])
            } else {
                let editing = files.openURL
                ReferencesPresenter.shared.show(symbol: symbol, locations: found, root: root, textOf: { [weak self] u in
                    guard let self, u == editing, let view = self.files.editorText?() else { return nil }
                    return view
                }, open: { [weak self] loc in self?.open(loc) })
            }
        }
    }

    /// Hover info at (line, column): the symbol's signature and documentation in a popover.
    func hover(url: URL, text: String, line: Int, character: Int) {
        guard let navigator, navigator.isSupported(url) else { return }
        let language = CodeLanguage(path: url.path)
        Task {
            guard let content = await hoverContent(navigator, url: url, text: text, line: line, character: character, language: language) else { return }
            HoverPresenter.shared.show(content)
        }
    }

    /// The identifier around a position (for titles like "Usages of LoopLayer").
    static func word(in text: String, line: Int, character: Int) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard line < lines.count else { return nil }
        let u = Array(lines[line].utf16)
        guard character <= u.count else { return nil }
        func isWord(_ c: UInt16) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 }
        var lo = character, hi = character
        while lo > 0, isWord(u[lo - 1]) { lo -= 1 }
        while hi < u.count, isWord(u[hi]) { hi += 1 }
        return hi > lo ? String(decoding: u[lo..<hi], as: UTF16.self) : nil
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
            // Never pull the project out from under unsaved edits or a running app; tests never follow.
            guard let self, !self.hasUnsavedEdits, !self.run.isRunning, !SnapshotHook.isTesting else { return }
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
        review.hoverer = { [weak self] url, text, line, character in self?.hover(url: url, text: text, line: line, character: character) }
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

extension Workspace {
    /// Asks the language server for hover info (wired once the hover request lands).
    func hoverContent(_ navigator: CodeNavigator, url: URL, text: String, line: Int, character: Int, language: CodeLanguage) async -> HoverContent? {
        nil
    }
}
