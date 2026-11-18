import SwiftUI

/// Every clickable control on glass and in Vet's bars: the borderless look with the pointing
/// hand, and a soft highlight under the pointer (as the system's toolbar buttons have), so a
/// button always shows it can be clicked (the code underneath never lends its I-beam).
struct HandButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HandButton(configuration: configuration) }
}

extension PrimitiveButtonStyle where Self == HandButtonStyle {
    static var hand: HandButtonStyle { HandButtonStyle() }
}

extension EnvironmentValues {
    /// The corner radius of the highlight under the pointer (buttons that fill a rounder shape set it).
    @Entry var hoverRadius: CGFloat = 6
}

private struct HandButton: View {
    let configuration: PrimitiveButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.hoverRadius) private var radius

    var body: some View {
        Button(configuration)
            .buttonStyle(.borderless)
            .pointerStyle(.link)
            .background(HoverFill(on: hovering && enabled, radius: radius))
            // A button that can't be used now reads as off, not only without its highlight.
            .opacity(enabled ? 1 : 0.38)
            .onHover { hovering = $0 }
    }
}

/// Tests: every highlight shown at once, to look at them without a pointer.
@MainActor @Observable final class HoverDebug {
    static let shared = HoverDebug()
    var forced = false
}

/// The highlight under the pointer.
struct HoverFill: View {
    let on: Bool
    var radius: CGFloat = 7
    /// Off while a menu or the search panel is open (the menu's own button keeps its highlight).
    var gated = true
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill((on && !(gated && PointerState.shared.blocked)) || HoverDebug.shared.forced ? Glass.fillStrong : Color.clear)
            .animation(.easeOut(duration: 0.12), value: on)
    }
}
