import Foundation
import VetCore

/// Find in Files for one folder. In a git work tree it runs `git grep` over tracked and untracked
/// files, minus ignored and binary ones; in any other folder it walks the files (skipping
/// dependency and build folders) and searches them in Swift. Either way the match ranges come
/// from `FindMatcher`, so highlighting is the same.
actor TextSearch {
    nonisolated let root: URL
    private nonisolated let engine: TextSearchEngine

    init(root: URL) {
        self.root = root
        engine = TextSearchEngine(root: root)
    }

    /// Streams batches of matches; stops at `limit`. Cancelling the consuming Task terminates git.
    /// An empty query finishes at once; an invalid regex finishes with `FindError.invalidRegex`.
    nonisolated func search(_ query: FindQuery, limit: Int = 2000) -> AsyncThrowingStream<[FindMatch], Error> {
        let engine = self.engine
        return AsyncThrowingStream { continuation in
            let run = SearchRun()
            continuation.onTermination = { _ in run.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try engine.search(query, limit: limit, run: run) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// One search's process and cancellation flag, shared with the stream's termination handler.
private final class SearchRun: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    /// Starts `p` unless the search was already cancelled.
    func launch(_ p: Process) throws -> Bool {
        try lock.withLock {
            if cancelled { return false }
            try p.run()
            process = p
            return true
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let p = process, p.isRunning { p.terminate() }
        }
    }
}

/// Batches matches: the first as soon as there is one, then every 50 ms or 256 matches.
private struct MatchBatcher {
    let limit: Int
    let emit: ([FindMatch]) -> Void
    private var pending: [FindMatch] = []
    private var sent = 0
    private var lastFlush = DispatchTime.now()

    init(limit: Int, emit: @escaping ([FindMatch]) -> Void) {
        self.limit = limit
        self.emit = emit
    }

    var isFull: Bool { sent + pending.count >= limit }
    var room: Int { max(0, limit - sent - pending.count) }

    /// Adds matches up to the limit.
    mutating func add(_ matches: some Collection<FindMatch>) {
        pending.append(contentsOf: matches.prefix(room))
    }

    mutating func flushIfDue() {
        guard !pending.isEmpty else { return }
        let now = DispatchTime.now()
        if sent == 0 || pending.count >= 256 || now.uptimeNanoseconds - lastFlush.uptimeNanoseconds >= 50_000_000 {
            flush(now)
        }
    }

    mutating func flush(_ now: DispatchTime = .now()) {
        guard !pending.isEmpty else { return }
        emit(pending)
        sent += pending.count
        pending = []
        lastFlush = now
    }
}

private final class TextSearchEngine: Sendable {
    enum Mode: Sendable { case git(pcre: Bool), walk }

    let root: URL
    private let cache = Cache()

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var mode: Mode?
    }

    private struct NoPCRE: Error {}

    init(root: URL) { self.root = root }

    func search(_ query: FindQuery, limit: Int, run: SearchRun, emit: @escaping ([FindMatch]) -> Void) throws {
        let matcher: FindMatcher
        do {
            matcher = try FindMatcher(query)
        } catch FindError.emptyQuery {
            return
        }
        guard limit > 0 else { return }
        let mode = cache.lock.withLock { cache.mode } ?? {
            let m: Mode = GitRepo.root(containing: root) == nil ? .walk : .git(pcre: true)
            cache.lock.withLock { cache.mode = m }
            return m
        }()
        var batcher = MatchBatcher(limit: limit, emit: emit)
        switch mode {
        case .walk:
            walk(matcher, run: run, batcher: &batcher)
        case .git(let pcre):
            do {
                try grep(matcher, pcre: pcre, run: run, batcher: &batcher)
            } catch is NoPCRE {
                cache.lock.withLock { cache.mode = .git(pcre: false) }
                try grep(matcher, pcre: false, run: run, batcher: &batcher)
            }
        }
        batcher.flush()
    }

    // MARK: git grep

    private func grep(_ matcher: FindMatcher, pcre: Bool, run: SearchRun, batcher: inout MatchBatcher) throws {
        let query = matcher.query
        // grep.fullName off: paths stay relative to the folder even if a config says otherwise.
        var args = ["-c", "grep.fullName=false", "grep", "-n", "-I", "--untracked", "--exclude-standard", "-z", "--no-color"]
        if !query.caseSensitive { args.append("-i") }
        if query.wholeWord { args.append("-w") }
        // Perl regexes agree with ICU (NSRegularExpression) on \d \w \b and lookaround; POSIX ERE doesn't.
        args.append(query.regex ? (pcre ? "-P" : "-E") : "-F")
        args += ["-e", query.text, "--"]

        let p = Process()
        p.executableURL = URL(fileURLWithPath: GitRepo.gitPath)
        p.arguments = args
        p.currentDirectoryURL = root
        // As GitRepo.runSync: inherited GIT_DIR etc. would point git elsewhere.
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_LITERAL_PATHSPECS"] = "1"
        env["LC_ALL"] = "en_US.UTF-8" // -i folds non-ASCII letters (é/É) only in a UTF-8 locale
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do {
            guard try run.launch(p) else { return }
        } catch {
            throw FindError.failed("couldn't run git: \(error.localizedDescription)")
        }
        // Read stderr concurrently so a chatty git can't block on a full pipe.
        nonisolated(unsafe) var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        var splitter = GrepOutputParser.RecordSplitter()
        let reader = out.fileHandleForReading
        while !batcher.isFull {
            let chunk = reader.availableData
            let records = chunk.isEmpty ? splitter.finish() : splitter.append(chunk)
            batcher.add(records.lazy.compactMap { matcher.match(path: $0.path, line: $0.line, text: $0.text) })
            batcher.flushIfDue()
            if chunk.isEmpty { break }
        }
        let stoppedEarly = batcher.isFull
        if stoppedEarly { run.cancel() } // enough: stop git
        p.waitUntilExit()
        group.wait()
        if stoppedEarly || run.isCancelled { return }
        switch p.terminationStatus {
        case 0, 1: return // matches / no matches
        default:
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if query.regex && pcre && (message.contains("USE_LIBPCRE") || message.contains("not compiled")) { throw NoPCRE() }
            // E.g. a regex ICU accepts and PCRE doesn't: git's own message says why.
            throw FindError.failed(message.isEmpty ? "git grep exited with \(p.terminationStatus)" : message)
        }
    }

    // MARK: Plain folders

    static let skippedFolders: Set<String> = [".git", ".hg", ".svn", "node_modules", ".venv", "venv", "__pycache__", "build", "dist",
                                              ".build", ".gradle", ".idea", "target", ".angular", ".next", "DerivedData", "Pods", ".swiftpm"]
    static let maxFileBytes = 10 << 20

    private func walk(_ matcher: FindMatcher, run: SearchRun, batcher: inout MatchBatcher) {
        for path in listFiles(run: run) {
            if run.isCancelled || batcher.isFull { return }
            let url = root.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= Self.maxFileBytes,
                  !data.prefix(8000).contains(0) else { continue } // binary, like git's -I
            batcher.add(matcher.search(path: path, text: String(decoding: data, as: UTF8.self), limit: batcher.room))
            batcher.flushIfDue()
        }
    }

    /// Files under the root in path order, skipping dependency and build folders.
    private func listFiles(run: SearchRun) -> [String] {
        let base = root.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { return [] }
        var result: [String] = []
        for case let url as URL in e {
            if run.isCancelled { return [] }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if Self.skippedFolders.contains(url.lastPathComponent) { e.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            result.append(String(path.dropFirst(base.count + 1)))
            if result.count >= 200_000 { break }
        }
        return result.sorted()
    }
}
