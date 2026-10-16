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
        window.collectionBehavior = [.fullScreenNone]
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.setFrame(screen.visibleFrame, display: false)
        window.delegate = self

        window.addChildWindow(rail, ordered: .above)
        layoutRail()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        rail.orderFront(nil)
    }

    private func layoutRail() {
        rail.setFrame(DockGeometry.railFrame(mainWindowFrame: window.frame), display: true)
    }

    func windowDidResize(_ notification: Notification) {
        layoutRail()
        onFrameChange?()
    }

    func windowDidMove(_ notification: Notification) {
        onFrameChange?()
    }
}
