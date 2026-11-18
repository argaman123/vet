import SwiftUI

/// Vet's glass: one sheet for every piece (the sidebar, the top row's groups, the tabs, bars,
/// menus, messages), in rounded squares.
enum Glass {
    /// The dark sheet as one flat tone, for where the system draws the shape (a popover).
    /// Popovers are the system's clear glass, like every floating panel: nothing laid over it.
    static let sheet = Color.clear
    /// The window's own tint over its glass.
    static let windowTint = Color(red: 0.045, green: 0.045, blue: 0.06)
    /// The window's corners (measured: 16 pt). Nothing in the window is rounder at its edge.
    static let windowRadius: CGFloat = 16
    /// The menu panel and everything that floats (menus, search, messages): the system popover's corner.
    static let panelRadius: CGFloat = 16
    /// Fields in the menu panel: the tabs, Filter.
    static let fieldRadius: CGFloat = 10
    /// Rows, chips and small buttons.
    static let rowRadius: CGFloat = 7
    /// The one hairline: around the menu panel, its fields and every floating panel.
    static let hairline = Color.white.opacity(0.10)
    /// The fills, lightest first: a button at rest or a row under the pointer; a selected row or
    /// a button under the pointer; a button being pressed.
    static let fill = Color.white.opacity(0.07)
    static let fillStrong = Color.white.opacity(0.10)
    static let fillPressed = Color.white.opacity(0.15)
    /// The dark tone under everything opaque: the window's tint, the backing of floating panels.
    static let tone = Color(red: 0.07, green: 0.07, blue: 0.08)
}

extension View {
    /// A control group's surface in the top row: a sheet of the window's glass.
    func groupGlass() -> some View { windowGlass(radius: NativeShell.capsuleRadius) }

    /// A floating panel (menus, messages, search): the same sheet as the sidebar and the row's
    /// groups, backed so the code under it doesn't show.
    func glassPanel(radius: CGFloat = Glass.panelRadius) -> some View { modifier(FloatingSurface(radius: radius)) }

    /// A floating panel arriving: it grows a little out of where it came from and fades in, fast.
    /// Leaving is instant. With Reduce Motion it only fades.
    func popsIn(anchor: UnitPoint) -> some View { modifier(PopIn(anchor: anchor)) }
}

/// Buttons in a glass panel (a note's Save, Send…): small rounded squares, filled. The main one
/// takes the accent with dark text.
struct PanelButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? AnyShapeStyle(Color.black.opacity(0.85)) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule()
                .fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(configuration.isPressed ? Glass.fillPressed : Glass.fillStrong)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .opacity(enabled ? (configuration.isPressed && prominent ? 0.8 : 1) : 0.4)
            .contentShape(Rectangle())
            .pointerStyle(.link)
    }
}

/// A quiet round icon button in a panel (a note's Delete, Edit, Dismiss): the same fill as the
/// panel's other buttons, the size of their height.
struct PanelIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.primary.opacity(0.85))
            .frame(width: 26, height: 26)
            .background(Circle().fill(configuration.isPressed ? Glass.fillPressed : Glass.fillStrong))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Circle())
            .pointerStyle(.link)
    }
}

/// Everything that floats (search, messages, the file's summary): the system's clear glass, the
/// same as its popovers and menus. No tint, no shadow of our own.
private struct FloatingSurface: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.background { Color.clear.glassEffect(.regular, in: .rect(cornerRadius: radius)) }
    }
}

// MARK: Motion

/// Vet's motion: two curves. Things that appear use `quick`; things that move or resize use `move`
/// (a spring with no bounce, so it can be redirected mid-way).
enum Motion {
    static let quick = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
    static let move = Animation.spring(response: 0.3, dampingFraction: 1)
}

private struct PopIn: ViewModifier {
    let anchor: UnitPoint
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .scaleEffect(shown || reduceMotion ? 1 : 0.96, anchor: anchor)
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(Motion.quick) { shown = true } }
    }
}

// MARK: Glass lying on the work surface

extension View {
    /// A button's surface on the window (the top row's groups, Approve and Next): one flat fill, no edge, no shadow.
    func windowGlass(radius: CGFloat) -> some View {
        background { RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Glass.fill) }
    }

    /// A field in the menu panel (the tabs, Filter): outlined, barely filled.
    func fieldGlass(radius: CGFloat = Glass.fieldRadius) -> some View {
        background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack { shape.fill(Color.white.opacity(0.025)); shape.strokeBorder(Glass.hairline, lineWidth: 1) }
        }
    }

    /// The menu's panel: a sheet a step lighter than the window, in the window's own dark tone
    /// (so a bright wallpaper doesn't light it up), with the hairline.
    func menuPanel() -> some View {
        background {
            let shape = RoundedRectangle(cornerRadius: Glass.panelRadius, style: .continuous)
            ZStack { shape.fill(Color.white.opacity(0.04)); shape.strokeBorder(Glass.hairline, lineWidth: 1) }
        }
    }

    /// A button's surface floating over code: backed by the window's tone over a blur, so the
    /// code under it doesn't show through.
    func windowGlassOverCode(radius: CGFloat) -> some View {
        windowGlass(radius: radius)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Glass.tone.opacity(0.86)))
            .background(Color.clear.glassEffect(.regular, in: .rect(cornerRadius: radius)))
    }

    /// The bar under a list in the sidebar (Filter): a sheet of the same glass, lying on the
    /// sidebar below the list.
    func sidebarBar() -> some View { fieldGlass() }

    /// Puts `bar` under a sidebar list, which ends above it (rows would show through a bar laid
    /// over them on the panel's glass).
    func sidebarFooter<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        VStack(spacing: 0) { self; bar() }
    }

    /// The Filter bar's place in the sidebar: the panel's own padding around it.
    func sidebarBarPadding() -> some View {
        padding(.horizontal, NativeShell.gap).padding(.top, 6).padding(.bottom, NativeShell.gap)
    }
}
