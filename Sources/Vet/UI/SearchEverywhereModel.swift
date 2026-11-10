import AppKit
import SwiftUI
import VetCore

/// Search Everywhere in the toolbar's search field: files, classes and symbols, actions and
/// text, grouped in the field's suggestion list, each group as soon as it's ready (WebStorm's
/// Search Everywhere, as the Mac's own search field).
@MainActor @Observable
final class SearchEverywhereModel {
    private(set) var items: [SearchItem] = []
    @ObservationIgnored weak var app: AppDelegate?
    @ObservationIgnored private var engine: SearchEverywhere?
    @ObservationIgnored private var engineRoot: URL?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// LSP symbol kinds by item id, for the row icons.
    @ObservationIgnored private var symbolKinds: [String: Int] = [:]

    static let order: [SearchItem.Kind] = [.file, .symbol, .action, .text]
    static func title(_ kind: SearchItem.Kind) -> String {
        switch kind {
        case .file: "Files"
        case .symbol: "Classes and Symbols"
        case .action: "Actions"
        case .text: "Text"
        }
    }

    /// The field's text changed: search again, or run the suggestion that was just picked (a
    /// picked suggestion puts its id in the field).
    func update(_ query: String) {
        guard let app else { return }
        if let item = items.first(where: { $0.id == query }) { choose(item); return }
        task?.cancel()
        guard let root = app.workspace.root, !query.trimmingCharacters(in: .whitespaces).isEmpty else { items = []; return }
        if engineRoot != root {
            engine = makeEngine(root)
            engineRoot = root
        }
        guard let stream = engine?.results(for: query) else { return }
        task = Task { [weak self] in
            for await list in stream {
                guard !Task.isCancelled else { break }
                self?.items = list
            }
        }
    }

    // MARK: Recent files

    private struct Recent: Codable, Equatable { var path: String; var diff: Bool }
    /// What you opened last in this project, newest first (shown before you type).
    private var recent: [Recent] = []
    @ObservationIgnored private var recentRoot: URL?

    private func loadRecent() {
        guard let app, app.workspace.root != recentRoot else { return }
        recentRoot = app.workspace.root
        recent = recentRoot.flatMap { try? Data(contentsOf: ProjectFolder.url($0, "recent.json")) }
            .flatMap { try? JSONDecoder().decode([Recent].self, from: $0) } ?? []
    }

    /// A file (or a file's changes) was opened: it goes to the top of the recent list.
    func noteOpened(_ path: String, diff: Bool) {
        loadRecent()
        guard recent.first != Recent(path: path, diff: diff) else { return }
        recent.removeAll { $0.path == path }
        recent.insert(Recent(path: path, diff: diff), at: 0)
        recent = Array(recent.prefix(12))
        // Tests leave no files behind.
        if !SnapshotHook.isTesting, let root = recentRoot, let data = try? JSONEncoder().encode(recent) {
            try? data.write(to: ProjectFolder.url(root, "recent.json"))
        }
    }

    /// The recent files as rows, without the one that's open now: Return goes to the one before.
    var recentItems: [SearchItem] {
        loadRecent()
        guard let app, let root = app.workspace.root else { return [] }
        let open: String? = switch app.ui.location {
        case .diff(let path)?: path
        case .file?: app.workspace.files.relativePath
        default: nil
        }
        return recent.filter { $0.path != open && FileManager.default.fileExists(atPath: root.appendingPathComponent($0.path).path) }.map { r in
            SearchItem(id: "recent:\(r.diff ? "diff" : "file"):\(r.path)", kind: .file, title: (r.path as NSString).lastPathComponent,
                       detail: (r.path as NSString).deletingLastPathComponent, matched: [], target: .file(path: r.path, line: nil))
        }
    }

    func choose(_ item: SearchItem) {
        guard let app else { return }
        task?.cancel()
        items = []
        app.ui.search = ""
        app.ui.focusSearch = false
        // A recent file whose changes you were reading opens as its changes again (while it has any).
        if item.id.hasPrefix("recent:diff:"), case .file(let path, _) = item.target,
           app.workspace.review.changes.contains(where: { $0.path == path }) {
            app.showDiff(path)
            return
        }
        switch item.target {
        case .file(let path, let line):
            if let root = app.workspace.root { app.showFile(root.appendingPathComponent(path), line: line ?? 0) }
        case .location(let url, let line, let character):
            app.showFile(url, line: line, character: character)
        case .action(let id):
            app.runAction(id)
        }
    }

    func symbolKind(_ item: SearchItem) -> Int? { symbolKinds[item.id] }

    @ObservationIgnored private var mainLanguageCache: (count: Int, language: LSPLanguage?)?
    private func mainLanguage(_ paths: [String]) -> LSPLanguage? {
        if let c = mainLanguageCache, c.count == paths.count { return c.language }
        var counts: [LSPLanguage: Int] = [:]
        for p in paths {
            if let l = LSPLanguage(fileExtension: (p as NSString).pathExtension) { counts[l, default: 0] += 1 }
        }
        let best = counts.max { $0.value < $1.value }?.key
        mainLanguageCache = (paths.count, best)
        return best
    }

    private func makeEngine(_ root: URL) -> SearchEverywhere {
        SearchEverywhere(root: root,
                         files: { [weak self] in self?.app?.workspace.files.paths ?? [] },
                         symbols: { [weak self] query in
                             guard let self, let ws = self.app?.workspace, let navigator = ws.navigator else { return [] }
                             // The open file's language, else the project's most common one.
                             let language = ws.files.openURL.flatMap { LSPLanguage(fileExtension: $0.pathExtension) } ?? self.mainLanguage(ws.files.paths)
                             let found = await navigator.workspaceSymbols(matching: query, preferring: language)
                             return found.compactMap { s in
                                 guard let url = LSPURI.url(for: s.location.uri) else { return nil }
                                 let start = s.location.range.start
                                 self.symbolKinds["symbol:\(url.absoluteString)#\(start.line):\(start.character):\(s.name)"] = s.kind
                                 return (s.name, s.containerName, url, start.line, start.character, s.kind)
                             }
                         },
                         actions: { [weak self] in self?.app?.actionList ?? [] })
    }
}

/// The suggestion list under the toolbar's search field.
struct SearchEverywhereSuggestions: View {
    let app: AppDelegate

    var body: some View {
        let model = app.searchEverywhere
        ForEach(SearchEverywhereModel.order, id: \.self) { kind in
            let group = model.items.filter { $0.kind == kind }
            if !group.isEmpty {
                Section(SearchEverywhereModel.title(kind)) {
                    ForEach(group) { item in
                        Label {
                            HStack(spacing: 8) {
                                Text(item.kind == .text ? Self.codeLine(item) : Self.highlighted(item)).lineLimit(1)
                                    .font(item.kind == .text ? .system(size: 12, design: .monospaced) : nil)
                                Text(item.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                        } icon: {
                            icon(item)
                        }
                        .searchCompletion(item.id)
                    }
                }
            }
        }
    }

    @ViewBuilder private func icon(_ item: SearchItem) -> some View {
        switch item.kind {
        case .file:
            Image(nsImage: FileIcons.icon(for: item.title))
        case .symbol:
            Image(systemName: Self.symbol(forKind: app.searchEverywhere.symbolKind(item)))
        case .action:
            Image(systemName: "command")
        case .text:
            Image(systemName: "text.alignleft")
        }
    }

    /// SF Symbols for LSP symbol kinds, letter badges as IDEs show them.
    static func symbol(forKind kind: Int?) -> String {
        switch kind {
        case 5: "c.square"            // class
        case 6, 9: "m.square"         // method, constructor
        case 7, 8: "p.square"         // property, field
        case 10, 22: "e.square"       // enum, enum member
        case 11: "i.square"           // interface
        case 12: "f.square"           // function
        case 13: "v.square"           // variable
        case 14: "k.square"           // constant
        case 23: "s.square"           // struct
        case 26: "t.square"           // type parameter
        default: "curlybraces.square"
        }
    }

    /// A text result: the line in code colors, the match on the search highlight.
    static func codeLine(_ item: SearchItem) -> AttributedString {
        let path = item.detail.split(separator: ":").dropLast().joined(separator: ":")
        return CodeText.line(item.title, language: CodeLanguage(path: path), matches: item.matched.map { $0..<($0 + 1) })
    }

    /// The title with the matched characters in bold.
    static func highlighted(_ item: SearchItem) -> AttributedString {
        guard !item.matched.isEmpty else { return AttributedString(item.title) }
        let utf16 = Array(item.title.utf16)
        let matched = Set(item.matched)
        var out = AttributedString()
        var run: [UInt16] = [], runBold = false
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(String(decoding: run, as: UTF16.self))
            if runBold { piece.inlinePresentationIntent = .stronglyEmphasized }
            out += piece
            run = []
        }
        for (i, u) in utf16.enumerated() {
            let bold = matched.contains(i)
            if bold != runBold { flush(); runBold = bold }
            run.append(u)
        }
        flush()
        return out
    }
}
