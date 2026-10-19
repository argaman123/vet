import SwiftUI
import VetCore

/// The window: a Liquid Glass sidebar with tools, the main area, and the toolbar.
struct RootView: View {
    let app: AppDelegate

    var body: some View {
        let ws = app.workspace, ui = app.ui
        NavigationSplitView {
            SidebarView(app: app)
                .background(DiffTheme.palette.glassSidebar ? Color.clear : Color(nsColor: DiffTheme.sidebar))
                .navigationSplitViewColumnWidth(min: 230, ideal: 290, max: 460)
        } detail: {
            MainArea(app: app)
                .background(Color(nsColor: DiffTheme.background))
                .navigationTitle(app.projects.current?.lastPathComponent ?? "Vet")
                .navigationSubtitle(subtitle)
                .toolbarTitleMenu { ProjectMenu(app: app) }
                .toolbar { MainToolbar(app: app) }
                .searchable(text: Bindable(ui).search, isPresented: Bindable(ui).focusSearch, placement: .toolbar, prompt: "Search Everywhere")
                .searchSuggestions { SearchEverywhereSuggestions(app: app) }
        }
        .onChange(of: ui.search) { _, query in app.searchEverywhere.update(query) }
        .tint(Color(nsColor: DiffTheme.accent)) // the theme's accent on every control
        .id(ui.themeID) // a new theme redraws everything with its colors
        .background(WindowTint())
        .task(id: app.projects.current) {
            app.ui.reset()
            app.find.reset()
            ws.open(app.projects.current)
        }
        .onChange(of: ws.review.selectedPath) { _, path in
            // Keep the main area on the selected change (selection can change from the menu or Claude).
            if let path, ui.location != .diff(path: path), case .diff = ui.location ?? .diff(path: "") { ui.replace(.diff(path: path)) }
        }
        // ⌘K away from the diff: the commit form as a sheet.
        .sheet(isPresented: Binding(get: { ui.showCommit && ui.location.map { if case .diff = $0 { false } else { true } } ?? true },
                                    set: { ui.showCommit = $0 })) { CommitPopover(app: app) }
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
        let review = app.workspace.review
        let local = review.branches.filter { !$0.isRemote }, remote = review.branches.filter(\.isRemote)
        if !local.isEmpty {
            Section("Branches") {
                ForEach(local, id: \.name) { b in branchButton(b) }
                if !remote.isEmpty {
                    Menu("Remote Branches") { ForEach(remote, id: \.name) { b in branchButton(b) } }
                }
            }
        }
    }

    private func branchButton(_ b: GitBranch) -> some View {
        Button { app.workspace.review.checkout(b.name) } label: {
            if b.isCurrent { Label(b.name, systemImage: "checkmark") } else { Text(b.name) }
        }
        .disabled(app.workspace.review.gitBusy)
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
        ToolbarItem(placement: .navigation) {
            // Where you work: the changes, all files, or the browser.
            Picker("Show", selection: Binding(get: { app.place }, set: { app.go(to: $0) })) {
                Image(systemName: "checklist").accessibilityLabel("Changes").help("Changes (⌘1)").tag(AppDelegate.Place.changes)
                Image(systemName: "folder").accessibilityLabel("All Files").help("All Files (⌘2)").tag(AppDelegate.Place.files)
                Image(systemName: "safari").accessibilityLabel("Browser").help("Browser (⌘3)").tag(AppDelegate.Place.browser)
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem(placement: .primaryAction) {
            // One button: Run, or Stop while running; its arrow picks the configuration.
            Menu {
                ForEach(run.configs) { c in
                    Button { run.selectedID = c.id } label: {
                        if c.id == run.selected?.id { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                    }
                }
                if !run.configs.isEmpty { Divider() }
                Button("Edit Configurations…") { ui.editingRunConfigs = true }
            } label: {
                Label(run.isRunning ? "Stop" : "Run", systemImage: run.isRunning ? "stop.fill" : "play.fill")
                    .foregroundStyle(run.isRunning ? Color.red : Color.primary)
            } primaryAction: {
                if run.isRunning { run.stop() }
                else if run.configs.isEmpty { ui.editingRunConfigs = true }
                else { run.start(); run.outputVisible = true }
            }
            .help(run.isRunning ? "Stop (⌘.)" : run.selected.map { "Run ‘\($0.name)’ (⌘R) · arrow: configurations" } ?? "Run (⌘R)")
        }
    }
}

/// Gives the window the theme's background (seen under the toolbar and around the panes).
private struct WindowTint: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { v.window?.backgroundColor = DiffTheme.window }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { v.window?.backgroundColor = DiffTheme.window }
}

