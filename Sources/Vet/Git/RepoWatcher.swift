import CoreServices
import Foundation

/// Watches a project folder with FSEvents and calls `onChange` (on the main thread) after
/// changes settle: 150 ms after the last event, or at least once a second during a long burst.
/// Inside `.git/` only the index and HEAD count, so Vet notices staging and commits but not
/// git's own housekeeping.
@MainActor
final class RepoWatcher {
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void
    private let gitDir: String
    private var pending: DispatchWorkItem?
    private var burstStart: Date?

    init(root: URL, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        gitDir = root.appendingPathComponent(".git").path
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            MainActor.assumeIsolated { watcher.received(Array(list.prefix(count))) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
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

    private func received(_ paths: [String]) {
        let relevant = paths.contains { p in
            guard p.hasPrefix(gitDir) else { return !p.contains("/node_modules/") }
            let rest = p.dropFirst(gitDir.count)
            return rest == "/index" || rest == "/HEAD"
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
