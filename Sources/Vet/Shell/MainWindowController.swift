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
    /// The frame to go back to when "full screen" (filling the screen) is turned off.
    private var restoredFrame: NSRect?
    private var railFloating = true

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
        // No macOS full screen: it puts Vet and Claude in separate Spaces, so every tab switch
        // slides the whole screen and the rail would sit on top of Claude. The green button
        // instead toggles "fill the screen" for Vet and Claude together (see toggleFill).
        window.collectionBehavior = [.fullScreenNone]
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

    /// The rail is never hidden. While Vet or Claude is in front it floats above both;
    /// otherwise it sits with Vet's window, so other apps can cover it like any window.
    func setRailFloating(_ floating: Bool) {
        railFloating = floating
        guard !window.isMiniaturized else { return }
        if floating {
            rail.level = .floating
            rail.orderFrontRegardless()
        } else {
            rail.level = .normal
            rail.order(.above, relativeTo: window.windowNumber)
        }
    }

    /// Whether Vet (and so Claude) fills the screen.
    var isFilling: Bool {
        let visible = (window.screen ?? NSScreen.screens[0]).visibleFrame
        return abs(window.frame.minX - visible.minX) < 2 && abs(window.frame.minY - visible.minY) < 2
            && abs(window.frame.width - visible.width) < 2 && abs(window.frame.height - visible.height) < 2
    }

    /// Green button: fill the screen, or go back to the previous size.
    func toggleFill() {
        let visible = (window.screen ?? NSScreen.screens[0]).visibleFrame
        if isFilling {
            let fallback = visible.insetBy(dx: visible.width * 0.1, dy: visible.height * 0.08)
            window.setFrame(restoredFrame ?? fallback, display: true, animate: true)
        } else {
            restoredFrame = window.frame
            window.setFrame(visible, display: true, animate: true)
        }
    }

    func fill() {
        if !isFilling { toggleFill() }
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        toggleFill()
        return false
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

    func windowDidMiniaturize(_ notification: Notification) {
        rail.orderOut(nil) // minimizing Vet takes the rail with it
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        setRailFloating(railFloating)
    }

    func windowDidMove(_ notification: Notification) {
        layoutRail()
        onFrameChange?()
    }
}
