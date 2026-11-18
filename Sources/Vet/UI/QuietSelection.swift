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

    /// A folder's row: the same background, with the pointer watched on its label only (`rowPointer`).
    /// Watched on the whole folder, the pointer over any file inside would light the folder too.
    func quietFolderRow(_ path: String) -> some View { modifier(QuietRow(path: path, watchesPointer: false)) }

    /// The part of a row that answers the pointer (a folder's label), full width.
    func rowPointer(_ path: String) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { PointerState.shared.setRow(path, $0) }
    }
}

/// Where the pointer is, for the highlights under it. One place holds it, so only one row can
/// ever be lit (a row's own flag stays set when the list reuses or moves it under a still pointer).
@MainActor @Observable final class PointerState {
    static let shared = PointerState()
    /// The file row under the pointer.
    private(set) var row: String?
    /// A menu or the search panel is open over the window: nothing under it lights up.
    var blocked = false { didSet { if blocked { row = nil } } }

    func setRow(_ path: String, _ inside: Bool) {
        if inside { row = path } else if row == path { row = nil }
    }
}

extension EnvironmentValues {
    @Entry var selectedRow: String? = nil
}

private struct QuietRow: ViewModifier {
    let path: String
    var watchesPointer = true
    @Environment(\.selectedRow) private var selected
    func body(content: Content) -> some View {
        let pointer = PointerState.shared
        let hovering = pointer.row == path && !pointer.blocked
        Group {
            if watchesPointer { content.rowPointer(path) } else { content }
        }
            // Set on the row itself: the list replaces a font set around it with its own size.
            .font(.system(size: SidebarMetrics.text))
            .listRowBackground(
            Group {
                if selected != path {
                    RoundedRectangle(cornerRadius: Glass.rowRadius, style: .continuous).fill(hovering || HoverDebug.shared.forced ? Glass.fill : Color.clear)
                } else if Design.shell == .native {
                    // On the sidebar's glass: a lighter fill, not more glass on glass.
                    RoundedRectangle(cornerRadius: Glass.rowRadius, style: .continuous).fill(Glass.fillStrong)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.09))
                }
            }
            .padding(.horizontal, NativeShell.gap)
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
