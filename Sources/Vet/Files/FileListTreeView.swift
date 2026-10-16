import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The whole project as a native source-list outline.
struct FileListTreeView: NSViewRepresentable {
    let model: FilesModel
    let version: Int
    let selected: String?

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        outline.style = .sourceList
        outline.headerView = nil
        outline.indentationPerLevel = 14
        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.action = #selector(Coordinator.clicked(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu
        context.coordinator.outline = outline
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.reload(selected: selected)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        _ = version
        context.coordinator.reload(selected: selected)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        let model: FilesModel
        weak var outline: NSOutlineView?
        private var roots: [FileListNode] = []
        private var shownVersion = -1
        private var restoring = false

        init(model: FilesModel) { self.model = model }

        func reload(selected: String?) {
            guard let outline else { return }
            restoring = true
            if shownVersion != model.treeVersion {
                shownVersion = model.treeVersion
                roots = model.tree
                outline.reloadData()
            }
            expand(roots)
            restoring = false
            if let selected, let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? FileListNode)?.path == selected }) {
                if outline.selectedRow != row {
                    outline.selectRowIndexes([row], byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                }
            }
        }

        private func expand(_ nodes: [FileListNode]) {
            for n in nodes where n.isFolder && model.expanded.contains(n.path) {
                outline?.expandItem(n)
                expand(n.children)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? FileListNode)?.children.count ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? FileListNode)?.children[index] ?? roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileListNode)?.isFolder ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileListNode else { return nil }
            let id = NSUserInterfaceItemIdentifier("FileListRow")
            let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                c.identifier = id
                let image = NSImageView(), text = NSTextField(labelWithString: "")
                text.lineBreakMode = .byTruncatingMiddle
                let stack = NSStackView(views: [image, text])
                stack.spacing = 5
                stack.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(stack)
                c.imageView = image
                c.textField = text
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    stack.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -4),
                    stack.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16),
                ])
                return c
            }()
            cell.textField?.stringValue = node.name
            if node.isFolder {
                cell.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
                cell.imageView?.contentTintColor = .secondaryLabelColor
            } else {
                cell.imageView?.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .plainText)
                cell.imageView?.contentTintColor = nil
            }
            return cell
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !restoring, let node = notification.userInfo?["NSObject"] as? FileListNode else { return }
            model.expanded.insert(node.path)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !restoring, let node = notification.userInfo?["NSObject"] as? FileListNode else { return }
            model.expanded.remove(node.path)
        }

        @objc func clicked(_ sender: NSOutlineView) {
            let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
            guard row >= 0, let node = sender.item(atRow: row) as? FileListNode else { return }
            if node.isFolder {
                if sender.isItemExpanded(node) { sender.collapseItem(node) } else { sender.expandItem(node) }
            } else if !selectionHandledClick, let url = model.url(for: node.path), url != model.openURL {
                open(url)
            }
            selectionHandledClick = false
        }

        /// A click that changed the selection already opened the file (or asked about unsaved
        /// edits); the click action that follows mustn't ask again.
        private var selectionHandledClick = false

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline, !restoring, outline.selectedRow >= 0,
                  let node = outline.item(atRow: outline.selectedRow) as? FileListNode, !node.isFolder,
                  let url = model.url(for: node.path), url != model.openURL else { return }
            selectionHandledClick = true
            open(url)
        }

        /// Opens `url`; if you chose to stay on the open file, puts the selection back on it.
        private func open(_ url: URL) {
            model.show(url)
            if model.openURL != url { reload(selected: model.openURL.flatMap(model.relative)) }
        }

        // Right-click: Show in Finder, Copy path.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline else { return }
            let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
            guard row >= 0, let node = outline.item(atRow: row) as? FileListNode else { return }
            let finder = NSMenuItem(title: "Show in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
            let copy = NSMenuItem(title: "Copy path", action: #selector(copyPath(_:)), keyEquivalent: "")
            for i in [finder, copy] { i.target = self; i.representedObject = node; menu.addItem(i) }
        }

        @objc func showInFinder(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileListNode, let url = model.url(for: node.path) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        @objc func copyPath(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileListNode else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        }
    }
}
