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
            RailView(state: state, run: workspace.run, editingRun: $editingRun) { state.selected = $0 }
                .frame(width: RailView.width)
                .padding(.top, 34) // room for the window's close/minimize/zoom buttons
            VStack(spacing: 0) {
            Group {
                switch state.selected {
                case .review: ReviewView(model: workspace.review, projects: projects)
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
