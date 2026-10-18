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
                Text(app.projects.current?.lastPathComponent ?? "No project").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                ToolButton("scope", "Reveal the Open File") { if let p = files.relativePath { files.expandAncestors(of: p) } }
                ToolButton("arrow.down.right.and.arrow.up.left", "Collapse All") { files.expanded = [] }
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

// MARK: Run: configurations, start/stop, output

struct RunTool: View {
    let app: AppDelegate

    var body: some View {
        let run = app.workspace.run, ui = app.ui
        VStack(spacing: 0) {
            ToolHeader {
                Text(run.isRunning ? "Running" : run.crashed ? "Stopped with an error" : "Not running")
                    .foregroundStyle(run.crashed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                Spacer()
                ToolButton(run.outputVisible ? "rectangle.bottomthird.inset.filled" : "rectangle.bottomthird.inset.filled",
                           run.outputVisible ? "Hide Output (⇧⌘Y)" : "Show Output (⇧⌘Y)") { run.outputVisible.toggle() }
                ToolButton("slider.horizontal.3", "Edit Configurations…") { ui.editingRunConfigs = true }
            }
            if run.configs.isEmpty {
                EmptyToolState(title: "No Run Configurations", message: "Add a command such as npm run start.") {
                    Button("Add Configuration…") { ui.editingRunConfigs = true }
                }
            } else {
                List(selection: Binding(get: { run.selected?.id }, set: { run.selectedID = $0 })) {
                    Section("Configurations") {
                        ForEach(run.configs) { c in
                            HStack(spacing: 8) {
                                Image(systemName: c.id == run.selected?.id && run.isRunning ? "play.circle.fill" : "play.circle")
                                    .foregroundStyle(c.id == run.selected?.id && run.isRunning ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name.isEmpty ? c.command : c.name).lineLimit(1)
                                    Text(c.command).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .tag(c.id)
                            .contextMenu {
                                Button("Run") { run.selectedID = c.id; run.start(); run.outputVisible = true }.disabled(run.isRunning)
                                Button("Edit Configurations…") { ui.editingRunConfigs = true }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}

// MARK: Browser: address and the page in the main area

struct BrowserTool: View {
    let app: AppDelegate
    @FocusState private var editing: Bool

    var body: some View {
        let browser = app.workspace.browser
        VStack(alignment: .leading, spacing: 8) {
            TextField("Address, e.g. localhost:4200", text: Bindable(browser).address)
                .textFieldStyle(.roundedBorder)
                .focused($editing)
                .onSubmit { browser.go(browser.address); app.showBrowser(); editing = false }
            HStack {
                Button { browser.back() } label: { Image(systemName: "chevron.left") }.disabled(!browser.canGoBack).help("Back")
                Button { browser.forward() } label: { Image(systemName: "chevron.right") }.disabled(!browser.canGoForward).help("Forward")
                Button { browser.reload() } label: { Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise") }.help("Reload")
                Spacer()
                Button("Show Page") { app.showBrowser() }
            }
            .buttonStyle(.borderless)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .onAppear { app.showBrowser() }
    }
}
