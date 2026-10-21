import AppKit
import SwiftUI

/// Clicking a change bar in the editor's gutter: what those lines were in the last commit, as in
/// JetBrains IDEs, with a way into the full diff.
@MainActor
enum ChangeBarPopover {
    private static var popover: NSPopover?

    static func show(_ bar: LineNumberGutter.ChangeBar, at rect: NSRect, in view: NSView, showChanges: @escaping () -> Void) {
        popover?.close()
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        let host = NSHostingController(rootView: ChangeBarView(bar: bar, showChanges: { [weak p] in
            p?.close()
            showChanges()
        }))
        host.sizingOptions = .preferredContentSize
        p.contentViewController = host
        popover = p
        p.show(relativeTo: rect, of: view, preferredEdge: .maxX)
    }
}

private struct ChangeBarView: View {
    let bar: LineNumberGutter.ChangeBar
    let showChanges: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer(minLength: 24)
                Button("Show Changes", action: showChanges).buttonStyle(.hand).font(.callout)
            }
            if !bar.old.isEmpty {
                ScrollView([.vertical, .horizontal]) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .trailing, spacing: 0) {
                            ForEach(Array(bar.old.indices), id: \.self) { i in
                                Text("\(bar.oldStart + i + 1)").foregroundStyle(.tertiary)
                            }
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(bar.old.enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : line).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    .font(Font(DiffTheme.font))
                    .fixedSize()
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: 640, maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(minWidth: 260)
    }

    private var title: String {
        switch bar.kind {
        case .inserted: bar.lines.count == 1 ? "1 new line" : "\(bar.lines.count) new lines"
        case .modified: "Before"
        case .deleted: bar.old.count == 1 ? "1 line removed" : "\(bar.old.count) lines removed"
        }
    }
}
