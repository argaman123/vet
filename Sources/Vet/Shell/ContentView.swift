import SwiftUI
import VetCore

/// The whole window: the glass rail on the left, the selected tab on the right.
struct ContentView: View {
    @Bindable var state: ShellState
    var review: AnyView = AnyView(EmptyView())

    var body: some View {
        HStack(spacing: 0) {
            RailView(state: state) { state.selected = $0 }
                .frame(width: RailView.width)
                .padding(.top, 34) // room for the window's close/minimize/zoom buttons
            Group {
                switch state.selected {
                case .review: review
                case .files: placeholder("Files", "The whole project will show here.")
                case .browser: placeholder("Browser", "A bare browser will show here.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
        .ignoresSafeArea()
    }

    private func placeholder(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.title2)
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}
