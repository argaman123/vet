import SwiftUI
import VetCore

/// Review tab: the changes tree on the left, the selected file's diff on the right.
struct ReviewView: View {
    let model: ReviewModel
    let projects: ProjectStore

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 300, maxWidth: 520)
            diffArea
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: projects.current) { model.open(projects.current) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(projects.current?.lastPathComponent ?? "No project").font(.headline).lineLimit(1)
                    Text("\(model.reviewedCount) of \(model.changes.count) reviewed")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                iconButton("arrow.down.circle", "Next unreviewed file") { model.nextUnreviewed() }
                iconButton("arrow.clockwise", "Refresh") { Task { await model.refresh() } }
                iconButton("arrow.down.right.and.arrow.up.left", "Collapse all folders") { model.collapseAll() }
                iconButton("arrow.up.left.and.arrow.down.right", "Expand all folders") { model.expandAll() }
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 8)
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 12).lineLimit(3)
            }
            if projects.current == nil {
                emptyState("Open a project", "File › Open Folder…", action: projects.showOpenPanel)
            } else if !model.isGitRepo {
                emptyState("Not a Git repository", "Review needs git. Files and Browser still work.", action: nil)
            } else if model.changes.isEmpty {
                emptyState("No changes", "Everything matches the last commit.", action: nil)
            } else {
                FileTreeView(model: model, version: model.version, selectedPath: model.selectedPath)
            }
        }
    }

    private var diffArea: some View {
        Group {
            if let path = model.selectedPath {
                VStack(spacing: 6) {
                    Text(path).font(.headline)
                    Text("The diff will show here.").foregroundStyle(.secondary)
                }
            } else {
                Text("Select a file to review").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0x0d / 255, green: 0x11 / 255, blue: 0x17 / 255))
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(help)
    }

    private func emptyState(_ title: String, _ subtitle: String, action: (() -> Void)?) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.title3)
            Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action { Button("Open Folder…", action: action).buttonStyle(.glass) }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
