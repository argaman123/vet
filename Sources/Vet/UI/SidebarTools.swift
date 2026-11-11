import AppKit
import SwiftUI
import VetCore

// MARK: Project: the whole tree; a click opens the file

struct ProjectTool: View {
    let app: AppDelegate
    @State private var quickLook: URL?
    @State private var row: String?
    /// Typed in the bar: the files whose names contain it, as a flat list.
    @State private var filter = ""

    var body: some View {
        let files = app.workspace.files
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        VStack(spacing: 0) {
            if app.projects.current == nil {
                EmptyToolState(title: "No Project", message: "Open a project folder.") {
                    Button("Open Folder…") { app.projects.showOpenPanel() }
                }
            } else if !query.isEmpty {
                let matches = Array(files.paths.lazy.filter { ($0 as NSString).lastPathComponent.lowercased().contains(query) }.prefix(300))
                List(selection: Binding(get: { row ?? files.relativePath }, set: { path in
                    row = path
                    if let path, let url = files.url(for: path) { app.showFile(url) }
                })) {
                    ForEach(matches, id: \.self) { path in
                        let name = (path as NSString).lastPathComponent, folder = (path as NSString).deletingLastPathComponent
                        HStack(spacing: 6) {
                            Image(nsImage: FileIcons.icon(for: name)).resizable().frame(width: SidebarMetrics.icon, height: SidebarMetrics.icon)
                            ChangeName(name: name, kind: app.workspace.review.changes.first(where: { $0.path == path })?.kind).layoutPriority(1)
                            Text(folder).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                        }
                        .frame(minHeight: SidebarMetrics.row)
                        .tag(path)
                        .quietRow(path)
                    }
                    ListEndSpace()
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .transaction { $0.disablesAnimations = true; $0.animation = nil }
                .quietSelection(row ?? files.relativePath)
            } else {
                List(selection: Binding(get: { row ?? files.relativePath }, set: { path in
                    row = path
                    if let path, Self.isFile(path, files.tree), let url = files.url(for: path) { app.showFile(url) }
                })) {
                    ForEach(CompactFile.compact(files.tree)) { ProjectNodeRow(app: app, item: $0, quickLook: $quickLook) }
                    ListEndSpace()
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .transaction { $0.disablesAnimations = true; $0.animation = nil }
                // Double-click (or Return) opens or closes a folder.
                .contextMenu(forSelectionType: String.self) { _ in EmptyView() } primaryAction: { ids in
                    for id in ids where !Self.isFile(id, files.tree) {
                        if files.expanded.contains(id) { files.expanded.remove(id) } else { files.expanded.insert(id) }
                    }
                }
                .quickLookPreview($quickLook)
                .quietSelection(row ?? files.relativePath)
                // A file opened elsewhere (Open in Editor, a jump) becomes the one selection here.
                .onChange(of: files.relativePath) { _, _ in row = nil }
            }
        }
        .frame(maxHeight: .infinity)
        // The tree's tools in glass over the list, as in the changes list.
        .overlay(alignment: .bottom) {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.tertiary)
                TextField("Filter", text: $filter).textFieldStyle(.plain)
                // One button that flips between folding everything and opening everything.
                if files.expanded.isEmpty {
                    ToolButton("arrow.up.left.and.arrow.down.right", "Expand All") { files.expanded = files.allFolders() }
                } else {
                    ToolButton("arrow.down.right.and.arrow.up.left", "Collapse All") { files.expanded = [] }
                }
            }
            .font(.callout)
            .buttonStyle(.hand)
            .foregroundStyle(.secondary)
            .padding(.leading, 10).padding(.trailing, 4)
            .frame(height: 30)
            .sidebarBar()
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
    }
}

extension ProjectTool {
    /// Whether `path` is a file (not a folder) in the tree.
    static func isFile(_ path: String, _ nodes: [FileListNode]) -> Bool {
        for n in nodes {
            if n.path == path { return !n.isFolder }
            if n.isFolder, path.hasPrefix(n.path + "/") { return isFile(path, n.children) }
        }
        return false
    }
}

/// A project tree row; single-folder chains are joined, as in the changes outline.
struct CompactFile: Identifiable {
    let name: String
    let node: FileListNode
    var id: String { node.path }

    @MainActor static func compact(_ nodes: [FileListNode]) -> [CompactFile] {
        nodes.map { n in
            var cur = n, name = n.name
            while cur.isFolder, cur.children.count == 1, cur.children[0].isFolder {
                cur = cur.children[0]
                name += "/" + cur.name
            }
            return CompactFile(name: name, node: cur)
        }
    }
}

struct ProjectNodeRow: View {
    let app: AppDelegate
    let item: CompactFile
    @Binding var quickLook: URL?
    @Environment(\.backgroundProminence) private var prominence
    private var node: FileListNode { item.node }

    var body: some View {
        let files = app.workspace.files
        if node.isFolder {
            DisclosureGroup(isExpanded: Binding(
                get: { files.expanded.contains(node.path) },
                set: { if $0 { files.expanded.insert(node.path) } else { files.expanded.remove(node.path) } })) {
                // Children are built only when the folder is open, so large projects stay fast.
                ForEach(CompactFile.compact(node.children)) { ProjectNodeRow(app: app, item: $0, quickLook: $quickLook) }
            } label: {
                // Folders recede: a thin outline and a quiet name, so the files carry the color.
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(.tertiary).frame(width: SidebarMetrics.icon)
                        .padding(.leading, TreeMetrics.iconLead) // air after the disclosure chevron
                    Text(item.name).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(minHeight: SidebarMetrics.row)
                .opacity(app.workspace.review.isMarked(node.path) ? 0.45 : 1)
                .rowPointer(node.path)
            }
            .tag(node.path)
            .quietFolderRow(node.path)
            .contextMenu { menu }
        } else {
            HStack(spacing: 6) {
                Image(nsImage: FileIcons.icon(for: node.name)).resizable().frame(width: SidebarMetrics.icon, height: SidebarMetrics.icon)
                    .padding(.leading, TreeMetrics.iconLead) // in line with the folders' icons
                let change = app.workspace.review.changes.first(where: { $0.path == node.path })
                ChangeName(name: node.name, kind: change?.kind, selected: app.workspace.files.relativePath == node.path)
            }
            .frame(minHeight: SidebarMetrics.row)
            .opacity(app.workspace.review.isMarked(node.path) ? 0.45 : 1) // unimportant files recede
            .tag(node.path)
            .quietRow(node.path)
            .contextMenu { menu }
        }
    }

    @ViewBuilder private var menu: some View {
        let files = app.workspace.files
        if !node.isFolder {
            Button("Quick Look") { quickLook = files.url(for: node.path) }
            if app.workspace.review.changes.contains(where: { $0.path == node.path }) {
                Button("Show Changes") { app.showDiff(node.path) }
            }
            Divider()
        }
        Button("Show in Finder") { if let url = files.url(for: node.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        }
    }
}

/// The file trees' spacing.
enum TreeMetrics {
    /// Between a folder's disclosure chevron and its icon (files at the same level move with it).
    static let iconLead: CGFloat = 3 // WebStorm keeps the icon right after the chevron
}
