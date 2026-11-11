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
    /// A control group's surface in the top row and the sidebar: its own glass, or (the quiet and
    /// bar looks) nothing, the controls sitting on what's behind them.
    @ViewBuilder func groupGlass(interactive: Bool = false) -> some View {
        if Design.groupGlass {
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
