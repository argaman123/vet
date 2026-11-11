import AppKit
import SwiftUI

/// The file lists draw their own selection: a quiet grey that keeps each name's color.
/// AppKit's own highlight turns the accent blue whenever the list has focus, and blue names
/// on a blue row don't read.
extension View {
    func quietSelection(_ selected: String?) -> some View {
        environment(\.selectedRow, selected)
            .background(NoSystemHighlight())
    }

    /// The row's background: the grey selection when it is the selected one.
    func quietRow(_ path: String) -> some View { modifier(QuietRow(path: path)) }
}

extension EnvironmentValues {
    @Entry var selectedRow: String? = nil
}

private struct QuietRow: ViewModifier {
    let path: String
    @Environment(\.selectedRow) private var selected
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            // Set on the row itself: the list replaces a font set around it with its own size.
            .font(.system(size: SidebarMetrics.text))
            // The whole row answers the pointer, not only its text.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .listRowBackground(
            Group {
                if selected != path {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hovering || HoverDebug.shared.forced ? 0.07 : 0))
                } else if Design.shell == .native {
                    // The selected file: a piece of glass on the window's glass.
                    Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.09))
                }
            }
            .padding(.horizontal, 10)
        )
    }
}

/// Finds the list's outline view (the one filling the same frame) and turns its highlight off.
private struct NoSystemHighlight: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ v: Probe, context: Context) { v.apply() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        override func layout() { super.layout(); apply() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply() {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let root = self.window?.contentView else { return }
                    let mine = self.convert(self.bounds, to: nil)
                    for o in Self.outlines(in: root) where o.selectionHighlightStyle != .none {
                        guard let scroll = o.enclosingScrollView, scroll.convert(scroll.bounds, to: nil).intersects(mine) else { continue }
                        o.selectionHighlightStyle = .none
                    }
                }
            }
        }

        static func outlines(in v: NSView) -> [NSOutlineView] {
            if let o = v as? NSOutlineView { return [o] }
            return v.subviews.flatMap(outlines)
        }
    }
}

/// The file lists' text and rows, as WebStorm and VS Code size their trees (read from their own
/// theme files): 13-pt text, 16-pt icons, rows 24 pt apart (WebStorm 24, VS Code 22).
enum SidebarMetrics {
    static let text: CGFloat = 13
    /// A row's content height; the list's small rows add their padding around it (24 pt in all).
    static let row: CGFloat = 16
    static let icon: CGFloat = 16
}
