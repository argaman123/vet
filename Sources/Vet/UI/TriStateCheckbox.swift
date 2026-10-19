import AppKit
import SwiftUI
import VetCore

/// A file's or folder's review toggle, the same round one as a diff section's: a ring (not
/// reviewed), a ring with a dash (partly), a green check (reviewed). Clicking a reviewed one clears
/// it; clicking an empty or partial one checks it.
struct TriStateCheckbox: NSViewRepresentable {
    let state: StageState
    /// How much is reviewed (the ring fills by it); nil for state alone.
    var fraction: Double? = nil
    let action: (Bool) -> Void

    func makeNSView(context: Context) -> StageToggle {
        let t = StageToggle(id: 0, inList: true) { [coordinator = context.coordinator] _ in coordinator.clicked() }
        t.setContentHuggingPriority(.required, for: .horizontal)
        return t
    }

    func updateNSView(_ t: StageToggle, context: Context) {
        context.coordinator.parent = self
        context.coordinator.toggle = t
        t.state = state
        t.fraction = fraction
        t.toolTip = state == .staged ? "Reviewed" : fraction.map { $0 > 0 ? "\(Int($0 * 100))% reviewed · click to mark all reviewed" : "Mark reviewed" } ?? "Mark reviewed"
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StageToggle, context: Context) -> CGSize? { CGSize(width: 16, height: 16) }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject {
        var parent: TriStateCheckbox
        weak var toggle: StageToggle?
        init(parent: TriStateCheckbox) { self.parent = parent }
        func clicked() {
            let turnOn = parent.state != .staged
            toggle?.state = turnOn ? .staged : .unstaged // answer the click at once; git catches up
            parent.action(turnOn)
        }
    }
}

extension View {
    /// Lines a control up with the row's text baseline, so a list's disclosure arrow (which
    /// follows the label's first baseline) sits level with the row.
    func alignedToTextBaseline() -> some View {
        alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            .alignmentGuide(.lastTextBaseline) { d in d[VerticalAlignment.center] + 4 }
    }
}

