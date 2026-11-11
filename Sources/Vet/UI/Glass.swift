import SwiftUI

/// The dark glass of Vet's floating pieces (bars over lists, notes, messages, menus): the
/// window's own tone over the system's glass, in rounded squares.
enum Glass {
    /// The window's dark tone, laid over glass so light content behind never washes it out.
    static let tint = Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.68)
    /// Bars and small messages.
    static let barRadius: CGFloat = 8
    /// Panels: menus, notes.
    static let panelRadius: CGFloat = 12
    /// The window's corners (measured: 16 pt). Everything nested in it takes its radius from this,
    /// less its distance from the window's edge, so the corners stay concentric (never rounder
    /// inside than out), down to a floor for the smallest pieces.
    static let windowRadius: CGFloat = 16
    /// How light a sheet of glass is over the work surface (float).
    static let wash: Double = 0.07
    /// The sidebar's panel: a large sheet at the groups' strength reads as a flat grey slab, so it
    /// is only a touch lighter than the surface; its rim and shadow make it a sheet.
    static let panelWash: Double = 0.025
    static func nested(inset: CGFloat, floor: CGFloat = 6) -> CGFloat { max(floor, windowRadius - inset) }
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

// MARK: Glass lying on the work surface

extension View {
    /// This view's bounds as a sheet of glass lying on the work surface (float: the sidebar, the
    /// top row's groups). The surface runs on under it unchanged, exactly as beside it: the sheet
    /// is lighter only by its own light (a white wash, brighter toward the top, and a lit rim),
    /// with a shadow on the surface around it. Never by showing more of what's behind the window,
    /// which reads as a hole cut through the surface.
    /// `lift`: how far it floats over the surface (its shadow's spread).
    func windowGlass(radius: CGFloat, lift: CGFloat = 4, panel: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let wash = panel ? DesignState.shared.panelWash ?? Glass.panelWash : DesignState.shared.wash ?? Glass.wash
        return background {
            ZStack {
                shape.fill(Color.black.opacity(0.55)).blur(radius: lift * 1.6).offset(y: lift * 0.4)
                    .mask { Rectangle().padding(-lift * 6).overlay(shape.blendMode(.destinationOut)).compositingGroup() }
                if DesignState.shared.glassKind == "clear" {
                    Color.clear.glassEffect(.clear, in: shape)
                } else {
                    shape.fill(LinearGradient(colors: [Color.white.opacity(wash * 1.3), Color.white.opacity(wash)], startPoint: .top, endPoint: .bottom))
                }
                shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
        }
    }

    /// A well set into the sidebar's glass (float: the place tabs, the Filter bar): darker than
    /// the sheet around it.
    func glassWell(radius: CGFloat = NativeShell.capsuleRadius) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.black.opacity(0.28)))
    }

    /// The bar under a list in the sidebar (Filter). Float: a well like the place tabs', below the
    /// list. Elsewhere: glass floating over the list's last rows.
    @ViewBuilder func sidebarBar() -> some View {
        if Design.look == .float {
            glassWell()
        } else {
            glassEffect(.regular.tint(Glass.tint), in: .rect(cornerRadius: Glass.barRadius))
        }
    }

    /// Puts `bar` at the bottom of a sidebar list. Float: under the list, which ends above it
    /// (rows would show through a bar on the panel's glass). Elsewhere: floating over the list.
    @ViewBuilder func sidebarFooter<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if Design.look == .float {
            VStack(spacing: 0) { self; bar() }
        } else {
            overlay(alignment: .bottom) { bar() }
        }
    }

    /// The Filter bar's place in the sidebar: the panel's own padding around it.
    @ViewBuilder func sidebarBarPadding() -> some View {
        if Design.look == .float {
            padding(.horizontal, NativeShell.gap).padding(.top, 6).padding(.bottom, NativeShell.gap)
        } else {
            padding(10)
        }
    }
}
