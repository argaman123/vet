import SwiftUI
import VetCore

/// Review tab: the changes tree on the left, the selected file's diff on the right.
struct ReviewView: View {
    let model: ReviewModel
    let projects: ProjectStore
    let link: ClaudeLink
    @State private var installMessage: String?
    @State private var installing = false

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 300, maxWidth: 520)
            diffArea
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
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
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 12).lineLimit(4)
                    .onTapGesture { model.dismissError() }
                    .help("Click to dismiss")
            }
            claudeLinkRow
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

    /// Whether drafts reach Claude, and a one-click install of the Claude Desktop mod if not.
    private var claudeLinkRow: some View {
        HStack(spacing: 6) {
            Circle().fill(link.connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            Text(link.connected ? "Claude linked" : "Claude not linked").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !link.connected {
                Button(installing ? "Connecting…" : "Connect Claude") {
                    installing = true
                    Task {
                        installMessage = await link.installMod()
                        installing = false
                    }
                }
                .buttonStyle(.borderless).font(.caption).disabled(installing)
                .help("Installs the small vet-bridge mod into Claude Code so Vet can put drafts into your chat")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .alert("Claude link", isPresented: Binding(get: { installMessage != nil }, set: { if !$0 { installMessage = nil } })) {
            Button("OK") { installMessage = nil }
        } message: { Text(installMessage ?? "") }
    }

    private var diffArea: some View {
        VStack(spacing: 0) {
            if let doc = model.diff {
                HStack(spacing: 8) {
                    if let orig = doc.change.origPath {
                        Text("Renamed: \(orig) → \(doc.change.path)").lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(doc.change.path).lineLimit(1).truncationMode(.middle)
                    }
                    if model.diffDirty {
                        Circle().fill(.white.opacity(0.7)).frame(width: 7, height: 7).help("Unsaved changes")
                        Button("Save") { NSApp.sendAction(#selector(CodeTextView.vetSave(_:)), to: nil, from: nil) }.buttonStyle(.borderless)
                        Button("Discard") { model.revertDiffEdits() }.buttonStyle(.borderless)
                    }
                    Spacer()
                    iconButton("chevron.up", "Previous change") { model.jumpToChange(forward: false) }
                    iconButton("chevron.down", "Next change") { model.jumpToChange(forward: true) }
                    iconButton(model.folding ? "arrow.up.and.down.text.horizontal" : "rectangle.compress.vertical",
                               model.folding ? "Show unchanged lines" : "Fold unchanged lines") { model.folding.toggle() }
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .foregroundStyle(Color(nsColor: DiffTheme.text))
                .background(Color(nsColor: DiffTheme.foldBand))
            }
            RibbonDiffView(model: model, version: model.diffVersion, jumpSerial: model.jump.serial)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: DiffTheme.background))
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
