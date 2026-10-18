import AppKit

/// Test aid, off unless Vet is launched with VET_SNAPSHOT_DIR set: on the distributed
/// notification "dev.vet.snapshot" it renders the main window (offscreen, at full size, even
/// when Stage Manager has it shrunk in the strip) into VET_SNAPSHOT_DIR/window.png.
@MainActor
enum SnapshotHook {
    static var isTesting: Bool { ProcessInfo.processInfo.environment["VET_SNAPSHOT_DIR"] != nil }

    static func install() {
        guard let dir = ProcessInfo.processInfo.environment["VET_SNAPSHOT_DIR"] else { return }
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.vet.snapshot"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("window.png")) }
        }
    }

    private static func snapshot(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
              let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
