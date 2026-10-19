import SwiftUI
import VetCore

/// Sidebar layouts under study (design.sidebar). All share: a review mark that shows only
/// when it means something (hover, partly or fully reviewed), unimportant files in their own
/// dimmed section, and the list's tools in a filter bar at the bottom, as Xcode's navigators do.
struct ChangesVariant: View {
    let app: AppDelegate
    let style: Design.SidebarStyle
    @State private var quickLook: URL?
    @State private var row: String?
    @State private var filter = ""

    var body: some View {
        let review = app.workspace.review
        Group {
            if app.projects.current == nil {
                EmptyToolState(title: "No Project", message: "Open a project folder to review its changes.") {
                    Button("Open Folder…") { app.projects.showOpenPanel() }
                }
            } else if !review.isGitRepo {
                EmptyToolState(title: "Not a Git Repository", message: "Review needs git. Project, Find and Run still work.") { EmptyView() }
            } else if review.changes.isEmpty {
                EmptyToolState(title: "No Changes", message: "Everything matches the last commit.") { EmptyView() }
            } else {
                list
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { FilterBar(app: app, filter: $filter, tree: style == .tree) }
        .quickLookPreview($quickLook)
    }

    private var list: some View {
        let review = app.workspace.review
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = review.changes.filter { q.isEmpty || $0.path.lowercased().contains(q) }
        let planPaths = review.followPlan ? (review.plan?.files.map(\.path) ?? []).filter { p in visible.contains { $0.path == p } } : []
        let planned = Set(planPaths)
        let rest = visible.filter { !planned.contains($0.path) }
        let unimportant = rest.filter { review.isMarked($0.path) }
        let important = rest.filter { !review.isMarked($0.path) }
        return List(selection: Binding(get: { row ?? review.selectedPath }, set: { path in
            row = path
            if let path, review.changes.contains(where: { $0.path == path }) { app.showDiff(path) }
        })) {
            if !planPaths.isEmpty {
                Section {
                    ForEach(Array(planPaths.enumerated()), id: \.element) { i, path in
                        if let node = FileTreeNode.find(path, in: review.tree) {
                            VariantFileRow(app: app, node: node, index: i + 1, detail: nil).tag(path)
                        }
                    }
                } header: { VariantHeader(title: "Review Order", count: planPaths.count) }
            }
            switch style {
            case .tree, .current:
                if !important.isEmpty {
                    Section {
                        ForEach(CompactChange.compact(FileTreeNode.build(important))) { VariantTreeRow(app: app, item: $0) }
                    } header: { VariantHeader(title: planPaths.isEmpty ? "Changes" : "Other Changes", count: important.count) }
                }
            case .list:
                let toReview = important.filter { review.stage(of: $0) != .staged }
                let reviewed = important.filter { review.stage(of: $0) == .staged }
                if !toReview.isEmpty {
                    Section { flat(toReview) } header: { VariantHeader(title: "To Review", count: toReview.count) }
                }
                if !reviewed.isEmpty {
                    Section { flat(reviewed) } header: { VariantHeader(title: "Reviewed", count: reviewed.count) }
                }
            case .groups:
                let byFolder = Dictionary(grouping: important) { ($0.path as NSString).deletingLastPathComponent }
                ForEach(byFolder.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { folder in
                    Section {
                        ForEach(byFolder[folder]!.sorted { $0.path < $1.path }, id: \.path) { c in
                            if let node = FileTreeNode.find(c.path, in: review.tree) {
                                VariantFileRow(app: app, node: node, index: nil, detail: nil).tag(c.path)
                            }
                        }
                    } header: { VariantHeader(title: folder.isEmpty ? "Project" : folder, count: nil, path: true) }
                }
            }
            if !unimportant.isEmpty {
                Section {
                    if style == .tree {
                        ForEach(CompactChange.compact(FileTreeNode.build(unimportant))) { VariantTreeRow(app: app, item: $0) }
                    } else {
                        flat(unimportant)
                    }
                } header: { VariantHeader(title: "Unimportant", count: unimportant.count) }
            }
        }
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
        .transaction { $0.disablesAnimations = true; $0.animation = nil }
        .onKeyPress(.space) { review.approveAndNext(); return .handled }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    /// Files as one flat list: the name, then its folder in a quiet tone.
    @ViewBuilder private func flat(_ changes: [FileChange]) -> some View {
        let review = app.workspace.review
        ForEach(changes.sorted { $0.path < $1.path }, id: \.path) { c in
            if let node = FileTreeNode.find(c.path, in: review.tree) {
                let folder = (c.path as NSString).deletingLastPathComponent
                VariantFileRow(app: app, node: node, index: nil, detail: folder.isEmpty ? nil : folder).tag(c.path)
            }
        }
    }
}

private struct VariantHeader: View {
    let title: String
    let count: Int?
    var path = false
    var body: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1).truncationMode(.head)
                .font(path ? .caption.weight(.medium) : .subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let count { Text("\(count)").font(.subheadline).foregroundStyle(.tertiary).monospacedDigit() }
        }
    }
}

/// The review mark of a row: a check when reviewed, a filling ring when partly reviewed,
/// otherwise nothing until the pointer is over the row (or it is the selected one).
private struct VariantMark: View {
    let app: AppDelegate
    let node: FileTreeNode
    let hovering: Bool
    var body: some View {
        let review = app.workspace.review
        let state = review.stage(of: node)
        let shown = state != .unstaged || hovering || review.selectedPath == node.path
        TriStateCheckbox(state: state, fraction: node.isFolder ? nil : review.reviewedFraction(node)) { review.setStaged(node, $0) }
            .alignedToTextBaseline()
            .opacity(shown ? 1 : 0)
    }
}

private struct VariantFileRow: View {
    let app: AppDelegate
    let node: FileTreeNode
    let index: Int?
    let detail: String?
    @State private var hovering = false

    var body: some View {
        let review = app.workspace.review
        let change = node.change!
        let reviewed = review.stage(of: change) == .staged
        let quiet = review.isMarked(node.path)
        HStack(spacing: 6) {
            if let index {
                Text("\(index)").font(.callout.monospacedDigit()).foregroundStyle(.tertiary).frame(minWidth: 12, alignment: .trailing)
            }
            Image(nsImage: FileIcons.icon(for: node.name)).resizable().frame(width: 16, height: 16)
            ChangeName(name: node.name, kind: change.kind).layoutPriority(1)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            VariantMark(app: app, node: node, hovering: hovering)
        }
        .opacity(quiet ? 0.45 : reviewed && review.selectedPath != node.path ? 0.6 : 1)
        .onHover { hovering = $0 }
        .simultaneousGesture(TapGesture().onEnded { app.showDiff(node.path) })
        .help(change.kind.help)
    }
}

private struct VariantTreeRow: View {
    let app: AppDelegate
    let item: CompactChange
    @State private var hovering = false
    private var node: FileTreeNode { item.node }

    var body: some View {
        let review = app.workspace.review
        if node.isFolder {
            DisclosureGroup(isExpanded: Binding(
                get: { review.expanded.contains(node.path) || review.isMarked(node.path) || review.expanded.isEmpty },
                set: { if $0 { review.expanded.insert(node.path) } else { review.expanded.remove(node.path) } })) {
                ForEach(item.children) { VariantTreeRow(app: app, item: $0) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(.tertiary).frame(width: 16)
                    Text(item.name).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    VariantMark(app: app, node: node, hovering: hovering)
                }
                .opacity(node.fileChanges.allSatisfy { review.isMarked($0.path) } ? 0.45 : 1)
                .onHover { hovering = $0 }
            }
            .tag(node.path)
        } else {
            VariantFileRow(app: app, node: node, index: nil, detail: nil).tag(node.path)
        }
    }
}

/// The list's tools along the bottom: a filter, the unimportant rules, Claude's order, fold all.
private struct FilterBar: View {
    let app: AppDelegate
    @Binding var filter: String
    let tree: Bool

    var body: some View {
        let review = app.workspace.review
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.tertiary)
            TextField("Filter", text: $filter).textFieldStyle(.plain)
            if review.plan != nil {
                ToolButton(review.followPlan ? "list.number" : "list.bullet", review.followPlan ? "Showing Claude's review order" : "Show Claude's review order") { review.followPlan.toggle() }
            }
            ToolButton("eye.slash", "Unimportant Files…") { app.ui.editingRules = true }
            if tree {
                if review.allExpanded {
                    ToolButton("arrow.down.right.and.arrow.up.left", "Collapse All") { review.collapseAll() }
                } else {
                    ToolButton("arrow.up.left.and.arrow.down.right", "Expand All") { review.expandAll() }
                }
            }
        }
        .font(.callout)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(height: 28)
        .glassEffect(in: Capsule())
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
}
