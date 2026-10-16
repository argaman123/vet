import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VetCore

/// The changes tree: a native source-list outline with a staging checkbox on every row.
struct FileTreeView: NSViewRepresentable {
    let model: ReviewModel
    let version: Int
    let selectedPath: String?

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = KeyOutlineView()
        outline.style = .sourceList
        outline.headerView = nil
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.action = #selector(Coordinator.rowClicked(_:))
        outline.menu = context.coordinator.makeMenu()
        outline.onSpace = { [weak coordinator = context.coordinator] in coordinator?.toggleSelected() }
        context.coordinator.outline = outline
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.reload()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        _ = version
        context.coordinator.reload()
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        let model: ReviewModel
        weak var outline: NSOutlineView?
        private var roots: [FileTreeNode] = []
        private var restoring = false

        init(model: ReviewModel) { self.model = model }

        func reload() {
            guard let outline else { return }
            roots = model.tree
            restoring = true
            outline.reloadData()
            restoreExpansion(roots)
            restoring = false
            if let sel = model.selectedPath, let row = rowFor(path: sel) {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            } else {
                outline.deselectAll(nil)
            }
        }

        private func restoreExpansion(_ nodes: [FileTreeNode]) {
            for n in nodes where n.isFolder && model.expanded.contains(n.path) {
                outline?.expandItem(n)
                restoreExpansion(n.children)
            }
        }

        private func rowFor(path: String) -> Int? {
            guard let outline else { return nil }
            for row in 0..<outline.numberOfRows {
                if (outline.item(atRow: row) as? FileTreeNode)?.path == path { return row }
            }
            return nil
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? FileTreeNode)?.children.count ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? FileTreeNode)?.children[index] ?? roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileTreeNode)?.isFolder ?? false
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileTreeNode else { return nil }
            let cell = (outlineView.makeView(withIdentifier: FileRowView.id, owner: nil) as? FileRowView) ?? FileRowView()
            cell.configure(node: node, stage: model.stage(of: node)) { [weak self] staged in
                self?.model.setStaged(node, staged)
            }
            return cell
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !restoring, let node = notification.userInfo?["NSObject"] as? FileTreeNode else { return }
            model.expanded.insert(node.path)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !restoring, let node = notification.userInfo?["NSObject"] as? FileTreeNode else { return }
            model.expanded.remove(node.path)
        }

        @objc func rowClicked(_ sender: NSOutlineView) {
            let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
            guard row >= 0, let node = sender.item(atRow: row) as? FileTreeNode else { return }
            if node.isFolder {
                if sender.isItemExpanded(node) { sender.collapseItem(node) } else { sender.expandItem(node) }
            } else {
                model.selectedPath = node.path
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline, !restoring, outline.selectedRow >= 0,
                  let node = outline.item(atRow: outline.selectedRow) as? FileTreeNode, !node.isFolder else { return }
            if model.selectedPath != node.path { model.selectedPath = node.path }
        }

        func toggleSelected() {
            guard let outline, outline.selectedRow >= 0, let node = outline.item(atRow: outline.selectedRow) as? FileTreeNode else { return }
            model.setStaged(node, model.stage(of: node) != .staged)
        }

        // MARK: Right-click menu (spec §2.3, exactly these items)

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? FileTreeNode else { return }
            let ask = NSMenuItem(title: node.isFolder ? "Ask Claude about this folder" : "Ask Claude about this file", action: nil, keyEquivalent: "")
            ask.toolTip = "Needs the Claude bridge (coming soon)"
            ask.isEnabled = false
            menu.addItem(ask)
            menu.addItem(.separator())
            menu.addItem(item("Mark as unimportant", node, #selector(markUnimportant(_:)), enabled: false))
            menu.addItem(item("Unstage", node, #selector(unstage(_:)), enabled: model.stage(of: node) != .unstaged))
            menu.addItem(.separator())
            menu.addItem(item("Open plain diff", node, #selector(openPlain(_:)), enabled: !node.isFolder))
            menu.addItem(item("Show in Finder", node, #selector(showInFinder(_:))))
            menu.addItem(item("Copy path", node, #selector(copyPath(_:))))
        }

        private func item(_ title: String, _ node: FileTreeNode, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            i.target = self
            i.representedObject = node
            i.isEnabled = enabled
            return i
        }

        @objc func markUnimportant(_ sender: NSMenuItem) {}

        @objc func unstage(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileTreeNode else { return }
            model.setStaged(node, false)
        }

        @objc func openPlain(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileTreeNode else { return }
            model.selectedPath = node.path
        }

        @objc func showInFinder(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileTreeNode, let url = model.url(for: node.path) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        @objc func copyPath(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileTreeNode else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        }
    }
}

/// Space toggles the selected row's checkbox; Return opens/expands it.
final class KeyOutlineView: NSOutlineView {
    var onSpace: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: onSpace?() // space
        case 36, 76: // return, enter
            if selectedRow >= 0 { sendAction(action, to: target) }
        default: super.keyDown(with: event)
        }
    }
}

/// One tree row: checkbox, icon, colored name, and the original name for renames.
final class FileRowView: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("FileRow")
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var onToggle: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        checkbox.allowsMixedState = true
        checkbox.target = self
        checkbox.action = #selector(toggled)
        icon.imageScaling = .scaleProportionallyDown
        name.lineBreakMode = .byTruncatingMiddle
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let stack = NSStackView(views: [checkbox, icon, name, detail])
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = name
        imageView = icon
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
        ])
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(node: FileTreeNode, stage: StageState, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        checkbox.state = switch stage { case .staged: .on; case .unstaged: .off; case .partial: .mixed }
        name.stringValue = node.name
        if let change = node.change {
            icon.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .plainText)
            var color = Self.color(for: change.kind)
            if stage == .staged { color = color.withAlphaComponent(0.6) } // reviewed files go quieter
            name.textColor = color
            name.font = .systemFont(ofSize: NSFont.systemFontSize)
            detail.stringValue = change.origPath.map { "← " + ($0 as NSString).lastPathComponent } ?? ""
            detail.toolTip = change.origPath
            toolTip = change.origPath.map { "Renamed from \($0)" } ?? change.path
        } else {
            icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
            icon.contentTintColor = .secondaryLabelColor
            name.textColor = .labelColor
            detail.stringValue = ""
            toolTip = node.path
        }
        detail.isHidden = detail.stringValue.isEmpty
    }

    static func color(for kind: ChangeKind) -> NSColor {
        switch kind {
        case .modified: .systemOrange
        case .added, .untracked: .systemGreen
        case .deleted: .systemRed
        case .renamed: .systemBlue
        case .conflicted: .systemPurple
        }
    }

    @objc private func toggled() {
        // A click on a mixed or empty box stages everything; on a checked box, unstages.
        onToggle?(checkbox.state != .off)
    }
}
