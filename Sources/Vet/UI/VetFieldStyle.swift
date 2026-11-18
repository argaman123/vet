import SwiftUI

/// Vet's text field: a filled box that brightens when you type in it. No focus ring (it clipped
/// against scrolling lists and fought the dark sheets).
struct VetFieldStyle: TextFieldStyle {
    @FocusState private var focused: Bool
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Glass.rowRadius, style: .continuous).fill(focused ? Glass.fillStrong : Glass.fill))
    }
}

extension TextFieldStyle where Self == VetFieldStyle {
    static var vet: VetFieldStyle { VetFieldStyle() }
}
