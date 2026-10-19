import AppKit
import SwiftUI
import VetCore

// MARK: Project: the whole tree; a click opens the file

struct ProjectTool: View {
    let app: AppDelegate
    @State private var quickLook: URL?
    @State private var row: String?

    var body: some View {
        let files = app.workspace.files
        VStack(spacing: 0) {
            if app.projects.current == nil {
                EmptyToolState(title: "No Project", message: "Open a project folder.") {
                    Button("Open Folder…") { app.projects.showOpenPanel() }
                }
            } else {
                List(selection: Binding(get: { row ?? files.relativePath }, set: { path in
                    row = path
                    if let path, Self.isFile(path, files.tree), let url = files.url(for: path) { app.showFile(url) }
                })) {
                    ForEach(CompactFile.compact(files.tree)) { ProjectNodeRow(app: app, item: $0, quickLook: $quickLook) }
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
                .contentMargins(.bottom, 52, for: .scrollContent) // the last rows can scroll clear of the bar
                .quietSelection(row ?? files.relativePath)
            }
        }
        .frame(maxHeight: .infinity)
        // The tree's tools in glass over the list, as in the changes list.
        .overlay(alignment: .bottom) {
            HStack(spacing: 4) {
                Text("All Files").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                ToolButton("scope", "Reveal the Open File") { if let p = files.relativePath { files.expandAncestors(of: p) } }
                ToolButton("arrow.down.right.and.arrow.up.left", "Collapse All") { files.expanded = [] }
            }
            .font(.callout)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.leading, 12).padding(.trailing, 4)
            .frame(height: 28)
            .glassEffect(in: Capsule())
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
                    Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(.tertiary).frame(width: 16)
                    Text(item.name).foregroundStyle(.secondary).lineLimit(1)
                }
                .opacity(app.workspace.review.isMarked(node.path) ? 0.45 : 1)
            }
            .tag(node.path)
            .quietRow(node.path)
            .contextMenu { menu }
        } else {
            HStack(spacing: 6) {
                Image(nsImage: FileIcons.icon(for: node.name)).resizable().frame(width: 16, height: 16)
                let change = app.workspace.review.changes.first(where: { $0.path == node.path })
                ChangeName(name: node.name, kind: change?.kind, selected: app.workspace.files.relativePath == node.path)
            }
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
