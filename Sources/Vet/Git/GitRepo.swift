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

    func status() throws -> [FileChange] {
        StatusParser.parse(try run(["status", "--porcelain=v2", "-z", "--untracked-files=all", "--find-renames"]))
    }

    /// HEAD's version of the file. Renames read their old path. Nil when it isn't in HEAD.
    func headText(_ change: FileChange) throws -> Data? {
        try? run(["show", "HEAD:\(change.origPath ?? change.path)"])
    }

    /// The index's version of the file, or nil when it isn't in the index.
    func indexText(_ path: String) throws -> Data? {
        try? run(["show", ":\(path)"])
    }

    func stageFile(_ change: FileChange) throws {
        if change.kind == .deleted {
            _ = try run(["rm", "--cached", "--quiet", "--", change.path])
        } else {
            var paths = [change.path]
            if let orig = change.origPath { paths.append(orig) } // a rename stages both sides
            _ = try run(["add", "-A", "--"] + paths)
        }
    }

    func unstageFile(_ change: FileChange) throws {
        var paths = [change.path]
        if let orig = change.origPath { paths.append(orig) }
        // `restore --staged` fails on a repo with no commits yet; `rm --cached` covers that case.
        if (try? run(["rev-parse", "--verify", "-q", "HEAD"])) == nil {
            _ = try run(["rm", "--cached", "--quiet", "-r", "--"] + paths)
        } else {
            _ = try run(["restore", "--staged", "--"] + paths)
        }
    }

    /// Replaces the index entry for `path` with `text`. Never touches the working file.
    func writeIndex(path: String, text: Data, mode: String) throws {
        let sha = String(decoding: try run(["hash-object", "-w", "--stdin", "--path", path], stdin: text), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(["update-index", "--add", "--cacheinfo", "\(mode),\(sha),\(path)"])
    }

    // MARK: Process

    private func run(_ args: [String], stdin: Data? = nil) throws -> Data {
        try Self.runSync(args, in: root, stdin: stdin)
    }

    private static func runSync(_ args: [String], in dir: URL, stdin: Data? = nil) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0" // status must not fight Claude's own git commands for the index lock
        env["LC_ALL"] = "C"
        p.environment = env
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
        try p.run()
        if let stdin {
            inPipe.fileHandleForWriting.write(stdin)
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
