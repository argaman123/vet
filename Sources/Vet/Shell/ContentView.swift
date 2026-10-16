import SwiftUI
import VetCore

/// The main window's content: an empty strip under the rail, then the selected tab.
struct ContentView: View {
    let state: ShellState
    var onOpenClaude: () -> Void = {}
    var onGrantPermission: () -> Void = {}
    var review: AnyView = AnyView(EmptyView())

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: DockGeometry.railWidth)
            Group {
                switch state.selected {
                case .claude: claudePlaceholder
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

    @ViewBuilder private var claudePlaceholder: some View {
        VStack(spacing: 14) {
            switch state.dockMessage {
            case .needsPermission:
                Text("Vet needs Accessibility access to dock Claude.").font(.title3)
                Button("Grant Accessibility access", action: onGrantPermission).buttonStyle(.glassProminent)
            case .claudeMissing:
                Text("Claude Desktop isn't open.").font(.title3)
                Button("Open Claude", action: onOpenClaude).buttonStyle(.glassProminent)
            case nil:
                Text("Claude is docked here.").foregroundStyle(.secondary)
            }
        }
    }

    private func placeholder(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.title2)
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}
