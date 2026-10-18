import AppKit
import SwiftUI
import VetCore

/// A native checkbox with a mixed state (some changes staged). Clicking a checked box clears
/// it; clicking an empty or mixed one checks it.
struct TriStateCheckbox: NSViewRepresentable {
    let state: StageState
    let action: (Bool) -> Void

    func makeNSView(context: Context) -> NSButton {
        let b = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        b.allowsMixedState = true
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    func updateNSView(_ b: NSButton, context: Context) {
        context.coordinator.parent = self
        b.state = switch state { case .staged: .on; case .unstaged: .off; case .partial: .mixed }
        b.toolTip = state == .staged ? "Reviewed (staged)" : "Mark reviewed (stage)"
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject {
        var parent: TriStateCheckbox
        init(parent: TriStateCheckbox) { self.parent = parent }
        @objc func clicked(_ sender: NSButton) {
            let turnOn = parent.state != .staged
            sender.state = turnOn ? .on : .off // answer the click at once; git catches up
            parent.action(turnOn)
        }
    }
}
