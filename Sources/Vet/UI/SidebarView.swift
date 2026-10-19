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
            case .changes: ChangesTool(app: app)
            case .project: ProjectTool(app: app)
            }
        }
        .frame(maxHeight: .infinity)
        // IDE trees want dense rows (Xcode's navigators use the small size too).
        .environment(\.sidebarRowSize, .medium)
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
                Text(review.changes.isEmpty ? "No changes" : "\(review.reviewedCount) of \(review.changes.count) reviewed")
                    .foregroundStyle(.secondary)
                Spacer()
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
        return List(selection: Binding(get: { row ?? review.selectedPath }, set: { path in
            row = path
            if let path, review.changes.contains(where: { $0.path == path }) { app.showDiff(path) }
        })) {
            Section {
                ForEach(CompactChange.compact(all)) { ChangeNodeRow(app: app, item: $0, quickLook: $quickLook) }
            } header: {
                SectionHeader(title: "Changes", nodes: all, app: app)
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
            .padding(.trailing, 8) // the header runs past the rows' inset; line up with the rows
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
                    Label { Text(item.name) } icon: { Image(systemName: "folder.fill").foregroundStyle(Color(nsColor: DiffTheme.folder)) }
                        .lineLimit(1)
                        .opacity(review.stage(of: node) == .staged ? 0.65 : 1) // reviewed names recede
                    Spacer(minLength: 0)
                    ReviewBar(fraction: review.reviewedFraction(node)).alignedToTextBaseline().alignedToTextBaseline()
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
        Button("Unstage") { review.setStaged(node, false) }.disabled(review.stage(of: node) == .unstaged)
        Divider()
        Button("Show in Finder") { if let url = review.url(for: node.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        }
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
                Text(node.name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(change.kind.color))
                    .opacity(review.stage(of: change) == .staged && prominence != .increased ? 0.65 : 1) // reviewed names recede
                if let orig = change.origPath {
                    Text("from \((orig as NSString).lastPathComponent)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            ReviewBar(fraction: review.reviewedFraction(node)).alignedToTextBaseline()
            TriStateCheckbox(state: review.stage(of: node)) { review.setStaged(node, $0) }.alignedToTextBaseline()
        }
        .help(change.kind.help)
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
            .buttonStyle(.borderless)
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
        let key = special[lower] != nil ? lower : ext
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
        return NSImage(size: size, flipped: false) { rect in
            let color = DiffTheme.hex(style.color)
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
