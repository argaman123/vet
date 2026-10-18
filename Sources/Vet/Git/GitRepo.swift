import CryptoKit
import Foundation
import VetCore

struct GitError: Error, CustomStringConvertible {
    let args: [String]
    let status: Int32
    let stderr: String
    /// Some refusals print only here (`commit` says "nothing to commit" on stdout).
    var stdout: String = ""
    var description: String { "git \(args.joined(separator: " ")) failed (\(status)): \(stderr)" }
}

/// A commit or push git refused, in one sentence for an alert, plus git's own output
/// (a hook's output included) for the details.
struct GitActionError: Error, CustomStringConvertible, Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        case emptyMessage, nothingToCommit, noIdentity, unmergedFiles, hookFailed
        case detachedHead, noRemote, pushRejected, remoteRejected, needsCredentials, cantReachRemote
        case failed
    }
    let reason: Reason
    let message: String
    let output: String

    init(_ reason: Reason, _ message: String, output: String = "") {
        self.reason = reason
        self.message = message
        self.output = output
    }

    var description: String { output.isEmpty ? message : "\(message)\n\n\(output)" }
}

struct GitBranch: Sendable, Hashable {
    /// "main" for a local branch, "origin/feature" for a remote one.
    let name: String
    let isCurrent: Bool
    let isRemote: Bool
    /// The upstream's short name ("origin/main"); nil when it has none (always nil for remotes).
    let upstream: String?
    /// The tip's committer date; nil for a branch with no commits yet.
    let lastCommitDate: Date?
}

enum CheckoutOutcome: Sendable, Equatable {
    case done
    /// Git refused: switching would overwrite these uncommitted or untracked files.
    case wouldOverwrite(paths: [String])
    /// Git refused for another reason; its own message.
    case failed(String)
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

    // MARK: Branches

    /// The checked-out branch; nil when HEAD is detached. A branch with no commits yet counts.
    func currentBranch() throws -> String? {
        let ref: String
        do {
            ref = String(decoding: try run(["symbolic-ref", "-q", "HEAD"]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let e as GitError where e.status == 1 {
            return nil // detached
        }
        return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : nil
    }

    /// Local branches (the current one first, then the most recently committed), then the remote
    /// branches no local branch tracks or shares a name with.
    func branches() throws -> [GitBranch] {
        let out = String(decoding: try run(["for-each-ref", "--sort=-committerdate",
                                            "--format=%(refname)%00%(HEAD)%00%(upstream:short)%00%(committerdate:unix)%00%(symref)",
                                            "refs/heads", "refs/remotes"]), as: UTF8.self)
        var local: [GitBranch] = [], remote: [GitBranch] = []
        for line in out.split(separator: "\n") {
            let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5, f[4].isEmpty else { continue } // refs/remotes/origin/HEAD is a symref
            let date = Double(f[3]).map { Date(timeIntervalSince1970: $0) }
            if f[0].hasPrefix("refs/heads/") {
                local.append(GitBranch(name: String(f[0].dropFirst("refs/heads/".count)), isCurrent: f[1] == "*",
                                       isRemote: false, upstream: f[2].isEmpty ? nil : f[2], lastCommitDate: date))
            } else if f[0].hasPrefix("refs/remotes/") {
                remote.append(GitBranch(name: String(f[0].dropFirst("refs/remotes/".count)), isCurrent: false,
                                        isRemote: true, upstream: nil, lastCommitDate: date))
            }
        }
        let remotes = try remoteNames()
        let tracked = Set(local.compactMap(\.upstream)), localNames = Set(local.map(\.name))
        remote.removeAll { tracked.contains($0.name) || localNames.contains(Self.branchName(remoteBranch: $0.name, remotes: remotes)) }
        if let i = local.firstIndex(where: \.isCurrent) {
            local.insert(local.remove(at: i), at: 0)
        } else if let unborn = try currentBranch() { // no commits yet, so no ref to list
            local.insert(GitBranch(name: unborn, isCurrent: true, isRemote: false, upstream: nil, lastCommitDate: nil), at: 0)
        }
        return local + remote
    }

    private func remoteNames() throws -> [String] {
        String(decoding: try run(["remote"]), as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// "origin/feature" → "feature" (remote names may themselves contain slashes).
    private static func branchName(remoteBranch: String, remotes: [String]) -> String {
        if let r = remotes.filter({ remoteBranch.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
            return String(remoteBranch.dropFirst(r.count + 1))
        }
        return remoteBranch.split(separator: "/", maxSplits: 1).last.map(String.init) ?? remoteBranch
    }

    private func refExists(_ ref: String) throws -> Bool {
        do {
            _ = try run(["show-ref", "--verify", "--quiet", ref])
            return true
        } catch let e as GitError where e.status == 1 {
            return false
        }
    }

    /// Switches to `branch` with `git switch`, never forced: git itself refuses when uncommitted
    /// or untracked files would be overwritten, and other changes carry over. A remote branch
    /// ("origin/feature") switches to the local branch tracking it, or creates one (`--track`).
    func checkout(_ branch: String) async throws -> CheckoutOutcome {
        guard !branch.isEmpty, !branch.hasPrefix("-") else { return .failed("“\(branch)” isn't a branch name.") }
        let env = await actionEnvironment()
        var args = ["switch", branch]
        if try !refExists("refs/heads/\(branch)"), try refExists("refs/remotes/\(branch)") {
            let out = String(decoding: try run(["for-each-ref", "--format=%(refname)%00%(upstream)", "refs/heads"]), as: UTF8.self)
            let twin = out.split(separator: "\n").map { $0.split(separator: "\0", omittingEmptySubsequences: false) }
                .first { $0.count == 2 && $0[1] == "refs/remotes/\(branch)" }
            args = twin.map { ["switch", String($0[0].dropFirst("refs/heads/".count))] } ?? ["switch", "--track", branch]
        }
        do {
            _ = try runAction(args, env: env)
            return .done
        } catch let e as GitError {
            let paths = Self.overwrittenPaths(e.stderr)
            if !paths.isEmpty { return .wouldOverwrite(paths: paths) }
            let text = e.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(text.isEmpty ? "git switch failed (\(e.status))." : text)
        }
    }

    /// The tab-indented paths under each "… would be overwritten by checkout:" (or "removed")
    /// heading; git prints them unquoted.
    static func overwrittenPaths(_ stderr: String) -> [String] {
        var paths: [String] = [], inList = false
        for line in stderr.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\t") {
                if inList { paths.append(String(line.dropFirst())) }
            } else {
                inList = (line.contains("would be overwritten by") || line.contains("would be removed by")) && line.hasSuffix(":")
            }
        }
        return paths
    }

    // MARK: Commit and push

    /// The full message of HEAD's commit (prefills "Amend last commit"); nil before the first commit.
    func lastCommitMessage() throws -> String? {
        guard try headSHA() != nil else { return nil }
        var message = String(decoding: try run(["-c", "i18n.logOutputEncoding=UTF-8", "log", "-1", "--no-show-signature",
                                                "--format=%B", "HEAD"]), as: UTF8.self)
        while message.last?.isWhitespace == true { message.removeLast() }
        return message
    }

    /// Commits the index (what's staged) and returns the new commit's short sha. An empty message
    /// is refused, except when amending, which then keeps the last commit's message. Hooks run;
    /// when one stops the commit, its output comes back in the error.
    func commit(message: String, amend: Bool) async throws -> String {
        let keepMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if keepMessage && !amend { throw GitActionError(.emptyMessage, "Write a commit message first.") }
        let env = await actionEnvironment()
        // useConfigOnly: commit as the configured user, never one guessed from the host name (as VS Code).
        var args = ["-c", "user.useConfigOnly=true", "commit", "--quiet"]
        if amend { args.append("--amend") }
        args += keepMessage ? ["--no-edit"] : ["--file", "-"]
        do {
            _ = try runAction(args, stdin: keepMessage ? nil : Data(message.utf8), env: env)
        } catch let e as GitError {
            throw try commitError(e)
        }
        return String(decoding: try run(["rev-parse", "--short", "HEAD"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitError(_ e: GitError) throws -> GitActionError {
        let output = Self.output(e)
        let has = { (s: String) in e.stderr.contains(s) || e.stdout.contains(s) }
        if has("nothing to commit") || has("nothing added to commit") || has("no changes added to commit") {
            return GitActionError(.nothingToCommit, "Nothing is staged to commit.", output: output)
        }
        if has("Aborting commit due to empty commit message") {
            return GitActionError(.emptyMessage, "Write a commit message first.", output: output)
        }
        if ["Please tell me who you are", "Author identity unknown", "no email was given", "no name was given",
            "empty ident name"].contains(where: has) {
            return GitActionError(.noIdentity, "Git doesn't know who you are. Set user.name and user.email (git config --global), then commit again.", output: output)
        }
        if has("unmerged files") || has("unresolved conflict") {
            return GitActionError(.unmergedFiles, "Resolve the merge conflicts first.", output: output)
        }
        if has("You have nothing to amend") {
            return GitActionError(.failed, "There's no commit to amend yet.", output: output)
        }
        let hooks = try installedHooks(["pre-commit", "prepare-commit-msg", "commit-msg"])
        if !hooks.isEmpty {
            let which = hooks.count == 1 ? "The \(hooks[0]) hook" : "A commit hook (\(hooks.joined(separator: ", ")))"
            return GitActionError(.hookFailed, "\(which) stopped the commit.", output: output)
        }
        return GitActionError(.failed, "Git couldn't commit.", output: output)
    }

    /// Pushes the current branch to its upstream, or with `-u` to origin (the remote, when
    /// there's just one) when it has none yet. Returns git's summary line ("a1b2c3d..e4f5a6b  main -> main").
    func push() async throws -> String {
        let env = await actionEnvironment()
        guard let branch = try currentBranch() else {
            throw GitActionError(.detachedHead, "You're not on a branch (detached HEAD), so there's nothing to push.")
        }
        let remotes = try remoteNames()
        guard !remotes.isEmpty else {
            throw GitActionError(.noRemote, "This repository has no remote to push to. Add one with git remote add origin <url>.")
        }
        let out = String(decoding: try run(["for-each-ref", "--format=%(refname)%00%(upstream:remotename)%00%(upstream:remoteref)",
                                            "refs/heads/\(branch)"]), as: UTF8.self)
        let upstream = out.split(separator: "\n").map { $0.split(separator: "\0", omittingEmptySubsequences: false).map(String.init) }
            .first { $0.count == 3 && $0[0] == "refs/heads/\(branch)" }
        let args: [String]
        let remote: String
        if let u = upstream, !u[1].isEmpty, u[1] != ".", !u[2].isEmpty {
            // Explicit refspec, as VS Code: works even when the upstream's name differs from the branch's.
            remote = u[1]
            args = ["push", remote, "refs/heads/\(branch):\(u[2])"]
        } else {
            let pushDefault = (try? run(["config", "--get", "remote.pushDefault"]))
                .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            if let d = pushDefault, remotes.contains(d) { remote = d }
            else if remotes.contains("origin") { remote = "origin" }
            else if remotes.count == 1 { remote = remotes[0] }
            else {
                throw GitActionError(.noRemote, "\(branch) has no upstream and there's no remote named origin (remotes: \(remotes.joined(separator: ", "))).")
            }
            args = ["push", "-u", remote, "HEAD"]
        }
        do {
            let (_, err) = try runAction(args, env: env)
            return Self.pushSummary(err)
        } catch let e as GitError {
            throw try pushError(e, remote: remote)
        }
    }

    private static func pushSummary(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let ref = lines.first(where: { $0.contains(" -> ") }) { return ref }
        return lines.first(where: { $0.hasPrefix("Everything up-to-date") }) ?? lines.last ?? "Pushed."
    }

    private func pushError(_ e: GitError, remote: String) throws -> GitActionError {
        let output = Self.output(e)
        let lines = e.stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let line = lines.first(where: { $0.hasPrefix("! [remote rejected]") }) {
            let reason = line.range(of: "(").map { String(line[$0.lowerBound...]) } ?? ""
            return GitActionError(.remoteRejected, "\(remote) refused the push \(reason).".replacingOccurrences(of: "  ", with: " "), output: output)
        }
        if let line = lines.first(where: { $0.hasPrefix("! [rejected]") }) {
            let message = line.contains("(fetch first)") ? "\(remote) has commits you don't have yet. Pull them, then push again."
                : line.contains("(non-fast-forward)") ? "Your branch is behind \(remote). Pull first, then push again."
                : "\(remote) rejected the push."
            return GitActionError(.pushRejected, message, output: output)
        }
        if ["Authentication failed", "could not read Username", "could not read Password", "terminal prompts disabled",
            "Permission denied (publickey", "Host key verification failed"].contains(where: e.stderr.contains) {
            return GitActionError(.needsCredentials, "\(remote) needs credentials Vet can't ask for. Push once from Terminal (or set up a credential helper or SSH key), then try again.", output: output)
        }
        if ["Could not read from remote repository", "Permission denied", "unable to access", "Could not resolve host",
            "does not appear to be a git repository", "Connection refused", "timed out"].contains(where: e.stderr.contains) {
            return GitActionError(.cantReachRemote, "Couldn't reach \(remote). Check the connection and your credentials.", output: output)
        }
        if e.stderr.contains("No configured push destination") {
            return GitActionError(.noRemote, "This repository has no remote to push to.", output: output)
        }
        if try !installedHooks(["pre-push"]).isEmpty {
            return GitActionError(.hookFailed, "The pre-push hook stopped the push.", output: output)
        }
        return GitActionError(.failed, "Git couldn't push.", output: output)
    }

    /// The named hooks that exist and are executable (wherever core.hooksPath points).
    private func installedHooks(_ names: [String]) throws -> [String] {
        let out = String(decoding: try run(["rev-parse"] + names.flatMap { ["--git-path", "hooks/\($0)"] }), as: UTF8.self)
        let paths = out.split(separator: "\n").map(String.init)
        return zip(names, paths).filter { _, path in
            FileManager.default.isExecutableFile(atPath: path.hasPrefix("/") ? path : root.appendingPathComponent(path).path)
        }.map(\.0)
    }

    private static func output(_ e: GitError) -> String {
        [e.stderr, e.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// HEAD's commit sha; nil before the first commit.
    private func headSHA() throws -> String? {
        do {
            return String(decoding: try run(["rev-parse", "-q", "--verify", "HEAD^{commit}"]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let e as GitError where e.status == 1 {
            return nil
        }
    }

    // MARK: Blame

    private struct BlameKey: Hashable {
        let path: String
        let text: SHA256.Digest
    }
    /// Blame results for HEAD `blameHead`, most recently used last; one entry per path.
    private var blameCache: [BlameKey: [BlameLine]] = [:]
    private var blameOrder: [BlameKey] = []
    private var blameHead: String?
    private var blameStamp: [String] = []
    private static let blameCacheEntries = 32, blameCacheLines = 200_000

    /// Who last changed each line of `path` as `workingText` has it (nil: the file on disk). Lines
    /// not committed yet (unsaved, unstaged or staged) are `isUncommitted`; so is every line of an
    /// untracked file or a repo with no commits. Cached per text until HEAD moves.
    func blame(path: String, workingText: Data?) throws -> [BlameLine] {
        let text = try workingText ?? Data(contentsOf: root.appendingPathComponent(path))
        let stamp = try headStamp() // taken before rev-parse: a move in between just re-checks next time
        if stamp != blameStamp {
            let head = try headSHA()
            if head != blameHead {
                blameCache.removeAll()
                blameOrder.removeAll()
                blameHead = head
            }
            blameStamp = stamp
        }
        let head = blameHead
        let key = BlameKey(path: path, text: SHA256.hash(data: text))
        if let hit = blameCache[key] {
            blameOrder.removeAll { $0 == key }
            blameOrder.append(key)
            return hit
        }
        let lines: [BlameLine]
        if head == nil {
            lines = BlamePorcelainParser.uncommitted(text, at: Date())
        } else {
            do {
                // Always from stdin, so what's blamed is exactly what was hashed.
                lines = BlamePorcelainParser.parse(try run(["-c", "i18n.logOutputEncoding=UTF-8", "blame", "--line-porcelain",
                                                            "--contents", "-", "--", path], stdin: text))
            } catch let e as GitError where e.stderr.contains("no such path") || e.stderr.contains("no such ref") {
                lines = BlamePorcelainParser.uncommitted(text, at: Date()) // untracked
            }
        }
        for old in blameOrder where old.path == path { blameCache[old] = nil }
        blameOrder.removeAll { $0.path == path }
        blameCache[key] = lines
        blameOrder.append(key)
        while blameOrder.count > 1 && (blameOrder.count > Self.blameCacheEntries
                                       || blameCache.values.reduce(0) { $0 + $1.count } > Self.blameCacheLines) {
            blameCache[blameOrder.removeFirst()] = nil
        }
        return lines
    }

    /// For the "N usages · author" lens: whoever made the most recent commit touching `lines`
    /// (1-based); "You" when any of them isn't committed yet. Nil when no line is in range.
    func lastAuthor(path: String, lines: ClosedRange<Int>, workingText: Data?) throws -> (author: String, date: Date)? {
        try lastAuthors(path: path, ranges: [lines], workingText: workingText)[0]
    }

    /// `lastAuthor` for several declarations of one file in one call (one HEAD check, one lookup).
    func lastAuthors(path: String, ranges: [ClosedRange<Int>], workingText: Data?) throws -> [(author: String, date: Date)?] {
        let blamed = try blame(path: path, workingText: workingText)
        return ranges.map { range in
            // Blame lists every line once, in order, so line n sits at n - 1.
            let lo = max(1, range.lowerBound), hi = min(blamed.count, range.upperBound)
            guard lo <= hi else { return nil }
            let touched = blamed[lo - 1].line == lo && blamed[hi - 1].line == hi
                ? Array(blamed[(lo - 1)..<hi]) : blamed.filter { range.contains($0.line) }
            if let mine = touched.first(where: \.isUncommitted) { return ("You", mine.authorTime) }
            return touched.max { $0.authorTime < $1.authorTime }.map { ($0.author, $0.authorTime) }
        }
    }

    /// Stats of the files any move of HEAD rewrites (HEAD, its reflog, the branch's loose ref,
    /// packed-refs, reftable's table list). While they're unchanged HEAD is too, so a blame cache
    /// hit needs no `rev-parse`; a lens per declaration would otherwise spawn git for each one.
    private func headStamp() throws -> [String] {
        if gitDirs == nil {
            let out = String(decoding: try run(["rev-parse", "--absolute-git-dir", "--git-common-dir"]), as: UTF8.self)
                .split(separator: "\n").map(String.init)
            let git = out.first ?? root.appendingPathComponent(".git").path
            let common = out.count > 1 ? out[1] : git
            gitDirs = (git, common.hasPrefix("/") ? common : root.appendingPathComponent(common).standardizedFileURL.path)
        }
        let (git, common) = gitDirs!
        let head = (try? String(contentsOfFile: git + "/HEAD", encoding: .utf8)) ?? ""
        var files = [git + "/HEAD", git + "/logs/HEAD", common + "/packed-refs", common + "/reftable/tables.list"]
        if head.hasPrefix("ref: ") { files.append(common + "/" + head.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)) }
        return [head] + files.map { path in
            var st = stat()
            guard stat(path, &st) == 0 else { return "-" }
            return "\(st.st_ino) \(st.st_size) \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        }
    }
    private var gitDirs: (git: String, common: String)?

    // MARK: Process

    /// For commands that run hooks or reach a remote: the user's login-shell environment (hooks
    /// need its PATH for husky's node, git-lfs, credential helpers), and never a prompt, since no
    /// one could answer it and a waiting git would hold this actor (and every refresh) forever.
    private func actionEnvironment() async -> (base: [String: String], extra: [String: String]) {
        let base = await ShellEnvironment.load()
        var extra = ["GIT_TERMINAL_PROMPT": "0"]
        if (try? run(["config", "--get", "core.sshCommand"])) == nil { extra["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        return (base, extra)
    }

    /// Runs with `actionEnvironment()`; returns stdout and stderr (push reports on stderr).
    private func runAction(_ args: [String], stdin: Data? = nil,
                           env: (base: [String: String], extra: [String: String])) throws -> (out: String, err: String) {
        let r = try Self.execute(args, in: root, stdin: stdin, base: env.base, env: env.extra)
        let out = String(decoding: r.out, as: UTF8.self), err = String(decoding: r.err, as: UTF8.self)
        guard r.status == 0 else { throw GitError(args: args, status: r.status, stderr: err, stdout: out) }
        return (out, err)
    }

    private func run(_ args: [String], stdin: Data? = nil, env extra: [String: String] = [:]) throws -> Data {
        try Self.runSync(args, in: root, stdin: stdin, env: extra)
    }

    private static func runSync(_ args: [String], in dir: URL, stdin: Data? = nil, env extra: [String: String] = [:]) throws -> Data {
        let r = try execute(args, in: dir, stdin: stdin, base: nil, env: extra)
        guard r.status == 0 else {
            throw GitError(args: args, status: r.status, stderr: String(decoding: r.err, as: UTF8.self),
                           stdout: String(decoding: r.out, as: UTF8.self))
        }
        return r.out
    }

    private static func execute(_ args: [String], in dir: URL, stdin: Data?, base: [String: String]?,
                                env extra: [String: String]) throws -> (status: Int32, out: Data, err: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = args
        p.currentDirectoryURL = dir
        // Inherited GIT_DIR / GIT_INDEX_FILE etc. would point git somewhere else entirely.
        var env = (base ?? ProcessInfo.processInfo.environment).filter { !$0.key.hasPrefix("GIT_") }
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
        return (p.terminationStatus, outData, errData)
    }
}
