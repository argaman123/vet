import AppKit
import SwiftUI
import VetCore

/// Find in Files: searches the project as you type (git grep), results stream in grouped by file.
@MainActor @Observable
final class FindModel {
    var query = "" { didSet { if oldValue != query { schedule() } } }
    var caseSensitive = false { didSet { if oldValue != caseSensitive { schedule(.zero) } } }
    var wholeWord = false { didSet { if oldValue != wholeWord { schedule(.zero) } } }
    var regex = false { didSet { if oldValue != regex { schedule(.zero) } } }

    struct FileGroup: Identifiable {
        let id: String // repo-relative path
        var matches: [FindMatch]
    }
    private(set) var groups: [FileGroup] = []
    private(set) var count = 0
    private(set) var running = false
    private(set) var error: String?
    /// Results stopped at the limit.
    private(set) var limited = false
    var collapsed: Set<String> = []
    var selection: String?

    @ObservationIgnored weak var app: AppDelegate?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var index: [String: Int] = [:]
    static let limit = 2000

    func reset() {
        task?.cancel()
        debounce?.cancel()
        groups = []; index = [:]; count = 0; running = false; error = nil; limited = false; collapsed = []; selection = nil
    }

    private func schedule(_ delay: Duration = .milliseconds(200)) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            self?.run()
        }
    }

    func run() {
        task?.cancel()
        groups = []; index = [:]; count = 0; error = nil; limited = false; selection = nil; fileCache = [:]
        guard let root = app?.workspace.root, !query.isEmpty else { running = false; return }
        running = true
        let stream = TextSearch(root: root).search(FindQuery(text: query, caseSensitive: caseSensitive, wholeWord: wholeWord, regex: regex), limit: Self.limit)
        task = Task { [weak self] in
            do {
                for try await batch in stream {
                    guard !Task.isCancelled else { return }
                    self?.append(batch)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.error = (error as? FindError)?.description ?? "\(error)"
            }
            guard !Task.isCancelled, let self else { return }
            self.running = false
            self.limited = self.count >= Self.limit
        }
    }

    private func append(_ batch: [FindMatch]) {
        for m in batch {
            if let i = index[m.path] { groups[i].matches.append(m) }
            else { index[m.path] = groups.count; groups.append(FileGroup(id: m.path, matches: [m])) }
        }
        count += batch.count
        if selection == nil, let first = groups.first?.matches.first { selection = Self.id(first) }
    }

    static func id(_ m: FindMatch) -> String { "\(m.path):\(m.line):\(m.previewStart)" }

    /// The selected match (shown in the preview).
    var selectedMatch: FindMatch? {
        guard let selection else { return nil }
        for g in groups { if let m = g.matches.first(where: { Self.id($0) == selection }) { return m } }
        return nil
    }

    /// Up/down through every match across files.
    func move(_ delta: Int) {
        let all = groups.flatMap(\.matches).map(Self.id)
        guard let i = selection.flatMap({ all.firstIndex(of: $0) }) else { selection = all.first; return }
        selection = all[max(0, min(all.count - 1, i + delta))]
    }

    /// Opens the selected match in the editor.
    func openSelected() {
        guard let m = selectedMatch, let app, let root = app.workspace.root else { return }
        FindPresenter.shared.close()
        app.showFile(root.appendingPathComponent(m.path), line: m.line - 1, character: m.column)
    }

    @ObservationIgnored private var fileCache: [String: TextLines] = [:]
    func lines(of path: String) -> TextLines {
        if let l = fileCache[path] { return l }
        let url = app?.workspace.root?.appendingPathComponent(path)
        let l = TextLines(url.flatMap { try? Data(contentsOf: $0) } ?? Data())
        fileCache[path] = l
        return l
    }
}

/// Find in Files as a popup window over the main window (⇧⌘F), like IntelliJ's: the query and its
/// options on top, matches grouped by file, the selected one in a preview below. Return or a
/// double-click opens it; drag the popup away to keep it as a floating panel.
@MainActor
final class FindPresenter: NSObject, NSPopoverDelegate {
    static let shared = FindPresenter()
    private var popover: NSPopover?

    func show(app: AppDelegate) {
        if let popover, popover.isShown { popover.contentViewController?.view.window?.makeKey(); return }
        guard let content = NSApp.mainWindow?.contentView ?? NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 })?.contentView else { return }
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        let host = NSHostingController(rootView: FindPopup(app: app))
        host.sizingOptions = []
        host.view.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        p.contentViewController = host
        p.contentSize = NSSize(width: 900, height: 620)
        popover = p
        // Under the toolbar, centered over the main area.
        let anchor = NSRect(x: content.bounds.midX + 140, y: content.bounds.maxY - 58, width: 1, height: 1)
        p.show(relativeTo: anchor, of: content, preferredEdge: .minY)
    }

    func close() { popover?.close() }
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }
    func popoverDidClose(_ notification: Notification) { popover = nil }
}

struct FindPopup: View {
    let app: AppDelegate
    @FocusState private var focused: Bool

    var body: some View {
        let find = app.find
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in Files", text: Bindable(find).query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { find.openSelected() }
                Group {
                    Toggle(isOn: Bindable(find).caseSensitive) { Text("Aa") }
                        .help("Match Case").accessibilityLabel("Match Case")
                    Toggle(isOn: Bindable(find).wholeWord) { Text("W") }
                        .help("Words").accessibilityLabel("Words")
                    Toggle(isOn: Bindable(find).regex) { Text(".*") }
                        .help("Regex").accessibilityLabel("Regex")
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .toggleStyle(.button)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            Divider()
            HStack {
                if let error = find.error {
                    Text(error).foregroundStyle(.red).lineLimit(1)
                } else {
                    Text(find.query.isEmpty ? "Type to search the project" : summary(find)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if find.running { ProgressView().controlSize(.mini) }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .frame(height: 24)
            VSplitView {
                List(selection: Bindable(find).selection) {
                    ForEach(find.groups) { group in
                        DisclosureGroup(isExpanded: Binding(get: { !find.collapsed.contains(group.id) },
                                                            set: { if $0 { find.collapsed.remove(group.id) } else { find.collapsed.insert(group.id) } })) {
                            ForEach(group.matches, id: \.self) { m in
                                MatchRow(match: m).tag(FindModel.id(m))
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { find.selection = FindModel.id(m); find.openSelected() })
                            }
                        } label: {
                            FileGroupLabel(path: group.id, count: group.matches.count,
                                           kind: app.workspace.review.changes.first { $0.path == group.id }?.kind)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .environment(\.sidebarRowSize, .small)
                .frame(minHeight: 160, idealHeight: 260)
                Group {
                    if let m = find.selectedMatch, let root = app.workspace.root {
                        ReferencePreview(lines: find.lines(of: m.path), url: root.appendingPathComponent(m.path), line: m.line - 1,
                                         columns: m.column..<(m.column + (m.ranges.first?.count ?? 0)), tokens: ReferencesPresenter.shared.tokens)
                    } else {
                        Color(nsColor: DiffTheme.background)
                    }
                }
                .frame(minHeight: 160, idealHeight: 300)
            }
        }
        .tint(Color(nsColor: DiffTheme.accent)) // the popover's own glass, like the sidebar
        .onAppear { focused = true }
        .onKeyPress(.upArrow) { find.move(-1); return .handled }
        .onKeyPress(.downArrow) { find.move(1); return .handled }
        .onExitCommand { FindPresenter.shared.close() }
    }

    private func summary(_ find: FindModel) -> String {
        let files = find.groups.count
        if find.running && find.count == 0 { return "Searching…" }
        if find.count == 0 { return "No matches" }
        let more = find.limited ? "+" : ""
        return "\(find.count)\(more) match\(find.count == 1 ? "" : "es") in \(files) file\(files == 1 ? "" : "s")"
    }
}

private struct FileGroupLabel: View {
    let path: String, count: Int
    var kind: ChangeKind?
    var body: some View {
        let name = (path as NSString).lastPathComponent, folder = (path as NSString).deletingLastPathComponent
        HStack(spacing: 6) {
            Image(nsImage: FileIcons.icon(for: name)).resizable().frame(width: 16, height: 16)
            Text(name).lineLimit(1).foregroundStyle(kind.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.primary))
            Text(folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .help(path)
    }
}

private struct MatchRow: View {
    let match: FindMatch
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(match.line)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(minWidth: 24, alignment: .trailing)
            Text(Self.preview(match)).font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
        }
    }

    /// The line in code colors without its indentation, the matches on the search highlight; a
    /// match far along the line is brought into view (the text before it cut to a few characters).
    static func preview(_ m: FindMatch) -> AttributedString {
        let utf16 = Array(m.preview.utf16)
        let indent = utf16.prefix { $0 == 32 || $0 == 9 }.count
        var from = indent
        if let first = m.ranges.map(\.lowerBound).min(), first - indent > 22 { from = first - 10 }
        return CodeText.line(m.preview, language: CodeLanguage(path: m.path), matches: m.ranges, from: from, ellipsis: from > indent)
    }
}
