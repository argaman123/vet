import Foundation
import VetCore

/// A folder or file row in the changes tree. Classes so NSOutlineView can track identity.
@MainActor
final class FileTreeNode {
    let name: String
    /// Repo-relative path ("" for the root).
    let path: String
    let change: FileChange?
    private(set) var children: [FileTreeNode] = []

    var isFolder: Bool { change == nil }

    init(name: String, path: String, change: FileChange?) {
        self.name = name
        self.path = path
        self.change = change
    }

    /// Every file change at or under this node.
    var fileChanges: [FileChange] {
        if let change { return [change] }
        return children.flatMap(\.fileChanges)
    }

    /// Checked when every descendant is staged, empty when none are, a dash otherwise.
    var stage: StageState {
        if let change { return change.stage }
        let states = Set(fileChanges.map(\.stage))
        if states == [.staged] { return .staged }
        if states == [.unstaged] { return .unstaged }
        return .partial
    }

    /// Builds the nested tree (never compacted): folders first, then files, by name.
    static func build(_ changes: [FileChange]) -> [FileTreeNode] {
        let root = FileTreeNode(name: "", path: "", change: nil)
        var folders: [String: FileTreeNode] = ["": root]
        func folder(_ path: String) -> FileTreeNode {
            if let f = folders[path] { return f }
            let parentPath = (path as NSString).deletingLastPathComponent
            let node = FileTreeNode(name: (path as NSString).lastPathComponent, path: path, change: nil)
            folder(parentPath).children.append(node)
            folders[path] = node
            return node
        }
        for c in changes {
            let parent = folder((c.path as NSString).deletingLastPathComponent)
            parent.children.append(FileTreeNode(name: (c.path as NSString).lastPathComponent, path: c.path, change: c))
        }
        root.sortRecursively()
        return root.children
    }

    private func sortRecursively() {
        children.sort {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        children.forEach { $0.sortRecursively() }
    }

    /// Files in tree order (depth first), for "next unreviewed".
    static func filesInOrder(_ roots: [FileTreeNode]) -> [FileChange] {
        roots.flatMap { $0.isFolder ? filesInOrder($0.children) : [$0.change!] }
    }
}

extension FileTreeNode {
    /// The node at `path` (a file or folder) anywhere in `nodes`.
    static func find(_ path: String, in nodes: [FileTreeNode]) -> FileTreeNode? {
        for n in nodes {
            if n.path == path { return n }
            if n.isFolder, path.hasPrefix(n.path + "/"), let hit = find(path, in: n.children) { return hit }
        }
        return nil
    }
}

