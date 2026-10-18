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
        .environment(\.sidebarRowSize, .small)
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
            ClaudeLinkRow(app: app)
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
        .listStyle(.sidebar)
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
            TriStateCheckbox(state: states == [.staged] ? .staged : states == [.unstaged] ? .unstaged : .partial) { on in
                for n in nodes { review.setStaged(n, on) }
            }
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text("\(files.count)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                .padding(.trailing, 8) // the header runs past the rows' inset; keep the count inside
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
                    TriStateCheckbox(state: review.stage(of: node)) { review.setStaged(node, $0) }
                    Label(item.name, systemImage: "folder")
                        .lineLimit(1)
                        .opacity(review.stage(of: node) == .staged ? 0.65 : 1) // reviewed names recede
                    Spacer(minLength: 0)
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
        Button(node.isFolder ? "Ask Claude About This Folder" : "Ask Claude About This File") { review.askClaude(aboutFile: node.path) }
        Divider()
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
            TriStateCheckbox(state: review.stage(of: node)) { review.setStaged(node, $0) }
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
        }
        .help(change.kind.help)
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

/// Whether drafts reach Claude; installs the Claude Code mod on request.
struct ClaudeLinkRow: View {
    let app: AppDelegate
    @State private var installing = false
    @State private var installMessage: String?

    var body: some View {
        let link = app.workspace.link, review = app.workspace.review
        let notes = review.unsentNotes.count
        if !link.connected || notes > 0 {
            HStack(spacing: 6) {
                Circle().fill(link.connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                Text(link.connected ? "Claude linked" : "Claude not linked").foregroundStyle(.secondary)
                Spacer()
                if notes > 0 {
                    Button("Send \(notes) Note\(notes == 1 ? "" : "s")") { review.sendNotes() }
                        .help("Puts all unsent notes into Claude's message box as one draft")
                } else if !link.connected {
                    Button(installing ? "Connecting…" : "Connect") {
                        installing = true
                        Task { installMessage = await link.installMod(); installing = false }
                    }
                    .disabled(installing)
                    .help("Installs the small vet-bridge mod into Claude Code so Vet can put drafts into your chat")
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .frame(height: 22)
            .alert("Claude link", isPresented: Binding(get: { installMessage != nil }, set: { if !$0 { installMessage = nil } })) {
                Button("OK") { installMessage = nil }
            } message: { Text(installMessage ?? "") }
        }
    }
}

@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]
    /// The Finder icon for a file name's type (cached per extension).
    static func icon(for name: String) -> NSImage {
        let ext = (name as NSString).pathExtension.lowercased()
        if let i = cache[ext] { return i }
        let i = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .plainText)
        cache[ext] = i
        return i
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
