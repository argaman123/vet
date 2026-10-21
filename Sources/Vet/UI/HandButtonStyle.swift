import SwiftUI

/// Every clickable control on glass and in Vet's bars: the borderless look with the pointing
/// hand, so a button always shows it can be clicked (the code underneath never lends its I-beam).
struct HandButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.borderless)
            .pointerStyle(.link)
    }
}

extension PrimitiveButtonStyle where Self == HandButtonStyle {
    static var hand: HandButtonStyle { HandButtonStyle() }
}
