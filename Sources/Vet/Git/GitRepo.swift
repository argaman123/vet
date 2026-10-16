import Foundation
import VetCore

struct GitError: Error, CustomStringConvertible {
    let args: [String]
    let status: Int32
    let stderr: String
    var description: String { "git \(args.joined(separator: " ")) failed (\(status)): \(stderr)" }
}

/// Runs the system `git` for one repository. The actor serializes every command,
/// so staging operations never interleave.
actor GitRepo {
    nonisolated let root: URL

    init(root: URL) { self.root = root }

    static var gitPath: String {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/git") ? "/usr/bin/git"
            : "/Library/Developer/CommandLineTools/usr/bin/git"
    }

    /// The repository root containing `url`, or nil when it isn't inside a git repo.
    static func root(containing url: URL) -> URL? {
        guard let out = try? runSync(["-C", url.path, "rev-parse", "--show-toplevel"], in: url) else { return nil }
        let path = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The repository's git directory (outside the folder for worktrees).
    static func gitDir(of root: URL) -> URL {
        if let out = try? runSync(["rev-parse", "--absolute-git-dir"], in: root) {
            let path = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return root.appendingPathComponent(".git", isDirectory: true)
    }

    func status() throws -> [FileChange] {
        let changes = StatusParser.parse(try run(["status", "--porcelain=v2", "-z", "--untracked-files=all", "--find-renames"]))
        return (try? pairUnstagedRenames(changes)) ?? changes
    }

    /// A file moved but not staged shows as a deletion plus an untracked file. As in Working
    /// Tree 0.9.13, match them with git's own rename detection in a throwaway copy of the index
    /// (intent-to-add the new files there, then ask status); the real index is never touched.
    private func pairUnstagedRenames(_ changes: [FileChange]) throws -> [FileChange] {
        let deleted = changes.filter { $0.kind == .deleted && $0.stage == .unstaged }
        let untracked = changes.filter { $0.kind == .untracked }
        guard !deleted.isEmpty, !untracked.isEmpty, untracked.count <= 500 else { return changes }
        let gitDir = Self.gitDir(of: root)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("vet-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        // Copied by reading, not cloning: a clone shows up as an event on the real index.
        try Data(contentsOf: gitDir.appendingPathComponent("index")).write(to: temp)
        let env = ["GIT_INDEX_FILE": temp.path]
        _ = try run(["add", "--intent-to-add", "--"] + untracked.map(\.path), env: env)
        let scratch = StatusParser.parse(try run(["status", "--porcelain=v2", "-z", "--untracked-files=no", "--find-renames"], env: env))
        var renamed: [String: String] = [:] // new path → old path
        for c in scratch where c.kind == .renamed && c.stage == .unstaged {
            if let old = c.origPath, deleted.contains(where: { $0.path == old }) { renamed[c.path] = old }
        }
        guard !renamed.isEmpty else { return changes }
        let olds = Set(renamed.values)
        return changes.compactMap { c in
            if olds.contains(c.path) && c.kind == .deleted { return nil }
            if let old = renamed[c.path], c.kind == .untracked {
                return FileChange(path: c.path, origPath: old, kind: .renamed, stage: .unstaged, modeIndex: "100644", modeWork: c.modeWork)
            }
            return c
        }
    }

    /// HEAD's version of the file (renames read their old path). Nil when it isn't in HEAD;
    /// any other git failure throws.
    func headText(_ change: FileChange) throws -> Data? {
        try show("HEAD:\(change.origPath ?? change.path)")
    }

    /// The index's version of the file (stage 0), or nil when it isn't in the index.
    func indexText(_ path: String) throws -> Data? {
        try show(":0:\(path)")
    }

    /// The blob as it would look on disk (`--filters` applies line-ending conversion and smudge
    /// filters), so it compares cleanly with the working file — as VS Code reads it.
    private func show(_ object: String) throws -> Data? {
        do {
            return try run(["cat-file", "--filters", object])
        } catch let e as GitError where ["does not exist", "exists on disk, but not in", "invalid object name",
                                         "Invalid object name", "not a valid object name", "Not a valid object name",
                                         "not in the index"].contains(where: e.stderr.contains) {
            return nil
        }
    }

    /// Files with a clean/smudge filter (e.g. LFS) or a working-tree encoding can't be staged
    /// section by section safely; they're staged whole from the file list.
    private func hasFilter(_ path: String) -> Bool {
        guard let out = try? run(["check-attr", "filter", "working-tree-encoding", "--", path]) else { return false }
        return String(decoding: out, as: UTF8.self).split(separator: "\n").contains { line in
            let value = line.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return !["unspecified", "unset", ""].contains(value)
        }
    }

    /// Stages whole files in one git command (deletions, renames and untracked files included).
    func stageFiles(_ changes: [FileChange]) throws {
        guard !changes.isEmpty else { return }
        _ = try run(["add", "-A", "--"] + Self.paths(changes))
    }

    /// Unstages whole files in one git command, keeping the working files as they are.
    func unstageFiles(_ changes: [FileChange]) throws {
        guard !changes.isEmpty else { return }
        // `restore --staged` fails on a repo with no commits yet; `rm --cached` covers that case.
        if (try? run(["rev-parse", "--verify", "-q", "HEAD"])) == nil {
            _ = try run(["rm", "--cached", "--quiet", "-r", "--ignore-unmatch", "--"] + Self.paths(changes))
        } else {
            _ = try run(["restore", "--staged", "--"] + Self.paths(changes))
        }
    }

    func stageFile(_ change: FileChange) throws { try stageFiles([change]) }
    func unstageFile(_ change: FileChange) throws { try unstageFiles([change]) }

    private static func paths(_ changes: [FileChange]) -> [String] {
        changes.flatMap { [$0.path] + ($0.origPath.map { [$0] } ?? []) } // a rename covers both sides
    }

    // MARK: Diffs and section staging (one actor call each, so nothing can interleave)

    enum DiffLoad: Sendable {
        case unchanged
        case document(DiffDocument)
    }

    /// Reads HEAD, the index and the working file for `change` and builds its diff.
    /// Returns `.unchanged` when the bytes match `previousSnapshot`, so nothing is recomputed.
    func loadDiff(_ change: FileChange, previousSnapshot: String? = nil) -> DiffLoad {
        if change.kind == .conflicted { return .document(.message(change, "Merge conflict. Resolve it, then review.")) }
        if [change.modeIndex, change.modeWork].contains("120000") {
            return .document(.message(change, "Symbolic link. Stage it from the file list."))
        }
        if [change.modeIndex, change.modeWork].contains("160000") {
            return .document(.message(change, "Submodule. Stage it from the file list."))
        }
        if hasFilter(change.path) {
            return .document(.message(change, "This file goes through a git filter (like LFS). Stage it from the file list."))
        }
        let head: Data?, index: Data?
        do {
            head = try headText(change)
            // An unstaged rename isn't in the index under its new name yet: use the old one's.
            index = try indexText(change.path) ?? (change.origPath != nil ? try indexText(change.origPath!) : nil)
        } catch {
            return .document(.message(change, "Couldn't read the file from git: \(error)"))
        }
        let work = (try? Data(contentsOf: root.appendingPathComponent(change.path))) ?? Data()
        let all = [head ?? Data(), index ?? Data(), work]
        let snapshot = SectionStaging.snapshot(head: head ?? Data(), index: index ?? Data(), work: work)
        if snapshot == previousSnapshot { return .unchanged }
        if all.contains(where: { $0.count > DiffDocument.maxBytes }) { return .document(.message(change, "File too large to compare (> 5 MB)")) }
        if all.contains(where: { $0.prefix(8000).contains(0) }) { return .document(.message(change, "Binary file")) }
        if all.contains(where: { String(data: $0, encoding: .utf8) == nil }) { return .document(.message(change, "Not UTF-8 text")) }
        let h = TextLines(head ?? Data()), w = TextLines(work)
        if h.count + w.count > DiffDocument.maxLines { return .document(.message(change, "File too large to compare (over 30,000 lines)")) }
        let staging = SectionStaging(head: h, index: TextLines(index ?? Data()), work: w)
        return .document(DiffDocument(change: change, staging: staging, message: nil, language: CodeLanguage(path: change.path)))
    }

    enum SectionOutcome: Sendable { case done, stale }

    /// Stages just some working-file lines (re-reads and refuses if anything changed since drawing).
    func stageLines(_ change: FileChange, lines: Range<Int>, expectedSnapshot: String) throws -> SectionOutcome {
        guard case .document(let doc) = loadDiff(change), let now = doc.staging, now.snapshotID == expectedSnapshot else { return .stale }
        guard change.kind != .deleted, FileManager.default.fileExists(atPath: root.appendingPathComponent(change.path).path) else { return .stale }
        if change.kind == .renamed && (try? indexText(change.path)) == nil {
            // As with sections: an unstaged rename is staged whole first (the old path's
            // removal has to go in with it), then by lines.
            try stageFiles([change])
            return .done
        }
        guard let mode = indexMode(change) else { return .stale }
        try writeIndex(path: change.path, text: now.indexText(stagingWorkLines: lines), mode: mode)
        return .done
    }

    /// The mode a partly staged file gets in the index: an untracked file's from the disk
    /// (executable or not), else the index's own. Nil for symlinks and submodules.
    private func indexMode(_ change: FileChange) -> String? {
        let mode = change.kind == .untracked
            ? (FileManager.default.isExecutableFile(atPath: root.appendingPathComponent(change.path).path) ? "100755" : "100644")
            : change.modeIndex
        return mode == "100644" || mode == "100755" ? mode : nil
    }

    /// Stages or unstages one section, re-reading everything and refusing if HEAD, the index or
    /// the working file changed since the diff the user clicked was drawn. Runs as one actor
    /// call, so no other git operation from Vet can slip in between the read and the write.
    func setSection(_ change: FileChange, hunkID: Int, staged: Bool, expectedSnapshot: String) throws -> SectionOutcome {
        guard case .document(let doc) = loadDiff(change), let now = doc.staging, now.snapshotID == expectedSnapshot,
              let hunk = now.hunks.first(where: { $0.id == hunkID }) else { return .stale }
        let workExists = FileManager.default.fileExists(atPath: root.appendingPathComponent(change.path).path)
        let unstagedRename = change.kind == .renamed && (try? indexText(change.path)) == nil
        if change.kind == .deleted || !workExists || unstagedRename {
            // Unstaged renames are staged whole first (as in Working Tree), then by section.
            // A deleted file (or one renamed and then deleted) is staged as a removal, never as empty text.
            if staged { try stageFiles([change]) } else { try unstageFiles([change]) }
            return .done
        }
        guard let mode = indexMode(change) else { return .stale }
        try writeIndex(path: change.path, text: now.indexText(setting: hunk, staged: staged), mode: mode)
        return .done
    }

    /// Replaces the index entry for `path` with `text`. Never touches the working file.
    func writeIndex(path: String, text: Data, mode: String) throws {
        let sha = String(decoding: try run(["hash-object", "-w", "--stdin", "--path", path], stdin: text), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(["update-index", "--add", "--cacheinfo", "\(mode),\(sha),\(path)"])
    }

    // MARK: Process

    private func run(_ args: [String], stdin: Data? = nil, env extra: [String: String] = [:]) throws -> Data {
        try Self.runSync(args, in: root, stdin: stdin, env: extra)
    }

    private static func runSync(_ args: [String], in dir: URL, stdin: Data? = nil, env extra: [String: String] = [:]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = args
        p.currentDirectoryURL = dir
        // Inherited GIT_DIR / GIT_INDEX_FILE etc. would point git somewhere else entirely.
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_OPTIONAL_LOCKS"] = "0" // status must not fight Claude's own git commands for the index lock
        env["GIT_LITERAL_PATHSPECS"] = "1" // `src/[id]/page.ts` is a path, never a pattern
        for (k, v) in extra { env[k] = v }
        env["LC_ALL"] = "C"
        p.environment = env
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
        try p.run()
        if let stdin {
            // SIGPIPE is ignored app-wide, so a git that exits early makes this throw instead of crashing Vet.
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        // Read stderr concurrently so a chatty command can't block on a full pipe.
        nonisolated(unsafe) var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        group.wait()
        guard p.terminationStatus == 0 else {
            throw GitError(args: args, status: p.terminationStatus, stderr: String(decoding: errData, as: UTF8.self))
        }
        return outData
    }
}
