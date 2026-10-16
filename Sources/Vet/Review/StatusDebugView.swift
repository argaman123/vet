import SwiftUI
import VetCore

/// Temporary (Plan 2 Task 1): lists git status for the open project.
struct StatusDebugView: View {
    let projects: ProjectStore
    @State private var changes: [FileChange] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(projects.current?.path ?? "No project open — File › Open Folder…").font(.headline)
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(changes) { c in
                Text("\(String(describing: c.kind)) · \(String(describing: c.stage)) · \(c.path)\(c.origPath.map { " ← \($0)" } ?? "")")
                    .font(.system(.body, design: .monospaced))
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: projects.current) {
            guard let root = projects.current else { return }
            do { changes = try await GitRepo(root: root).status() } catch { self.error = "\(error)" }
        }
    }
}
