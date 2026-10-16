import SwiftUI
import VetCore

/// The whole window: the glass rail on the left, the selected tab on the right.
struct ContentView: View {
    @Bindable var state: ShellState
    let projects: ProjectStore
    let workspace: Workspace
    @State private var editingRun = false

    var body: some View {
        HStack(spacing: 0) {
            RailView(state: state, run: workspace.run, editingRun: $editingRun) {
                state.selected = $0
                state.badges[$0] = nil // opening a tab clears its badge
            }
                .frame(width: RailView.width)
                .padding(.top, 34) // room for the window's close/minimize/zoom buttons
            VStack(spacing: 0) {
            Group {
                switch state.selected {
                case .review: ReviewView(model: workspace.review, projects: projects, link: workspace.link)
                case .files: FilesView(model: workspace.files)
                case .browser: BrowserView(model: workspace.browser)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if workspace.run.outputVisible { OutputPanel(run: workspace.run) }
            }
        }
        .background(.background)
        .sheet(isPresented: $editingRun) { RunConfigEditor(run: workspace.run, isPresented: $editingRun) }
        .overlay(alignment: .bottom) {
            if let toast = workspace.link.toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, workspace.run.outputVisible ? 258 : 18)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .task(id: projects.current) { workspace.open(projects.current) }
    }

    private func placeholder(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.title2)
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}
