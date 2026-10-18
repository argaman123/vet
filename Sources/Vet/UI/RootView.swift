import SwiftUI
import VetCore

/// The window: a Liquid Glass sidebar with tools, the main area, and the toolbar.
struct RootView: View {
    let app: AppDelegate

    var body: some View {
        let ws = app.workspace, ui = app.ui
        NavigationSplitView {
            SidebarView(app: app)
                .navigationSplitViewColumnWidth(min: 230, ideal: 290, max: 460)
        } detail: {
            MainArea(app: app)
                .navigationTitle(app.projects.current?.lastPathComponent ?? "Vet")
                .navigationSubtitle(subtitle)
                .toolbarTitleMenu { ProjectMenu(app: app) }
                .toolbar { MainToolbar(app: app) }
                .searchable(text: Bindable(ui).search, isPresented: Bindable(ui).focusSearch, placement: .toolbar, prompt: "Search Everywhere")
                .searchSuggestions { SearchEverywhereSuggestions(app: app) }
        }
        .task(id: app.projects.current) {
            app.ui.reset()
            ws.open(app.projects.current)
        }
        .onChange(of: ws.review.selectedPath) { _, path in
            // Keep the main area on the selected change (selection can change from the menu or Claude).
            if let path, ui.location != .diff(path: path), case .diff = ui.location ?? .diff(path: "") { ui.replace(.diff(path: path)) }
        }
        .sheet(isPresented: Bindable(ui).editingRules) { RulesDialog(model: ws.review, isPresented: Bindable(ui).editingRules) }
        .sheet(isPresented: Bindable(ui).editingRunConfigs) { RunConfigEditor(run: ws.run, isPresented: Bindable(ui).editingRunConfigs) }
        .sheet(isPresented: Binding(get: { ws.navResults != nil }, set: { if !$0 { ws.navResults = nil } })) {
            if let results = ws.navResults {
                LocationPicker(title: results.title, locations: results.locations, root: ws.root) { ws.open($0) } cancel: { ws.navResults = nil }
            }
        }
    }

    private var subtitle: String {
        let review = app.workspace.review
        let branch = review.branch ?? ""
        guard review.isGitRepo, app.projects.current != nil else { return "" }
        let n = review.changes.count
        let changed = n == 0 ? "no changes" : "\(review.reviewedCount) of \(n) reviewed"
        return branch.isEmpty ? changed : "\(branch) · \(changed)"
    }
}

/// The title menu: switch project or branch.
struct ProjectMenu: View {
    let app: AppDelegate
    var body: some View {
        Section("Projects") {
            ForEach(app.projects.recent, id: \.self) { url in
                Button { app.projects.open(url) } label: {
                    if url.standardizedFileURL == app.projects.current?.standardizedFileURL {
                        Label(url.lastPathComponent, systemImage: "checkmark")
                    } else {
                        Text(url.lastPathComponent)
                    }
                }
            }
            Button("Open Folder…") { app.projects.showOpenPanel() }
        }
        if !app.workspace.review.branches.isEmpty {
            Section("Branches") {
                ForEach(app.workspace.review.branches, id: \.self) { name in
                    Button { app.workspace.review.checkout(name) } label: {
                        if name == app.workspace.review.branch { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            }
        }
    }
}

/// The toolbar: history, change navigation and layout, run, commit, search.
struct MainToolbar: ToolbarContent {
    let app: AppDelegate

    var body: some ToolbarContent {
        let ui = app.ui, review = app.workspace.review, run = app.workspace.run
        ToolbarItemGroup(placement: .navigation) {
            Button { app.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!ui.canGoBack).help("Back (⌘[)")
            Button { app.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!ui.canGoForward).help("Forward (⌘])")
        }
        if case .diff? = ui.location {
            ToolbarItemGroup(placement: .principal) {
                Button { review.jumpToChange(forward: false) } label: { Label("Previous Change", systemImage: "chevron.up") }
                    .help("Previous Change (⌥⌘↑)")
                Button { review.jumpToChange(forward: true) } label: { Label("Next Change", systemImage: "chevron.down") }
                    .help("Next Change (⌥⌘↓)")
            }
            ToolbarItem(placement: .principal) {
                Picker("Layout", selection: Bindable(review).unified) {
                    Label("Side by Side", systemImage: "rectangle.split.2x1").tag(false)
                    Label("Unified", systemImage: "rectangle").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Diff Layout")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(run.configs) { c in
                    Button { run.selectedID = c.id } label: {
                        if c.id == run.selected?.id { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                    }
                }
                if !run.configs.isEmpty { Divider() }
                Button("Edit Configurations…") { ui.editingRunConfigs = true }
            } label: {
                Label(run.selected?.name ?? "Add Configuration", systemImage: "play.rectangle").labelStyle(.titleAndIcon)
            }
            .help("Run Configuration")
            Button {
                if run.configs.isEmpty { ui.editingRunConfigs = true } else { run.start(); run.outputVisible = true }
            } label: { Label("Run", systemImage: "play.fill") }
                .disabled(run.isRunning)
                .help(run.selected.map { "Run ‘\($0.name)’ (⌘R)" } ?? "Run (⌘R)")
            Button { run.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .disabled(!run.isRunning).help("Stop (⌘.)")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            let staged = review.changes.filter { review.stage(of: $0) != .unstaged }.count
            Button { ui.showCommit = true } label: { Text(staged > 0 ? "Commit \(staged)" : "Commit") }
                .buttonStyle(.glassProminent)
                .disabled(staged == 0)
                .help("Commit the checked changes (⌘K)")
                .popover(isPresented: Bindable(ui).showCommit, arrowEdge: .bottom) { CommitPopover(app: app) }
        }
    }
}
