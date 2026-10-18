import AppKit

/// Test aid, off unless Vet is launched with VET_SNAPSHOT_DIR set: on the distributed
/// notification "dev.vet.snapshot" it renders the main window (offscreen, at full size, even
/// when Stage Manager has it shrunk in the strip) into VET_SNAPSHOT_DIR/window.png.
@MainActor
enum SnapshotHook {
    static var isTesting: Bool { ProcessInfo.processInfo.environment["VET_SNAPSHOT_DIR"] != nil }
    /// The throwaway project a test run must use (VET_PROJECT).
    static var testProject: URL? { ProcessInfo.processInfo.environment["VET_PROJECT"].map { URL(fileURLWithPath: $0, isDirectory: true) } }

    static func install() {
        guard let dir = ProcessInfo.processInfo.environment["VET_SNAPSHOT_DIR"] else { return }
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.vet.snapshot"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("window.png")) }
        }
    }

    private static func snapshot(to url: URL) {
        // The main window, then any popover or panel windows as window-1.png, window-2.png…
        let windows = NSApp.windows.filter { w in
            w.contentView != nil && w.frame.width > 60 && (w.isVisible || String(describing: type(of: w)).contains("Popover"))
        }
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        let dir = url.deletingLastPathComponent()
        let inventory = NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) frame=\($0.frame) content=\($0.contentView != nil)" }.joined(separator: "\n")
        try? inventory.write(to: dir.appendingPathComponent("windows.txt"), atomically: true, encoding: .utf8)
        for old in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where old.hasPrefix("window-") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(old))
        }
        for (i, window) in windows.enumerated() {
            guard let frameView = window.contentView?.superview ?? window.contentView,
                  let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { continue }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            let out = i == 0 ? url : dir.appendingPathComponent("window-\(i).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: out)
        }
    }
}
