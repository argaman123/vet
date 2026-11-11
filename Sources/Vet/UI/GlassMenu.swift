import AppKit
import SwiftUI

/// One row of a glass menu.
enum GlassMenuItem {
    case label(String)
    case divider
    case item(title: String, checked: Bool = false, disabled: Bool = false, action: () -> Void)
    /// Opens in place, under its row.
    case submenu(title: String, items: [GlassMenuItem])
}

/// A menu that's open: where its button is in the window, and its rows.
struct OpenGlassMenu {
    var anchor: CGRect
    /// Lines up with the button's trailing edge (menus at the window's right side).
    var trailing: Bool
    var items: [GlassMenuItem]
}

/// A button whose menu is a panel of the window's dark glass (the native shell); the system's
/// menu in the classic window.
struct GlassMenuButton<Label: View>: View {
    let app: AppDelegate
    var trailing = false
    var help = ""
    let items: () -> [GlassMenuItem]
    @ViewBuilder let label: Label
    @State private var frame: CGRect = .zero
    @State private var hovering = false

    var body: some View {
        if Design.shell == .native {
            Button { app.ui.menu = OpenGlassMenu(anchor: frame, trailing: trailing, items: items()) } label: { label }
                .buttonStyle(.plain)
                .background(HoverFill(on: (hovering && !PointerState.shared.blocked) || app.ui.menu?.anchor == frame, gated: false).padding(.horizontal, -4))
                .onHover { hovering = $0 }
                .pointerStyle(.link)
                .fixedSize()
                .help(help)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        } else {
            Menu { SystemMenuItems(items: items()) } label: { label }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().pointerStyle(.link)
                .help(help)
        }
    }
}

/// The same rows as a system menu.
private struct SystemMenuItems: View {
    let items: [GlassMenuItem]
    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            switch item {
            case .label(let title): Button(title) {}.disabled(true)
            case .divider: Divider()
            case .item(let title, let checked, let disabled, let action):
                Button(action: action) { if checked { Label(title, systemImage: "checkmark") } else { Text(title) } }.disabled(disabled)
            case .submenu(let title, let items): Menu(title) { SystemMenuItems(items: items) }
            }
        }
    }
}

/// The open menu, over the whole window: a click anywhere else, Esc, or leaving the window closes it.
struct GlassMenuOverlay: View {
    let app: AppDelegate
    @State private var keys: Any?
    /// The panel's frame in the window, for telling a click on it from one elsewhere.
    @State private var panel: CGRect = .zero

    var body: some View {
        if let menu = app.ui.menu {
            GeometryReader { geo in
                // The button's frame is in window coordinates; the overlay starts at the window's top edge or under it.
                let origin = geo.frame(in: .global).origin
                let anchor = menu.anchor.offsetBy(dx: -origin.x, dy: -origin.y)
                let top = anchor.maxY + 5
                ZStack(alignment: menu.trailing ? .topTrailing : .topLeading) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { close() }
                        .onContinuousHover { if case .active = $0 { NSCursor.arrow.set() } }
                    GlassMenuPanel(items: menu.items, maxHeight: max(120, geo.size.height - top - 14), close: close)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { panel = $0 }
                        .offset(x: menu.trailing ? -max(8, geo.size.width - anchor.maxX) : max(8, min(anchor.minX - 6, geo.size.width - 330)),
                                y: top)
                }
            }
            .ignoresSafeArea()
            .onAppear {
                keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
                    if event.type == .keyDown {
                        if event.keyCode == 53 { close(); return nil } // Esc
                        return event
                    }
                    // A click anywhere but on the menu closes it and goes no further (the title bar
                    // and toolbar included, which no view over the content can cover).
                    guard let window = event.window, let content = window.contentView else { close(); return event }
                    let p = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
                    if panel.contains(p) { return event }
                    close()
                    return nil
                }
            }
            .onDisappear { if let keys { NSEvent.removeMonitor(keys) }; keys = nil }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in close() }
            .onChange(of: app.ui.focusSearch) { _, _ in close() }
        }
    }

    private func close() { app.ui.menu = nil; panel = .zero }
}

private struct GlassMenuPanel: View {
    let items: [GlassMenuItem]
    let maxHeight: CGFloat
    let close: () -> Void
    /// Submenus opened in place (by their row's index).
    @State private var opened: Set<Int> = []

    private static func height(_ items: [GlassMenuItem]) -> CGFloat {
        items.reduce(0) { sum, item in
            switch item {
            case .label: sum + 25
            case .divider: sum + 10
            case .item, .submenu: sum + 29
            }
        }
    }

    var body: some View {
        let checks = items.contains { if case .item(_, true, _, _) = $0 { true } else { false } }
        let height = Self.height(items) + items.enumerated().reduce(0) { sum, e in
            if opened.contains(e.offset), case .submenu(_, let sub) = e.element { sum + Self.height(sub) } else { sum }
        } + 11
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    row(item, checks: checks, index: i)
                    if opened.contains(i), case .submenu(_, let sub) = item {
                        ForEach(Array(sub.enumerated()), id: \.offset) { _, s in row(s, checks: true, index: nil) }
                    }
                }
            }
            .padding(6)
        }
        .scrollIndicators(height > maxHeight ? .automatic : .hidden)
        .frame(height: min(height, maxHeight))
        .frame(minWidth: 220, maxWidth: 340)
        .fixedSize(horizontal: true, vertical: false)
        .glassPanel()
        .clipShape(RoundedRectangle(cornerRadius: Glass.panelRadius, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 22, y: 10)
    }

    @ViewBuilder private func row(_ item: GlassMenuItem, checks: Bool, index: Int?) -> some View {
        switch item {
        case .label(let title):
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                .padding(.horizontal, 9).frame(height: 24, alignment: .bottomLeading)
        case .divider:
            Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 4)
        case .item(let title, let checked, let disabled, let action):
            GlassMenuRow(title: title, mark: checks ? (checked ? "checkmark" : "") : nil, disabled: disabled) { close(); action() }
        case .submenu(let title, _):
            let open = index.map(opened.contains) ?? false
            GlassMenuRow(title: title, mark: checks ? "" : nil, chevron: open ? "chevron.down" : "chevron.right") {
                if let index { if open { opened.remove(index) } else { opened.insert(index) } }
            }
        }
    }
}

private struct GlassMenuRow: View {
    let title: String
    /// The leading mark's symbol ("" keeps its room empty; nil: this menu has no marks).
    let mark: String?
    var chevron: String? = nil
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button { if !disabled { action() } } label: {
            HStack(spacing: 7) {
                if let mark {
                    Image(systemName: mark.isEmpty ? "checkmark" : mark).font(.system(size: 10, weight: .bold))
                        .opacity(mark.isEmpty ? 0 : 1).frame(width: 12)
                }
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                if let chevron { Image(systemName: chevron).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary) }
            }
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hovering && !disabled ? 0.11 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hovering = $0 }
        .pointerStyle(disabled ? nil : .link)
    }
}
