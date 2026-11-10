import AppKit
import QuickLook
import UniformTypeIdentifiers
import SwiftUI
import VetCore

/// The glass sidebar: the changes, or the project's files.
struct SidebarView: View {
    let app: AppDelegate

    var body: some View {
        // No tool strip: the changes are the sidebar; the project's files come up with ⌘2.
        Group {
            switch app.ui.tool {
            case .changes:
                if Design.sidebar == .current { ChangesTool(app: app) } else { ChangesVariant(app: app, style: Design.sidebar) }
            case .project: ProjectTool(app: app)
            }
        }
        .frame(maxHeight: .infinity)
        // A quiet grey selection (names keep their colors on it), not the accent blue.
        .tint(Color(white: 0.32))
        // IDE trees want dense rows (Xcode's navigators use the small size too).
        // Dense rows (the small size, as Xcode's navigators) with the regular 13-pt sidebar text:
        // the small size's own text is too small to read comfortably.
        .environment(\.sidebarRowSize, Design.shell == .native ? .small : .medium)
        .font(.system(size: 13))
    }
}

// MARK: Changes

struct ChangesTool: View {
    let app: AppDelegate
    @State private var quickLook: URL?
    /// The highlighted row: a file (its diff is open) or a folder.
    @State private var row: String?

    var body: some View {
        let review = app.workspace.review
        VStack(spacing: 0) {
            ToolHeader {
                // The count is in the window's subtitle; here only the list's own tools.
                Spacer()
                if review.plan != nil {
                    ToolButton(review.followPlan ? "list.number" : "list.bullet.indent", review.followPlan ? "Showing Claude's review order (click for the folder tree)" : "Show Claude's review order") {
                        review.followPlan.toggle()
                    }
                }
                ToolButton("line.3.horizontal.decrease.circle", "Unimportant Files…") { app.ui.editingRules = true }
                // One button that flips between expanding and collapsing everything.
                if review.allExpanded {
                    ToolButton("arrow.down.right.and.arrow.up.left", "Collapse All") { review.collapseAll() }
                } else {
                    ToolButton("arrow.up.left.and.arrow.down.right", "Expand All") { review.expandAll() }
                }
            }
            if app.projects.current == nil {
                EmptyToolState(title: "No Project", message: "Open a project folder to review its changes.") {
                    Button("Open Folder…") { app.projects.showOpenPanel() }
                }
            } else if !review.isGitRepo {
                EmptyToolState(title: "Not a Git Repository", message: "Review needs git. Project, Find and Run still work.") { EmptyView() }
            } else if review.changes.isEmpty {
                EmptyToolState(title: "No Changes", message: "Everything matches the last commit.") { EmptyView() }
            } else {
                changesList
            }
        }
        .quickLookPreview($quickLook)
    }

    private var changesList: some View {
        let review = app.workspace.review
        // New files sit in the same tree as everything else (checking one adds it to git).
        let all = review.tree
        // Claude's review order, when there is one: those files first, numbered, with Claude's
        // summary; whatever else changed follows as the usual tree.
        let planned: [FileTreeNode] = review.followPlan ? (review.plan?.files ?? []).compactMap { f in
            FileTreeNode.find(f.path, in: all).flatMap { $0.isFolder ? nil : $0 }
        } : []
        let plannedPaths = Set(planned.map(\.path))
        let rest = plannedPaths.isEmpty ? all : FileTreeNode.build(review.changes.filter { !plannedPaths.contains($0.path) })
        return List(selection: Binding(get: { row ?? review.selectedPath }, set: { path in
            row = path
            if let path, review.changes.contains(where: { $0.path == path }) { app.showDiff(path) }
        })) {
            if !planned.isEmpty {
                Section {
                    ForEach(Array(planned.enumerated()), id: \.element.path) { i, node in
                        PlanRow(app: app, node: node, index: i + 1, summary: review.plan?.file(node.path)?.summary ?? "")
                            .tag(node.path)
                    }
                } header: {
                    SectionHeader(title: "Review Order", nodes: planned, app: app)
                }
            }
            if !rest.isEmpty {
                Section {
                    ForEach(CompactChange.compact(rest)) { ChangeNodeRow(app: app, item: $0, quickLook: $quickLook) }
                } header: {
                    SectionHeader(title: planned.isEmpty ? "Changes" : "Other Changes", nodes: rest, app: app)
                }
            }
        }
        // Double-click (or Return): a folder opens or closes, a file shows its diff.
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let node = FileTreeNode.find(id, in: review.tree) {
                ChangeMenu(app: app, node: node, quickLook: $quickLook)
            }
        } primaryAction: { ids in
            for id in ids {
                if review.changes.contains(where: { $0.path == id }) { app.showDiff(id) }
                else if review.expanded.contains(id) { review.expanded.remove(id) } else { review.expanded.insert(id) }
            }
        }
        .onChange(of: review.selectedPath) { _, path in row = path }
        // The order the rows appear in: ⌘↩ moves through files in it.
        .onAppear { review.sidebarOrder = planned.map(\.path) + FileTreeNode.filesInOrder(rest).map(\.path) }
        .onChange(of: planned.map(\.path) + FileTreeNode.filesInOrder(rest).map(\.path)) { _, o in review.sidebarOrder = o }
        // Rebuilt lists never animate row moves: AppKit's outline view leaves moved rows drawn
        // over each other when a refresh reorders them mid-animation.
        .transaction { $0.disablesAnimations = true; $0.animation = nil }
        // Space approves the change in view and moves on, as in the diff.
        .onKeyPress(.space) { review.approveAndNext(); return .handled }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

private struct SectionHeader: View {
    let title: String
    let nodes: [FileTreeNode]
    let app: AppDelegate

    static func fraction(_ nodes: [FileTreeNode], _ review: ReviewModel) -> Double? {
        let parts = nodes.compactMap { review.reviewedFraction($0) }
        return parts.isEmpty ? nil : parts.reduce(0, +) / Double(parts.count)
    }
    var body: some View {
        let review = app.workspace.review
        let files = nodes.flatMap(\.fileChanges)
        let states = Set(files.map { review.stage(of: $0) })
        HStack(spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(files.count)").font(.subheadline).foregroundStyle(.tertiary).monospacedDigit()
            Spacer()
            TriStateCheckbox(state: states == [.staged] ? .staged : states == [.unstaged] ? .unstaged : .partial) { on in
                for n in nodes { review.setStaged(n, on) }
            }
            .alignedToTextBaseline()
            .padding(.trailing, 14) // same column as the rows' rings
        }
    }
}

/// A row of the changes outline: a file, or a folder with single-folder chains joined
/// ("src/app/layers"), as WebStorm and VS Code show them.
struct CompactChange: Identifiable {
    let name: String
    let node: FileTreeNode
    let children: [CompactChange]
    var id: String { node.path }

    @MainActor static func compact(_ nodes: [FileTreeNode]) -> [CompactChange] {
        nodes.map { n in
            var cur = n, name = n.name
            while cur.isFolder, cur.children.count == 1, cur.children[0].isFolder {
                cur = cur.children[0]
                name += "/" + cur.name
            }
            return CompactChange(name: name, node: cur, children: cur.isFolder ? compact(cur.children) : [])
        }
    }
}

/// One folder or file of the changes outline (recursive).
struct ChangeNodeRow: View {
    let app: AppDelegate
    let item: CompactChange
    @Binding var quickLook: URL?
    private var node: FileTreeNode { item.node }

    var body: some View {
        let review = app.workspace.review
        if node.isFolder {
            DisclosureGroup(isExpanded: Binding(
                get: { review.expanded.contains(node.path) },
                set: { if $0 { review.expanded.insert(node.path) } else { review.expanded.remove(node.path) } })) {
                ForEach(item.children) { ChangeNodeRow(app: app, item: $0, quickLook: $quickLook) }
            } label: {
                HStack(spacing: 6) {
                    Label { Text(item.name) } icon: { Image(systemName: "folder.fill").foregroundStyle(Design.accentFolders ? Color.accentColor : Color(nsColor: DiffTheme.folder)) }
                        .lineLimit(1)
                        .opacity(review.stage(of: node) == .staged ? 0.65 : 1) // reviewed names recede
                    Spacer(minLength: 0)
                    TriStateCheckbox(state: review.stage(of: node)) { review.setStaged(node, $0) }.alignedToTextBaseline()
                }
            }
            .tag(node.path)
            .listRowBackground(review.isMarked(node.path) ? Color.primary.opacity(0.04) : nil)
        } else {
            FileChangeLabel(app: app, node: node)
                .tag(node.path)
                // Clicking the selected file again brings its diff back (e.g. from the browser).
                .simultaneousGesture(TapGesture().onEnded { app.showDiff(node.path) })
                .listRowBackground(review.isMarked(node.path) ? Color.primary.opacity(0.04) : nil)
        }
    }
}

/// A changed file's or folder's menu (right-click in the changes tree).
struct ChangeMenu: View {
    let app: AppDelegate
    let node: FileTreeNode
    @Binding var quickLook: URL?

    var body: some View {
        let review = app.workspace.review
        if !node.isFolder {
            Button("Open in Editor") { if let url = review.url(for: node.path) { app.showFile(url) } }
            Button("Quick Look") { quickLook = review.url(for: node.path) }
            Divider()
        }
        Button(review.isDirectlyMarked(node.path) ? "Remove Unimportant Mark" : "Mark as Unimportant") { review.toggleMark(node) }
            .disabled(!review.isDirectlyMarked(node.path) && review.isMarked(node.path))
        Button("Mark as Reviewed") { review.setStaged(node, true) }.disabled(review.stage(of: node) == .staged)
        Button("Mark as Not Reviewed") { review.setStaged(node, false) }.disabled(review.stage(of: node) == .unstaged)
        Divider()
        Button("Show in Finder") { if let url = review.url(for: node.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        }
    }
}

/// A file in Claude's review order: its number, name, folder, and Claude's one-line summary.
private struct PlanRow: View {
    let app: AppDelegate
    let node: FileTreeNode
    let index: Int
    let summary: String
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let review = app.workspace.review
        let change = node.change!
        let reviewed = review.stage(of: change) == .staged
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index)").font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(.tertiary).frame(minWidth: 14, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(nsImage: FileIcons.icon(for: node.name)).resizable().frame(width: 16, height: 16)
                    ChangeName(name: node.name, kind: change.kind, selected: review.selectedPath == node.path)
                }
            }
            .opacity(reviewed && review.selectedPath != node.path ? 0.65 : 1)
            Spacer(minLength: 4)
            TriStateCheckbox(state: review.stage(of: node)) { review.setStaged(node, $0) }.alignedToTextBaseline()
        }
        .help(summary.isEmpty ? node.path : summary)
    }
}

private struct FileChangeLabel: View {
    let app: AppDelegate
    let node: FileTreeNode
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let review = app.workspace.review
        let change = node.change!
        HStack(spacing: 6) {
            Image(nsImage: FileIcons.icon(for: node.name)).resizable().frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                ChangeName(name: node.name, kind: change.kind, selected: review.selectedPath == node.path)
                    .opacity(review.stage(of: change) == .staged && review.selectedPath != node.path ? 0.6 : 1) // reviewed names recede
                if let orig = change.origPath {
                    Text("from \((orig as NSString).lastPathComponent)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            TriStateCheckbox(state: review.stage(of: node)) { review.setStaged(node, $0) }.alignedToTextBaseline()
        }
        .help(change.kind.help)
    }
}

/// A changed file's name. Its status shows by the design: a colored name, a small colored dot
/// after a plain name, or a quiet glyph. On a selected row the name is always plain, so colored
/// text never sits on the selection highlight.
struct ChangeName: View {
    let name: String
    let kind: ChangeKind?
    var selected = false
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        // The selection is a quiet grey, so names keep their color on it.
        let onHighlight = false
        HStack(spacing: 6) {
            Text(name).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(Design.names == .colored && !onHighlight ? (kind.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.primary)) : AnyShapeStyle(.primary))
            if let kind {
                switch Design.names {
                case .dot:
                    Circle().fill(onHighlight ? AnyShapeStyle(.primary.opacity(0.8)) : AnyShapeStyle(kind.color)).frame(width: 6, height: 6)
                        .help(kind.help)
                case .glyph:
                    if let g = kind.glyph {
                        Image(systemName: g).font(.system(size: 9, weight: .bold)).foregroundStyle(onHighlight ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            .help(kind.help)
                    }
                case .colored: EmptyView()
                }
            }
        }
    }
}

extension ChangeKind {
    /// A quiet status glyph (none for an ordinary edit).
    var glyph: String? {
        switch self {
        case .added, .untracked: "plus"
        case .deleted: "minus"
        case .renamed: "arrow.right"
        case .conflicted: "exclamationmark"
        case .modified: nil
        }
    }
}

/// How much of a file is reviewed: a short capsule that fills green.
struct ReviewBar: View {
    let fraction: Double?
    var body: some View {
        if let fraction {
            Capsule().fill(Color(nsColor: DiffTheme.foldPillBorder))
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(Color(nsColor: DiffTheme.added)).frame(width: max(fraction > 0 ? 4 : 0, g.size.width * fraction))
                    }
                }
                .frame(width: 26, height: 4)
                .help(fraction >= 1 ? "Reviewed" : fraction <= 0 ? "Not reviewed yet" : "\(Int(fraction * 100))% reviewed")
        }
    }
}

// MARK: Shared bits

/// A thin row of a tool's own actions, right under the tool picker.
struct ToolHeader<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 2) { content }
            .font(.callout)
            .buttonStyle(.hand)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 26)
    }
}

struct ToolButton: View {
    let symbol: String, help: String, action: () -> Void
    init(_ symbol: String, _ help: String, action: @escaping () -> Void) { self.symbol = symbol; self.help = help; self.action = action }
    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 20) }.help(help)
    }
}

struct EmptyToolState<Actions: View>: View {
    let title: String, message: String
    @ViewBuilder let actions: Actions
    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            actions.padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    /// A file's icon, in the spirit of VS Code's Material icon theme: a small colored badge with
    /// the language's mark (TS, JS, {}, #…), or a symbol for images and plain files. Cached.
    static func icon(for name: String) -> NSImage {
        let lower = (name as NSString).lastPathComponent.lowercased()
        let ext = (lower as NSString).pathExtension
        let key = (special[lower] != nil ? lower : ext) + (Design.monoIcons ? "#mono" : "") + "#" + Design.fileIcon.rawValue
        if let i = cache[key] { return i }
        let style = special[lower] ?? styles[ext] ?? Style(mark: nil, symbol: "doc.text", color: 0x8A93A6)
        let i = draw(style)
        cache[key] = i
        return i
    }

    struct Style { let mark: String?; let symbol: String?; let color: UInt32 }
    private static let styles: [String: Style] = [
        "ts": .init(mark: "TS", symbol: nil, color: 0x3178C6), "tsx": .init(mark: "TS", symbol: nil, color: 0x3178C6),
        "js": .init(mark: "JS", symbol: nil, color: 0xE8C730), "jsx": .init(mark: "JS", symbol: nil, color: 0xE8C730),
        "mjs": .init(mark: "JS", symbol: nil, color: 0xE8C730), "cjs": .init(mark: "JS", symbol: nil, color: 0xE8C730),
        "json": .init(mark: "{}", symbol: nil, color: 0xD9A13B), "jsonc": .init(mark: "{}", symbol: nil, color: 0xD9A13B),
        "html": .init(mark: "<>", symbol: nil, color: 0xE44D26), "css": .init(mark: "#", symbol: nil, color: 0x42A5F5),
        "scss": .init(mark: "#", symbol: nil, color: 0xCD6799), "less": .init(mark: "#", symbol: nil, color: 0x5C8DBF),
        "md": .init(mark: "M", symbol: nil, color: 0x5C8DBF), "py": .init(mark: "Py", symbol: nil, color: 0x3C78AA),
        "kt": .init(mark: "K", symbol: nil, color: 0xA97BFF), "kts": .init(mark: "K", symbol: nil, color: 0xA97BFF),
        "swift": .init(mark: nil, symbol: "swift", color: 0xF05138), "java": .init(mark: "J", symbol: nil, color: 0xE76F00),
        "go": .init(mark: "Go", symbol: nil, color: 0x00ADD8), "rs": .init(mark: "Rs", symbol: nil, color: 0xDEA584),
        "sh": .init(mark: nil, symbol: "terminal", color: 0x4CAF50), "zsh": .init(mark: nil, symbol: "terminal", color: 0x4CAF50),
        "yml": .init(mark: "Y", symbol: nil, color: 0xCB4B4B), "yaml": .init(mark: "Y", symbol: nil, color: 0xCB4B4B),
        "xml": .init(mark: "<>", symbol: nil, color: 0x8BC34A), "svg": .init(mark: nil, symbol: "scribble", color: 0xFFB13B),
        "png": .init(mark: nil, symbol: "photo", color: 0x26A69A), "jpg": .init(mark: nil, symbol: "photo", color: 0x26A69A),
        "jpeg": .init(mark: nil, symbol: "photo", color: 0x26A69A), "gif": .init(mark: nil, symbol: "photo", color: 0x26A69A),
        "webp": .init(mark: nil, symbol: "photo", color: 0x26A69A), "ico": .init(mark: nil, symbol: "photo", color: 0x26A69A),
        "txt": .init(mark: nil, symbol: "doc.text", color: 0x8A93A6), "lock": .init(mark: nil, symbol: "lock", color: 0x8A93A6),
        "sql": .init(mark: nil, symbol: "cylinder", color: 0xE38C00), "ps1": .init(mark: nil, symbol: "terminal", color: 0x5391FE),
    ]
    private static let special: [String: Style] = [
        "package.json": .init(mark: nil, symbol: "shippingbox", color: 0x8BC34A),
        "package-lock.json": .init(mark: nil, symbol: "lock", color: 0x8BC34A),
        ".gitignore": .init(mark: nil, symbol: "eye.slash", color: 0xF4511E),
        ".gitattributes": .init(mark: nil, symbol: "arrow.triangle.branch", color: 0xF4511E),
        "dockerfile": .init(mark: nil, symbol: "shippingbox.fill", color: 0x2496ED),
        "readme.md": .init(mark: nil, symbol: "info.circle.fill", color: 0x42A5F5),
        "claude.md": .init(mark: nil, symbol: "sparkle", color: 0xD97757),
        "agents.md": .init(mark: nil, symbol: "sparkle", color: 0xD97757),
    ]

    private static func draw(_ style: Style) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let variant = Design.fileIcon
        return NSImage(size: size, flipped: false) { rect in
            let color = Design.monoIcons ? NSColor.secondaryLabelColor : DiffTheme.hex(style.color)
            switch variant {
            case .badge: break
            case .dot:
                // Only the language's color, as a small dot.
                color.withAlphaComponent(0.9).setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.midX - 3, y: rect.midY - 3, width: 6, height: 6)).fill()
                return true
            case .letters:
                // The mark (or symbol) alone in the language's color: no badge behind it.
                if let mark = style.mark {
                    let font = NSFont.systemFont(ofSize: mark.count > 1 ? 8.5 : 10, weight: .bold)
                    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                    let t = mark as NSString, ts = t.size(withAttributes: attrs)
                    t.draw(at: NSPoint(x: rect.midX - ts.width / 2, y: rect.midY - ts.height / 2 + 0.3), withAttributes: attrs)
                    return true
                }
            case .glyph:
                // One thin grey symbol per kind of file, as Finder and Xcode keep it.
                let symbol = style.mark == nil ? (style.symbol ?? "doc") : ["{}": "curlybraces", "#": "number", "M": "doc.plaintext", "<>": "chevron.left.forwardslash.chevron.right"][style.mark!] ?? "doc.text"
                if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [NSColor.secondaryLabelColor]))) {
                    let s = image.size
                    image.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
                }
                return true
            }
            if let mark = style.mark {
                // A rounded badge in the language color with its mark in white.
                let badge = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1.5), xRadius: 3.5, yRadius: 3.5)
                color.setFill()
                badge.fill()
                let font = NSFont.systemFont(ofSize: mark.count > 1 ? 7.5 : 9, weight: .heavy)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
                let t = mark as NSString, ts = t.size(withAttributes: attrs)
                t.draw(at: NSPoint(x: rect.midX - ts.width / 2, y: rect.midY - ts.height / 2 + 0.3), withAttributes: attrs)
            } else if let symbol = style.symbol,
                      let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [color]))) {
                let s = image.size
                image.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
    }
}

extension ChangeKind {
    var letter: String {
        switch self {
        case .modified: "M"
        case .added, .untracked: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .conflicted: "!"
        }
    }
    /// IntelliJ's file-status color (names and letters in the trees).
    var color: Color { Color(nsColor: DiffTheme.fileStatus(self)) }
    var help: String {
        switch self {
        case .added: "Added"
        case .untracked: "New, not in git yet"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .conflicted: "Merge conflict"
        default: "Modified"
        }
    }
}
