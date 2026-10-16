import AppKit
import SwiftUI

/// Vet's single window. It remembers its size and position between launches.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow

    init(content: some View) {
        let screen = NSScreen.screens[0]
        window = NSWindow(contentRect: screen.visibleFrame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Vet"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 480)
        let host = NSHostingView(rootView: content)
        host.sizingOptions = [] // SwiftUI content must never resize the window
        window.contentView = host
        window.delegate = self
        if !window.setFrameUsingName("VetMain") { window.setFrame(screen.visibleFrame, display: false) }
        window.setFrameAutosaveName("VetMain")
    }

    func show() { window.makeKeyAndOrderFront(nil) }
}
