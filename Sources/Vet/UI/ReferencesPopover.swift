import AppKit
import SwiftUI
import VetCore

/// Where the last navigation started (the clicked symbol), so its result can point back at it.
@MainActor
enum NavigationAnchor {
    private(set) static weak var view: NSView?
    private(set) static var rect: NSRect = .zero
    static func set(_ view: NSView, _ rect: NSRect) { self.view = view; self.rect = rect }
}

/// Find Usages: a popover over the symbol, like VS Code's references window — the matches grouped
/// by file on the right, the selected match in its file on the left. Drag it away to keep it as
/// a floating panel (a Mac popover can be detached). Esc closes it; Return or a double-click opens
/// the selected match.
@MainActor
final class ReferencesPresenter: NSObject, NSPopoverDelegate {
    static let shared = ReferencesPresenter()
    private var popover: NSPopover?

    /// Semantic tokens for previews (set by the workspace).
    var tokens: ((URL, String) async -> [SemanticToken])?

    private var loading: NSPopover?
    private var pendingLoading: DispatchWorkItem?

    /// A lookup started at the symbol: if it takes more than a moment, a small popover there says
    /// so (like VS Code's peek while it loads), until the results replace it or `endLoading` ends it.
    func beginLoading(_ text: String) {
        endLoading()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.presentLoading(text) } }
        pendingLoading = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func endLoading() {
        pendingLoading?.cancel()
        pendingLoading = nil
        loading?.close()
        loading = nil
    }

    private func presentLoading(_ text: String) {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        let host = NSHostingController(rootView:
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text(text).foregroundStyle(.secondary) }
                .font(.callout)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .fixedSize())
        p.contentViewController = host
        loading = p
        if let view = NavigationAnchor.view, view.window != nil {
            p.show(relativeTo: NavigationAnchor.rect, of: view, preferredEdge: .maxY)
        }
    }

    func show(symbol: String, locations: [CodeLocation], root: URL?, noun: String = "usage", textOf: @escaping (URL) -> String?,
              open: @escaping (CodeLocation) -> Void) {
        endLoading()
        popover?.close()
        let model = ReferencesModel(symbol: symbol, locations: locations, root: root, textOf: textOf)
        model.noun = noun
        model.tokens = tokens
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.delegate = self
        let host = NSHostingController(rootView: ReferencesView(model: model, open: { [weak p] loc in
            p?.close()
            open(loc)
        }))
        host.sizingOptions = []
        host.view.frame = NSRect(x: 0, y: 0, width: 600, height: 470)
        p.contentViewController = host
        p.contentSize = NSSize(width: 600, height: 470)
        popover = p
        if let view = NavigationAnchor.view, view.window != nil {
            p.show(relativeTo: NavigationAnchor.rect, of: view, preferredEdge: .maxY)
        } else if let content = NSApp.keyWindow?.contentView {
            p.show(relativeTo: NSRect(x: content.bounds.midX, y: content.bounds.maxY - 80, width: 1, height: 1), of: content, preferredEdge: .minY)
        }
    }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }
    func popoverDidClose(_ notification: Notification) { popover = nil }
}

@MainActor @Observable
final class ReferencesModel {
    struct Hit: Identifiable, Hashable {
        let id: String
        let location: CodeLocation
        let lineText: String
        let column: Range<Int> // the symbol in lineText (UTF-16)
    }
    struct File: Identifiable {
        let id: URL
        let name: String
        let folder: String
        var hits: [Hit]
    }

    let symbol: String
    /// The language server's semantic tokens for a file's text (the preview's name colors).
    var tokens: ((URL, String) async -> [SemanticToken])?
    /// What the matches are ("usage", "implementation"), for the header.
    var noun = "usage"
    let files: [File]
    var selection: String?
    private let textOf: (URL) -> String?
    private var cache: [URL: TextLines] = [:]

    init(symbol: String, locations: [CodeLocation], root: URL?, textOf: @escaping (URL) -> String?) {
        self.symbol = symbol
        self.textOf = textOf
        var byFile: [URL: [CodeLocation]] = [:]
        var order: [URL] = []
        for loc in locations {
            if byFile[loc.url] == nil { order.append(loc.url) }
            byFile[loc.url, default: []].append(loc)
        }
        let rootPath = root?.standardizedFileURL.path ?? ""
        var files: [File] = []
        var seen = Set<String>()
        for url in order {
            let text = textOf(url) ?? (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let lines = text.components(separatedBy: "\n")
            let hits = byFile[url, default: []].sorted { ($0.startLine, $0.startCharacter) < ($1.startLine, $1.startCharacter) }.compactMap { loc -> Hit? in
                let id = "\(url.path):\(loc.startLine):\(loc.startCharacter)"
                guard seen.insert(id).inserted else { return nil }
                let raw = loc.startLine < lines.count ? lines[loc.startLine] : ""
                let indent = raw.utf16.prefix { $0 == 32 || $0 == 9 }.count
                let shown = String(raw.dropFirst(raw.prefix { $0 == " " || $0 == "\t" }.count))
                let lo = max(0, loc.startCharacter - indent)
                let hi = loc.endLine == loc.startLine ? max(lo, loc.endCharacter - indent) : lo + symbol.utf16.count
                return Hit(id: id, location: loc, lineText: shown, column: lo..<hi)
            }
            let path = url.standardizedFileURL.path
            let rel = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
            files.append(File(id: url, name: url.lastPathComponent, folder: (rel as NSString).deletingLastPathComponent, hits: hits))
        }
        self.files = files
        selection = files.first?.hits.first?.id
    }

    var count: Int { files.reduce(0) { $0 + $1.hits.count } }
    var selectedHit: Hit? { files.lazy.flatMap(\.hits).first { $0.id == self.selection } }

    func lines(of url: URL) -> TextLines {
        if let l = cache[url] { return l }
        let text = textOf(url) ?? (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let l = TextLines(Data(text.utf8))
        cache[url] = l
        return l
    }

    /// Up/down through every match across files.
    func move(_ delta: Int) {
        let all = files.flatMap(\.hits)
        guard let i = all.firstIndex(where: { $0.id == selection }) else { selection = all.first?.id; return }
        selection = all[max(0, min(all.count - 1, i + delta))].id
    }
}

struct ReferencesView: View {
    @Bindable var model: ReferencesModel
    let open: (CodeLocation) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(model.symbol).font(.system(.body, design: .monospaced)).fontWeight(.semibold)
                Text("\(model.count) \(model.noun)\(model.count == 1 ? "" : "s") in \(model.files.count) file\(model.files.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Spacer()
                if let hit = model.selectedHit {
                    Button("Open") { open(hit.location) }.keyboardShortcut(.defaultAction).buttonStyle(PanelButtonStyle())
                }
            }
            .font(.callout)
            .padding(.leading, 16).padding(.trailing, 10)
            .frame(height: 44)
            // The matches, grouped by file: the same rows as Search Everywhere.
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.files) { file in
                        HStack(spacing: 6) {
                            Image(nsImage: FileIcons.icon(for: file.name)).resizable().frame(width: 14, height: 14)
                            Text(file.name).fontWeight(.medium)
                            Text(file.folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Text("\(file.hits.count)").foregroundStyle(.tertiary).monospacedDigit()
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                        ForEach(file.hits) { hit in
                            HitRow(hit: hit)
                                .id(hit.id)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: Glass.panelRadius - 6, style: .continuous).fill(model.selection == hit.id ? Glass.fillStrong : Color.clear))
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { open(hit.location) }
                                .simultaneousGesture(TapGesture().onEnded { model.selection = hit.id })
                        }
                    }
                }
                .padding([.horizontal, .bottom], 6)
            }
            .onChange(of: model.selection) { _, id in if let id { withAnimation(Motion.quick) { proxy.scrollTo(id) } } }
            }
            .frame(maxHeight: 190)
            // The selected match in its file.
            Group {
                if let hit = model.selectedHit {
                    ReferencePreview(lines: model.lines(of: hit.location.url), url: hit.location.url, line: hit.location.startLine,
                                     columns: hit.column, tokens: model.tokens)
                } else { Color.clear }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Glass.fill)
            .clipShape(RoundedRectangle(cornerRadius: Glass.panelRadius - 6, style: .continuous))
            .padding([.horizontal, .bottom], 6)
        }
        .tint(Color(nsColor: DiffTheme.accent))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
    }
}

private struct HitRow: View {
    let hit: ReferencesModel.Hit
    var body: some View {
        HStack(spacing: 8) {
            Text("\(hit.location.startLine + 1)").font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Color(nsColor: DiffTheme.foldLabel)).frame(minWidth: 26, alignment: .trailing)
            Text(attributed).font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
        }
    }
    /// The line in code colors, the symbol on the search highlight.
    private var attributed: AttributedString {
        let text = hit.lineText
        let u = Array(text.utf16)
        let indent = u.prefix { $0 == 32 || $0 == 9 }.count
        let cut = hit.column.lowerBound - indent > 40 ? hit.column.lowerBound - 16 : indent
        return CodeText.line(text, language: CodeLanguage(path: hit.location.url.path), matches: [hit.column], from: cut, ellipsis: cut > indent)
    }
}

/// The selected match's file in a read-only editor (line numbers, sticky lines, the server's name
/// colors), the match's line banded a third of the way down and the symbol highlighted.
struct ReferencePreview: NSViewRepresentable {
    let lines: TextLines
    let url: URL
    let line: Int
    let columns: Range<Int>
    let tokens: ((URL, String) async -> [SemanticToken])?

    final class Coordinator { var shownURL: URL?; var shownLine = -1 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CodeEditorView {
        let v = CodeEditorView()
        v.readOnly = true
        return v
    }

    func updateNSView(_ v: CodeEditorView, context: Context) {
        let c = context.coordinator
        if c.shownURL != url {
            c.shownURL = url
            c.shownLine = -1
            v.load(lines, language: CodeLanguage(path: url.path), force: true)
            if let tokens {
                let text = v.currentText, url = url
                Task { @MainActor [weak v] in
                    let found = await tokens(url, text)
                    guard let v, v.currentText == text else { return }
                    v.pane.applySemanticTokens(found, display: { $0 })
                }
            }
        }
        if c.shownLine != line {
            c.shownLine = line
            let line = line, columns = columns
            // After layout, so the line can sit a third of the way down.
            DispatchQueue.main.async { [weak v] in v?.reveal(line: line, columns: columns) }
        }
    }
}
