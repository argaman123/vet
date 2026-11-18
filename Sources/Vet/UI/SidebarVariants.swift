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
    /// Sections you folded (folder paths, or "#order", "#unimportant"…), kept across launches.
    @AppStorage("foldedGroups") private var foldedRaw = ""

    private func open(_ key: String) -> Binding<Bool> {
        Binding(get: { !foldedRaw.split(separator: "\n").contains(Substring(key)) }, set: { isOpen in
            var keys = Set(foldedRaw.split(separator: "\n").map(String.init))
            if isOpen { keys.remove(key) } else { keys.insert(key) }
            foldedRaw = keys.sorted().joined(separator: "\n")
        })
    }

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
        .frame(maxHeight: .infinity)
        // Glass over the list: the rows pass under the bar.
        .sidebarFooter {
            VStack(spacing: 0) {
                if let path = app.workspace.review.diff?.change.path, let summary = app.workspace.review.plan?.file(path)?.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label((path as NSString).lastPathComponent, systemImage: RibbonGutterView.claudeSymbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Text(summary).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Glass.fill, in: .rect(cornerRadius: Glass.fieldRadius, style: .continuous))
                    .padding(.horizontal, NativeShell.gap).padding(.top, 6)
                }
                FilterBar(app: app, filter: $filter, tree: style == .tree)
            }
        }
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
        // The order the rows appear in, top to bottom: ⌘↩ moves through files in it.
        let byPath: ([FileChange]) -> [String] = { $0.map(\.path).sorted() }
        let middle: [String] = switch style {
        case .tree, .current: FileTreeNode.filesInOrder(FileTreeNode.build(important)).map(\.path)
        case .list: byPath(important.filter { review.stage(of: $0) != .staged }) + byPath(important.filter { review.stage(of: $0) == .staged })
        case .groups: Dictionary(grouping: important) { ($0.path as NSString).deletingLastPathComponent }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.flatMap { byPath($0.value) }
        }
        let tail = style == .tree ? FileTreeNode.filesInOrder(FileTreeNode.build(unimportant)).map(\.path) : byPath(unimportant)
        let order = planPaths + middle + tail
        return List(selection: Binding(get: { row ?? review.selectedPath }, set: { path in
            row = path
            if let path, review.changes.contains(where: { $0.path == path }) { app.showDiff(path) }
        })) {
            if !planPaths.isEmpty {
                VariantHeader(title: "Review Order", count: planPaths.count, open: open("#order")).headerRow()
                if open("#order").wrappedValue {
                    ForEach(Array(planPaths.enumerated()), id: \.element) { i, path in
                        if let node = FileTreeNode.find(path, in: review.tree) {
                            VariantFileRow(app: app, node: node, index: i + 1, detail: nil).tag(path).quietRow(path)
                        }
                    }
                }
            }
            switch style {
            case .tree, .current:
                if !important.isEmpty {
                    VariantHeader(title: planPaths.isEmpty ? "Changes" : "Other Changes", count: important.count, open: open("#changes")).headerRow()
                    if open("#changes").wrappedValue {
                        ForEach(CompactChange.compact(FileTreeNode.build(important))) { VariantTreeRow(app: app, item: $0) }
                    }
                }
            case .list:
                let toReview = important.filter { review.stage(of: $0) != .staged }
                let reviewed = important.filter { review.stage(of: $0) == .staged }
                if !toReview.isEmpty {
                    VariantHeader(title: "To Review", count: toReview.count, open: open("#toreview")).headerRow()
                    if open("#toreview").wrappedValue { flat(toReview) }
                }
                if !reviewed.isEmpty {
                    VariantHeader(title: "Reviewed", count: reviewed.count, open: open("#reviewed")).headerRow()
                    if open("#reviewed").wrappedValue { flat(reviewed) }
                }
            case .groups:
                let byFolder = Dictionary(grouping: important) { ($0.path as NSString).deletingLastPathComponent }
                ForEach(byFolder.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { folder in
                    VariantHeader(title: folder.isEmpty ? "Project" : folder, count: nil, path: true, open: open(folder)).headerRow()
                    if open(folder).wrappedValue {
                        ForEach(byFolder[folder]!.sorted { $0.path < $1.path }, id: \.path) { c in
                            if let node = FileTreeNode.find(c.path, in: review.tree) {
                                VariantFileRow(app: app, node: node, index: nil, detail: nil).tag(c.path).quietRow(c.path)
                            }
                        }
                    }
                }
            }
            if !unimportant.isEmpty {
                VariantHeader(title: "Unimportant", count: unimportant.count, open: open("#unimportant")).headerRow()
                if open("#unimportant").wrappedValue {
                    if style == .tree {
                        ForEach(CompactChange.compact(FileTreeNode.build(unimportant))) { VariantTreeRow(app: app, item: $0) }
                    } else {
                        flat(unimportant)
                    }
                }
            }
            ListEndSpace()
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
        .quietSelection(row ?? review.selectedPath)
        .onAppear { review.sidebarOrder = order }
        .onChange(of: order) { _, o in review.sidebarOrder = o }
    }

    /// Files as one flat list: the name, then its folder in a quiet tone.
    @ViewBuilder private func flat(_ changes: [FileChange]) -> some View {
        let review = app.workspace.review
        ForEach(changes.sorted { $0.path < $1.path }, id: \.path) { c in
            if let node = FileTreeNode.find(c.path, in: review.tree) {
                let folder = (c.path as NSString).deletingLastPathComponent
                VariantFileRow(app: app, node: node, index: nil, detail: folder.isEmpty ? nil : folder).tag(c.path).quietRow(c.path)
            }
        }
    }
}

private struct VariantHeader: View {
    let title: String
    let count: Int?
    var path = false
    /// Clicking the header folds or unfolds its section (a folder you've finished, say). The rows
    /// come and go with it, so the system's own hover chevron doesn't appear beside this one.
    var open: Binding<Bool>? = nil
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 5) {
            // Leading, like a folder's disclosure: never under the list's scroller.
            if let open {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                    .animation(.easeOut(duration: 0.15), value: open.wrappedValue)
                    .frame(width: 10)
            }
            Text(title).lineLimit(1).truncationMode(.head)
                .font(.system(size: 12, weight: path ? .medium : .semibold))
                .foregroundStyle(.secondary)
            if let count { Text("\(count)").font(.system(size: 12)).foregroundStyle(.tertiary).monospacedDigit() }
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(HoverFill(on: hovering && open != nil, radius: 6).padding(.horizontal, -4).padding(.vertical, -3))
        .onHover { hovering = $0 }
        .onTapGesture { open?.wrappedValue.toggle() }
        .pointerStyle(open == nil ? nil : .link)
        .help(open.map { $0.wrappedValue ? "Fold \(title)" : "Unfold \(title)" } ?? "")
    }

    /// The header as a row of the list, not a section's header: the list's own sections put a
    /// wide gap above each one, and a row keeps the groups as close as the files in them.
    func headerRow() -> some View {
        padding(.top, 2)
            .listRowBackground(Color.clear)
            .selectionDisabled()
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
    /// In a tree: the icon keeps in line with the folders' icons.
    var inTree = false
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
            Image(nsImage: FileIcons.icon(for: node.name)).resizable().frame(width: SidebarMetrics.icon, height: SidebarMetrics.icon)
                .padding(.leading, inTree ? TreeMetrics.iconLead : 0)
            ChangeName(name: node.name, kind: change.kind).layoutPriority(1)
            if let detail {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            VariantMark(app: app, node: node, hovering: hovering)
        }
        .frame(minHeight: SidebarMetrics.row)
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
                    Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(.tertiary).frame(width: SidebarMetrics.icon)
                        .padding(.leading, TreeMetrics.iconLead) // air after the disclosure chevron
                    Text(item.name).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    VariantMark(app: app, node: node, hovering: hovering)
                }
                .frame(minHeight: SidebarMetrics.row)
                .opacity(node.fileChanges.allSatisfy { review.isMarked($0.path) } ? 0.45 : 1)
                .onHover { hovering = $0 }
                .rowPointer(node.path)
            }
            .tag(node.path)
            .quietFolderRow(node.path)
        } else {
            VariantFileRow(app: app, node: node, index: nil, detail: nil, inTree: true).tag(node.path).quietRow(node.path)
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
        .buttonStyle(.hand)
        .foregroundStyle(.secondary)
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(height: 30)
        .sidebarBar()
        .sidebarBarPadding()
    }
}

/// Room after a list's last row, so it can scroll clear of the glass bar floating over the bottom.
/// (A plain row: the AppKit-backed list ignores content margins.)
struct ListEndSpace: View {
    var body: some View {
        Color.clear
            .frame(height: 2) // the bar is under the list, not over it
            .listRowBackground(Color.clear)
            .selectionDisabled()
            .accessibilityHidden(true)
    }
}
