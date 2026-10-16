import AppKit
import Observation
import VetCore

/// A folder or file in the Files tab.
@MainActor
final class FileListNode {
    let name: String
    let path: String // repo-relative
    let isFolder: Bool
    fileprivate(set) var children: [FileListNode] = []

    init(name: String, path: String, isFolder: Bool) {
        self.name = name
        self.path = path
        self.isFolder = isFolder
    }

    static func build(_ paths: [String]) -> [FileListNode] {
        let root = FileListNode(name: "", path: "", isFolder: true)
        var folders: [String: FileListNode] = ["": root]
        func folder(_ path: String) -> FileListNode {
            if let f = folders[path] { return f }
            let node = FileListNode(name: (path as NSString).lastPathComponent, path: path, isFolder: true)
            folder((path as NSString).deletingLastPathComponent).children.append(node)
            folders[path] = node
            return node
        }
        for p in paths {
            folder((p as NSString).deletingLastPathComponent).children.append(
                FileListNode(name: (p as NSString).lastPathComponent, path: p, isFolder: false))
        }
        func sort(_ n: FileListNode) {
            n.children.sort {
                if $0.isFolder != $1.isFolder { return $0.isFolder }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            n.children.forEach(sort)
        }
        sort(root)
        return root.children
    }
}

/// State of the Files tab: the whole project, and the open file with its history.
@MainActor @Observable
final class FilesModel {
    struct Location: Equatable { let url: URL; let line: Int }

    private(set) var root: URL?
    private(set) var tree: [FileListNode] = []
    private(set) var treeVersion = 0
    var expanded: Set<String> = []

    private(set) var openURL: URL?
    private(set) var text: TextLines?
    private(set) var language: CodeLanguage = .plain
    private(set) var message: String?
    /// Bumped whenever a new file (or a fresh copy from disk) should be shown.
    private(set) var docVersion = 0
    /// Where to put the caret after loading: (line, UTF-16 column).
    private(set) var target: (line: Int, character: Int)?
    var isDirty = false
    /// The open file changed on disk while you had unsaved edits.
    private(set) var changedOnDisk = false
    private(set) var error: String?
    private var back: [Location] = []
    private var forward: [Location] = []
    private var currentLine = 0
    private var treeTask: Task<Void, Never>?

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    var relativePath: String? {
        guard let root, let openURL else { return nil }
        let r = root.standardizedFileURL.path, p = openURL.standardizedFileURL.path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
    }

    func open(_ folder: URL?) {
        root = folder
        tree = []
        expanded = []
        openURL = nil
        text = nil
        back = []
        forward = []
        reloadTree()
    }

    func reloadTree() {
        guard let root else { return }
        treeTask?.cancel()
        treeTask = Task {
            let paths = await Task.detached { Self.listFiles(root) }.value
            guard !Task.isCancelled, root == self.root else { return }
            tree = FileListNode.build(paths)
            treeVersion += 1
        }
    }

    /// Git projects: tracked plus untracked-but-not-ignored files (what `git status` would care
    /// about). Plain folders: a walk that skips the usual dependency and build folders.
    nonisolated static func listFiles(_ root: URL) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: GitRepo.gitPath)
        p.arguments = ["ls-files", "-co", "--exclude-standard", "-z"]
        p.currentDirectoryURL = root
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            }
        }
        let skip: Set<String> = [".git", "node_modules", ".venv", "venv", "__pycache__", "build", "dist", ".gradle", ".idea", "target", ".angular", ".next", "DerivedData"]
        var result: [String] = []
        let base = root.standardizedFileURL.path
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) else { return [] }
        for case let url as URL in e {
            if skip.contains(url.lastPathComponent) { e.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            result.append(String(url.standardizedFileURL.path.dropFirst(base.count + 1)))
            if result.count > 50_000 { break }
        }
        return result
    }

    /// The editor's text as file contents (set by the editor view), for save prompts.
    var editorText: (() -> String?)?

    /// The editor lives as long as the model, so switching tabs keeps your unsaved text.
    @ObservationIgnored lazy var editorView = CodeEditorView()
    /// Bumped to move within the open file without reloading it (and losing your edits).
    private(set) var jumpSerial = 0

    /// Saves the editor's unsaved edits, if any.
    func saveEditor() {
        guard isDirty, let text = editorText?() else { return }
        save(text)
    }

    /// Before leaving the open file: asks to save unsaved edits. False means stay.
    func confirmLeave() -> Bool {
        guard isDirty, let name = openURL?.lastPathComponent else { return true }
        switch Alerts.unsaved(name) {
        case .save: return editorText?().map { save($0) } ?? false
        case .discard:
            if let url = openURL { load(url) } // the file as it is on disk now
            docVersion += 1
            return true
        case .cancel: return false
        }
    }

    /// Opens a file (from the tree, a definition jump, or history).
    func show(_ url: URL, line: Int = 0, character: Int = 0, record: Bool = true) {
        if url != openURL { guard confirmLeave() else { return } }
        if record, let current = openURL, current != url || currentLine != line {
            back.append(Location(url: current, line: currentLine))
            forward = []
        }
        if let rel = relative(url) { expandAncestors(of: rel) }
        currentLine = line
        target = (line, character)
        if url == openURL && text != nil { jumpSerial += 1; return } // same file: keep its text and your edits
        load(url)
        docVersion += 1
    }

    func goBack() {
        guard let last = back.last, let current = openURL else { return }
        if last.url != current { guard confirmLeave() else { return } }
        back.removeLast()
        forward.append(Location(url: current, line: currentLine))
        show(last.url, line: last.line, record: false)
    }

    func goForward() {
        guard let next = forward.last, let current = openURL else { return }
        if next.url != current { guard confirmLeave() else { return } }
        forward.removeLast()
        back.append(Location(url: current, line: currentLine))
        show(next.url, line: next.line, record: false)
    }

    private func load(_ url: URL) {
        openURL = url
        language = CodeLanguage(path: url.path)
        isDirty = false
        changedOnDisk = false
        message = nil
        text = nil
        guard let data = try? Data(contentsOf: url) else { message = "Couldn't read this file."; return }
        if data.count > DiffDocument.maxBytes { message = "File too large to show (> 5 MB)"; return }
        if data.prefix(8000).contains(0) { message = "Binary file"; return }
        guard String(data: data, encoding: .utf8) != nil else { message = "Not UTF-8 text"; return }
        text = TextLines(data)
    }

    /// Something in the project changed on disk.
    func diskChanged() {
        reloadTree()
        guard let url = openURL else { return }
        let fresh = try? Data(contentsOf: url)
        guard let fresh, fresh != text?.joined() else { return }
        if isDirty { changedOnDisk = true; return } // never overwrite your unsaved edits
        load(url)
        target = nil
        docVersion += 1
    }

    /// Writes the editor's text to the open file (atomically) and reloads it. If the file changed
    /// on disk since it was loaded, asks before overwriting. Returns whether it was saved.
    @discardableResult
    func save(_ contents: String) -> Bool {
        guard let url = openURL else { return false }
        if let loaded = text?.joined(), (try? Data(contentsOf: url)) != loaded, // changed, or moved away
           !Alerts.changedOnDisk(url.lastPathComponent) {
            changedOnDisk = true
            return false
        }
        do {
            try Data(contents.utf8).write(to: url, options: .atomic)
            isDirty = false
            changedOnDisk = false
            load(url)
            target = nil
            docVersion += 1
            return true
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }

    /// Throws away your unsaved edits and shows what's on disk.
    func revertToDisk() {
        guard let url = openURL else { return }
        load(url)
        target = nil
        docVersion += 1
    }

    func noteLine(_ line: Int) { currentLine = line }

    func expandAncestors(of path: String) {
        var p = (path as NSString).deletingLastPathComponent
        while !p.isEmpty {
            expanded.insert(p)
            p = (p as NSString).deletingLastPathComponent
        }
    }

    func relative(_ url: URL) -> String? {
        guard let root else { return nil }
        let r = root.standardizedFileURL.path, p = url.standardizedFileURL.path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : nil
    }

    func url(for path: String) -> URL? { root?.appendingPathComponent(path) }
}
