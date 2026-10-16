import AppKit
import SwiftUI
import VetCore

/// The rail lives in its own non-activating floating panel.
/// Clicking it does NOT activate Vet, so clicking the Claude icon never pulls
/// Vet's main window over the docked Claude window. It floats above normal
/// windows so Stage Manager leaves it alone: Vet and Claude each get their own
/// stage, and the rail stays put while Stage Manager switches between them.
@MainActor
final class RailPanel: NSPanel {
    init(state: ShellState, onSelect: @escaping (RailTab) -> Void) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: DockGeometry.railWidth, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        let host = FirstMouseHostingView(rootView: RailView(state: state, onSelect: onSelect))
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on an inactive window hit the SwiftUI buttons.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
