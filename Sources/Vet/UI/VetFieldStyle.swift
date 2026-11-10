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
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(focused ? 0.13 : 0.06)))
    }
}

extension TextFieldStyle where Self == VetFieldStyle {
    static var vet: VetFieldStyle { VetFieldStyle() }
}
