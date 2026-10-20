import CoreServices
import Foundation

/// Watches a project folder with FSEvents and calls `onChange` (on the main thread) after
/// changes settle: 150 ms after the last event, or at least once a second during a long burst.
/// Inside the git directory only the index, HEAD, refs and the HEAD log count, so Vet notices
/// staging, commits and branch moves but not git's own housekeeping. Worktrees (where `.git`
/// is a file pointing elsewhere) have their git directory watched too.
@MainActor
final class RepoWatcher {
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void
    private let gitDir: String
    private var pending: DispatchWorkItem?
    /// FSEvents reports real paths (`/private/tmp/…` for `/tmp/…`), so ours must be real too.
    private static func realPath(_ url: URL) -> String {
        guard let p = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(p) }
        return String(cString: p)
    }
    /// Events that change a file's contents or existence. Inside the git directory only these
    /// count: git also clones the index (Vet's own rename pairing does) and refreshes object
    /// times, and neither is a change.
    private var burstStart: Date?
    /// The project's own .vet folder (Vet's review marks and notes): writes there aren't changes.
    private var vetDir = ""

    init(root: URL, gitDir: URL, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        self.gitDir = Self.realPath(gitDir)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let events = (0..<min(count, list.count)).map { (list[$0], flags[$0]) }
            MainActor.assumeIsolated { watcher.received(events) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        let rootPath = Self.realPath(root)
        vetDir = rootPath + "/.vet"
        var paths = [rootPath]
        if !self.gitDir.hasPrefix(rootPath + "/") { paths.append(self.gitDir) }
        stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private static let contentFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
        | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified)
    private static let itemFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsDir
        | kFSEventStreamEventFlagItemIsSymlink)

    private func received(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        let relevant = events.contains { p, flags in
            // .gitignore, .github/ are ordinary files; Vet's own .vet folder isn't a change to review.
            guard p.hasPrefix(gitDir + "/") else { return !p.contains("/node_modules/") && !p.hasPrefix(vetDir + "/") && p != vetDir }
            // A rescan request names no item: count it. A file event must change contents.
            if flags & Self.itemFlags != 0 && flags & Self.contentFlags == 0 { return false }
            let rest = p.dropFirst(gitDir.count)
            return rest == "/index" || rest == "/HEAD" || rest == "/logs/HEAD" || rest.hasPrefix("/refs/") || rest == "/packed-refs"
        }
        guard relevant else { return }
        pending?.cancel()
        let now = Date()
        if burstStart == nil { burstStart = now }
        let fireNow = now.timeIntervalSince(burstStart!) > 1
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.burstStart = nil
                self?.onChange()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (fireNow ? 0 : 0.15), execute: work)
    }
}
