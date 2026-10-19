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
    /// Gutter jump icons' targets, by file and line (from the last reading-aids load).
    @ObservationIgnored var jumpTargets: [URL: [Int: GutterMark]] = [:]
    /// Shows a file in the editor after navigation (set by the app; records history).
    var onOpenFile: ((URL, Int) -> Void)?
    /// Asked to open another project (Review follows the Claude chat you're working in).
    var onOpenProject: ((URL) -> Void)?
    /// Set when Claude finishes a reply in this project: unreviewed files for the Review badge.
    var onClaudeFinished: ((Int) -> Void)?
    private(set) var root: URL?
    private var watcher: RepoWatcher?
    /// What Search Everywhere currently suggests.

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
        navBusy = kind == .references || kind == .usagesOrDeclaration ? "Finding usages of \(symbol)…" : kind == .implementation ? "Finding implementations…" : "Finding declaration…"
        ReferencesPresenter.shared.beginLoading(navBusy ?? "")
        Task {
            var kind = kind
            var found: [CodeLocation] = switch kind {
            case .definition: await navigator.definition(of: url, text: text, line: line, character: character)
            case .implementation: await navigator.implementation(of: url, text: text, line: line, character: character)
            case .references: await navigator.references(of: url, text: text, line: line, character: character)
            case .usagesOrDeclaration: await navigator.references(of: url, text: text, line: line, character: character)
            }
            // Force click: usages if anything besides this very spot uses the symbol, else its declaration.
            if kind == .usagesOrDeclaration {
                let elsewhere = found.filter { loc in
                    !(loc.url.standardizedFileURL == url.standardizedFileURL && loc.startLine == line
                      && (loc.startCharacter...max(loc.endCharacter, loc.startCharacter)).contains(character))
                }
                if elsewhere.isEmpty {
                    kind = .definition
                    navBusy = "Finding declaration…"
                    found = await navigator.definition(of: url, text: text, line: line, character: character)
                } else {
                    kind = .references
                }
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
            if found.isEmpty || (found.count == 1 && kind != .references) { ReferencesPresenter.shared.endLoading() }
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
        let token = HoverPresenter.shared.currentToken // the request the text view just prepared
        Task {
            guard let content = await hoverContent(navigator, url: url, text: text, line: line, character: character, language: language) else { return }
            HoverPresenter.shared.show(content, token: token)
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
        review.readingAids = { [weak self] view in self?.loadReadingAids(diff: view) }
        ReferencesPresenter.shared.tokens = { [weak self] url, text in
            guard let navigator = self?.navigator, navigator.isSupported(url) else { return [] }
            return await navigator.semanticTokens(of: url, text: text)
        }
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
    /// Asks the language server for hover info.
    func hoverContent(_ navigator: CodeNavigator, url: URL, text: String, line: Int, character: Int, language: CodeLanguage) async -> HoverContent? {
        guard let info = await navigator.hover(of: url, text: text, line: line, character: character) else { return nil }
        let signature = info.signature ?? "", docs = info.documentation ?? ""
        guard !signature.isEmpty || !docs.isEmpty else { return nil }
        return HoverContent(signature: signature, documentation: docs, language: language)
    }

    // MARK: Reading aids: semantic colors, inline hints, usage/author lenses, jump icons

    /// For the editor: everything, once the text is shown or typing pauses.
    func loadReadingAids(editor view: CodeEditorView, url: URL) {
        let text = view.currentText
        let current = { [weak view] in view?.currentText == text }
        view.lineGutter.onMarkClick = { [weak self, weak view] line, _, rect in
            guard let self, let view else { return }
            NavigationAnchor.set(view.lineGutter, rect)
            self.openJumpTargets(line: line, url: url, text: view.currentText)
        }
        view.pane.onLensClick = { [weak self, weak view] lens in
            guard let self, let view else { return }
            self.navigate(.references, url: url, text: view.currentText, line: lens.line, character: lens.character)
        }
        loadReadingAids(pane: view.pane, gutter: view.lineGutter, url: url, text: text, row: { $0 }, current: current)
    }

    /// For the diff's working-file pane.
    func loadReadingAids(diff view: RibbonDiffNSView) {
        guard let root, let doc = review.diff, let text = view.shownWorkText else { return }
        let url = root.appendingPathComponent(doc.change.path)
        let current = { [weak view] in view?.shownWorkText == text && !(view?.isDirty ?? true) }
        loadReadingAids(pane: view.workPane, gutter: nil, url: url, text: text, row: { [weak view] in view?.workRow(ofFileLine: $0) }, current: current)
        // HEAD gets the same name colors (the server is asked about that text too).
        if let navigator, navigator.isSupported(url), let head = view.shownHeadText {
            Task { [weak view] in
                let tokens = await navigator.semanticTokens(of: url, text: head)
                guard let view, view.shownHeadText == head else { return }
                view.headPane.applySemanticTokens(tokens, display: { [weak view] in view?.headRow(ofFileLine: $0) })
            }
        }
    }

    private func loadReadingAids(pane: CodeTextView, gutter: LineNumberGutter?, url: URL, text: String,
                                 row: @escaping (Int) -> Int?, current: @escaping () -> Bool) {
        guard let navigator, navigator.isSupported(url) else {
            pane.inlayHints = []
            pane.lenses = []
            gutter?.marks = [:]
            return
        }
        let lineCount = text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
        Task { [weak pane] in
            let tokens = await navigator.semanticTokens(of: url, text: text)
            guard let pane, current() else { return }
            pane.applySemanticTokens(tokens, display: row)
        }
        Task { [weak pane] in
            let hints = await navigator.inlayHints(of: url, text: text, lines: 0..<lineCount)
            guard let pane, current() else { return }
            pane.inlayHints = hints.compactMap { h in
                guard let label = Self.hintLabel(h) else { return nil }
                return row(h.line).map { InlayHintMark(line: $0, character: h.character, label: label, padLeft: h.paddingLeft, padRight: h.paddingRight) }
            }
        }
        Task { [weak pane] in
            let lenses = await navigator.codeLenses(of: url, text: text)
            // One lens per line: usages (and implementations) from the server. No author names.
            var byLine: [Int: [CodeLensInfo]] = [:]
            for l in lenses { byLine[l.line, default: []].append(l) }
            let lines = byLine.keys.sorted()
            guard let pane, current() else { return }
            pane.lenses = lines.compactMap { line in
                guard let r = row(line) else { return nil }
                let infos = byLine[line] ?? []
                let parts = infos.compactMap(Self.lensText)
                guard !parts.isEmpty else { return nil }
                return LineLensMark(line: r, character: infos.first?.character ?? 0, text: parts.joined(separator: " · "))
            }
        }
        if let gutter {
            Task { [weak gutter] in
                let marks = await navigator.gutterMarks(of: url, text: text)
                guard let gutter, current() else { return }
                var out: [Int: LineNumberGutter.JumpMark] = [:]
                for m in marks { if let r = row(m.line) { out[r] = m.kind == .overrides ? .overrides : .implemented } }
                gutter.marks = out
                jumpTargets[url] = Dictionary(marks.map { ($0.line, $0) }, uniquingKeysWith: { a, _ in a })
            }
        }
    }

    /// What a hint shows: nothing for a type that only repeats a literal (": 30", ": 'bolt'"),
    /// and long types cut short, as VS Code does.
    nonisolated static func hintLabel(_ h: InlayHint) -> String? {
        var label = h.label.trimmingCharacters(in: .whitespaces)
        if h.kind == .type {
            let type = label.hasPrefix(":") ? label.dropFirst().trimmingCharacters(in: .whitespaces) : label
            if type.first.map({ $0.isNumber || $0 == "\"" || $0 == "'" || $0 == "`" || $0 == "-" }) ?? true || type == "true" || type == "false" { return nil }
        }
        if label.count > 36 { label = String(label.prefix(35)) + "…" }
        return label
    }

    /// "3 references" → "3 usages", as WebStorm says it; no "0 implementations".
    nonisolated static func lensText(_ lens: CodeLensInfo) -> String? {
        guard lens.kind == .references else { return lens.title.hasPrefix("0 ") ? nil : lens.title }
        let n = Int(lens.title.prefix { $0.isNumber }) ?? 0
        return n == 0 ? "no usages" : n == 1 ? "1 usage" : "\(n) usages"
    }

    nonisolated static func relativePath(_ url: URL, in root: URL) -> String {
        let r = root.standardizedFileURL.path, p = url.standardizedFileURL.path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
    }

    /// A gutter icon was clicked: one target opens, several show in the usages popover.
    func openJumpTargets(line: Int, url: URL, text: String) {
        guard let mark = jumpTargets[url]?[line] else { return }
        let targets = mark.targets.compactMap(CodeLocation.init)
        if targets.count == 1 { open(targets[0]); return }
        let symbol = Self.word(in: text, line: line, character: Self.firstWordColumn(text, line: line)) ?? "Symbol"
        ReferencesPresenter.shared.show(symbol: symbol, locations: targets, root: root,
                                        noun: mark.kind == .overrides ? "overridden declaration" : "implementation",
                                        textOf: { _ in nil }, open: { [weak self] loc in self?.open(loc) })
    }

    nonisolated static func firstWordColumn(_ text: String, line: Int) -> Int {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard line < lines.count else { return 0 }
        // The declared name: the identifier before the first "(" or ":" or "{", else the first one.
        let s = String(lines[line])
        if let m = s.firstMatch(of: /([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*[(:{]/) {
            return s.utf16.distance(from: s.utf16.startIndex, to: m.1.startIndex.samePosition(in: s.utf16) ?? s.utf16.startIndex)
        }
        return s.utf16.prefix { $0 == 32 || $0 == 9 }.count
    }
}
