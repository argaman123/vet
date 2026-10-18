import AppKit
import SwiftUI
import VetCore

// MARK: Project: the whole tree; a click opens the file

struct ProjectTool: View {
    let app: AppDelegate
    @State private var quickLook: URL?

    var body: some View {
        let files = app.workspace.files
        VStack(spacing: 0) {
            ToolHeader {
                Text("Project").fontWeight(.semibold).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                ToolButton("scope", "Reveal the Open File") { if let p = files.relativePath { files.expandAncestors(of: p) } }
                ToolButton("arrow.down.right.and.arrow.up.left", "Collapse All") { files.expanded = [] }
                ToolButton("xmark", "Back to Changes (⌘1)") { app.ui.tool = .changes }
            }
            if app.projects.current == nil {
                EmptyToolState(title: "No Project", message: "Open a project folder.") {
                    Button("Open Folder…") { app.projects.showOpenPanel() }
                }
            } else {
                List(selection: Binding(get: { files.relativePath }, set: { path in
                    if let path, let url = files.url(for: path), !(files.tree.isEmpty) { app.showFile(url) }
                })) {
                    ForEach(CompactFile.compact(files.tree)) { ProjectNodeRow(app: app, item: $0, quickLook: $quickLook) }
                }
                .listStyle(.sidebar)
                .quickLookPreview($quickLook)
            }
        }
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
                Label(item.name, systemImage: "folder").lineLimit(1)
            }
            .contextMenu { menu }
        } else {
            HStack(spacing: 6) {
                Image(nsImage: FileIcons.icon(for: node.name)).resizable().frame(width: 16, height: 16)
                let change = app.workspace.review.changes.first(where: { $0.path == node.path })
                Text(node.name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : change.map { AnyShapeStyle($0.kind.color) } ?? AnyShapeStyle(.primary))
                if let change {
                    Spacer(minLength: 4)
                    Text(change.kind.letter).font(.caption.weight(.semibold).monospaced()).foregroundStyle(change.kind.color)
                }
            }
            .tag(node.path)
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
