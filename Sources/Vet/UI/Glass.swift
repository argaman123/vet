import SwiftUI

/// The dark glass of Vet's floating pieces (bars over lists, notes, messages, menus): the
/// window's own tone over the system's glass, in rounded squares.
enum Glass {
    /// The window's dark tone, laid over glass so light content behind never washes it out.
    static let tint = Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.68)
    /// Bars and small messages.
    static let barRadius: CGFloat = 10
    /// Panels: menus, notes.
    static let panelRadius: CGFloat = 13
    /// A dark filled tile with a hairline edge (the tiles look's control groups).
    static func tile(_ radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.black.opacity(0.34))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
    }
}

extension View {
    /// Where the work fills the window (float): the code itself fades to nothing before the
    /// window's edge, so long lines aren't cut by it. Only the text thins out: nothing is laid
    /// over it, so the surface and whatever floats on it stay as they are.
    @ViewBuilder func fadesAtWindowEdge() -> some View {
        if Design.look == .float {
            mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .leading, endPoint: .trailing).frame(width: 56)
                }
            }
        } else {
            self
        }
    }

    /// A control group's surface in the top row and the sidebar: its own glass, or (the quiet and
    /// bar looks) nothing, the controls sitting on what's behind them.
    @ViewBuilder func groupGlass(interactive: Bool = false) -> some View {
        if Design.look == .float {
            windowGlass(radius: NativeShell.capsuleRadius)
        } else if Design.groupGlass {
            glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: NativeShell.capsuleRadius))
        } else if Design.look == .tiles {
            background(Glass.tile(NativeShell.capsuleRadius))
        } else {
            self
        }
    }

    /// A floating panel of dark glass (menus, messages).
    func glassPanel(radius: CGFloat = Glass.panelRadius) -> some View {
        glassEffect(.regular.tint(Glass.tint), in: .rect(cornerRadius: radius))
    }
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
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.white.opacity(configuration.isPressed ? 0.18 : 0.11))))
            .opacity(enabled ? (configuration.isPressed && prominent ? 0.8 : 1) : 0.4)
            .contentShape(Rectangle())
            .pointerStyle(.link)
    }
}

// MARK: The window's own glass, in shapes

/// A shape left clear of the dark work surface, so the window's glass (the desktop behind it,
/// blurred) shows there: the floating sidebar, the top row's groups. A glass effect laid on the
/// dark surface can only show that surface, which reads as grey; this is the real thing.
struct GlassHole {
    let anchor: Anchor<CGRect>
    let radius: CGFloat
}

struct GlassHolesKey: PreferenceKey {
    static var defaultValue: [GlassHole] { [] }
    static func reduce(value: inout [GlassHole], nextValue: () -> [GlassHole]) { value += nextValue() }
}

/// The dark surface: everything but the holes.
struct SurfaceWithHoles: Shape {
    let holes: [CGRect]
    let radii: [CGFloat]
    func path(in rect: CGRect) -> Path {
        var p = Path(rect.insetBy(dx: -800, dy: -800)) // past the window's edges, title bar included
        for (hole, radius) in zip(holes, radii) {
            p.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        }
        return p
    }
}

extension View {
    /// This view's bounds as a piece of the window's glass: clear of the dark surface, with a
    /// faint sheen and a lit rim.
    func windowGlass(radius: CGFloat) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        }
        .anchorPreference(key: GlassHolesKey.self, value: .bounds) { [GlassHole(anchor: $0, radius: radius)] }
    }

    /// A bar floating over a list in the sidebar (Filter): glass that blurs the rows under it,
    /// darker where it sits on the sidebar's own glass, so it reads as set into it like the tabs.
    func sidebarBar() -> some View {
        glassEffect(.regular.tint(Design.look == .float ? Color.black.opacity(0.62) : Glass.tint), in: .rect(cornerRadius: Glass.barRadius))
    }
}
