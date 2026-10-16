import AppKit
import SwiftUI
import VetCore

/// The single maximized Vet window, with the rail panel attached on its left edge.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let rail: RailPanel
    /// Called (at most ~60×/s) whenever the window moves or resizes, so Claude can follow.
    var onFrameChange: (() -> Void)?
    /// Called after Vet's window enters (true) or leaves (false) native full screen.
    var onFullScreenChange: ((Bool) -> Void)?

    var isFullScreen: Bool { window.styleMask.contains(.fullScreen) }

    init(state: ShellState, content: some View, onSelect: @escaping (RailTab) -> Void) {
        let screen = NSScreen.screens[0]
        window = NSWindow(contentRect: screen.visibleFrame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        rail = RailPanel(state: state, onSelect: onSelect)
        super.init()

        window.title = "Vet"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        host.sizingOptions = [] // the window stays maximized; SwiftUI content must never resize it
        window.contentView = host
        window.setFrame(screen.visibleFrame, display: false)
        window.delegate = self

        layoutRail()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        rail.orderFrontRegardless()
    }

    /// The rail shows only while Vet or Claude is the frontmost app.
    func setRailVisible(_ visible: Bool) {
        if visible { rail.orderFrontRegardless() } else { rail.orderOut(nil) }
    }

    /// Puts the rail on the left edge of `anchor` (Cocoa coordinates), or of Vet's window by default.
    /// When Claude is in full screen, the anchor is Claude's full-screen window.
    func layoutRail(anchor: CGRect? = nil) {
        rail.setFrame(DockGeometry.railFrame(mainWindowFrame: anchor ?? window.frame), display: true)
    }

    func windowDidResize(_ notification: Notification) {
        layoutRail()
        onFrameChange?()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        layoutRail()
        onFullScreenChange?(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        layoutRail()
        onFullScreenChange?(false)
    }

    func windowDidMove(_ notification: Notification) {
        layoutRail()
        onFrameChange?()
    }
}
