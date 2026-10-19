import SwiftUI
import VetCore

/// The window: a Liquid Glass sidebar with tools, the main area, and the toolbar.
struct RootView: View {
    let app: AppDelegate

    var body: some View {
        let ws = app.workspace, ui = app.ui
        NavigationSplitView {
            SidebarView(app: app)
                .background(Self.sidebarFill)
                .navigationSplitViewColumnWidth(min: 230, ideal: 290, max: 460)
        } detail: {
            MainArea(app: app)
                // Frame: the work stops below the top bar, which shows the window's frost like the sidebar.
                .background { TopBarBackdrop() }
                // Studio: the work sits on an inset panel, floating on the window.
                // (Only Studio clips: a clip would also cut the backdrop off at the top bar.)
                .modifier(StudioClip())
                .overlay {
                    if Design.direction == .studio {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.07))
                    }
                }
                .shadow(color: .black.opacity(Design.direction == .studio ? 0.45 : 0), radius: 18, y: 6)
                .padding(Design.direction == .studio ? EdgeInsets(top: 2, leading: 2, bottom: 12, trailing: 12) : EdgeInsets())
                .background(Design.direction == .studio ? Color(nsColor: DiffTheme.window) : .clear)
                .navigationTitle(app.projects.current?.lastPathComponent ?? "Vet")
                .navigationSubtitle(subtitle)
                .toolbarTitleMenu { ProjectMenu(app: app) }
                .toolbar { MainToolbar(app: app) }
                // A frosted top bar, like the sidebar (not a see-through one).
                .modifier(TopBarMaterial())
                .searchable(text: Bindable(ui).search, isPresented: Bindable(ui).focusSearch, placement: .toolbar, prompt: "Search Everywhere")
                .searchSuggestions { SearchEverywhereSuggestions(app: app) }
        }
        .onChange(of: ui.search) { _, query in app.searchEverywhere.update(query) }
        .tint(Color(nsColor: DiffTheme.accent)) // the theme's accent on every control
        .focusEffectDisabled()
        // Up under the title bar too, or the window frame's own grey shows there.
        .background { if Design.frosted { BehindWindowBlur().ignoresSafeArea() } }
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
        .sheet(isPresented: Bindable(ui).showCommit) { CommitPopover(app: app) }
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

extension RootView {
    /// The sidebar's surface: the system's Liquid Glass (Glass), near-black (Monolith), the window
    /// itself (Studio), or the theme's.
    static var sidebarFill: Color {
        switch Design.direction {
        case .glass: .clear
        case .monolith: Color(nsColor: DiffTheme.hex(0x0A0A0A))
        case .studio: Color(nsColor: DiffTheme.window)
        case .current: DiffTheme.palette.glassSidebar ? .clear : Color(nsColor: DiffTheme.sidebar)
        }
    }
}

/// The title menu: switch project or branch.
struct ProjectMenu: View {
    let app: AppDelegate
    var body: some View {
        if app.workspace.review.isGitRepo {
            let staged = app.workspace.review.changes.filter { app.workspace.review.stage(of: $0) != .unstaged }.count
            Button(staged > 0 ? "Commit \(staged) Reviewed…" : "Commit…") { app.ui.showCommit = true } // ⌘K lives in the menu bar
            Divider()
        }
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
        ToolbarItemGroup(placement: .primaryAction) {
            // Run, or Stop while running; the chevron beside it picks the configuration.
            Button {
                if run.isRunning { run.stop() }
                else if run.configs.isEmpty { ui.editingRunConfigs = true }
                else { run.start(); run.outputVisible = true }
            } label: {
                Label(run.isRunning ? "Stop" : "Run", systemImage: run.isRunning ? "stop.fill" : "play.fill")
            }
            .help(run.isRunning ? "Stop (⌘.)" : run.selected.map { "Run ‘\($0.name)’ (⌘R)" } ?? "Run (⌘R)")
            Menu {
                ForEach(run.configs) { c in
                    Button { run.selectedID = c.id } label: {
                        if c.id == run.selected?.id { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                    }
                }
                if !run.configs.isEmpty { Divider() }
                Button("Edit Configurations…") { ui.editingRunConfigs = true }
            } label: {
                Label("Configurations", systemImage: "chevron.down")
            }
            .menuIndicator(.hidden)
            .help("Run Configurations")
        }
    }
}

/// Gives the window the theme's background (seen under the toolbar and around the panes).
private struct WindowTint: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { Self.apply(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { Self.apply(v.window) }
    /// Glass: the window lets the desktop through, so the Liquid Glass sidebar picks up the wallpaper.
    private static func apply(_ w: NSWindow?) {
        guard let w else { return }
        // Glass keeps a solid window (the sidebar's own glass frosts it); Frosted lets the desktop through.
        w.isOpaque = !Design.frosted
        w.backgroundColor = Design.frosted ? .clear : DiffTheme.window
    }
}

/// The work's surface, and what sits behind the top bar over it: the code itself running up
/// under the bar (column), the same glass as the sidebar (frame), or the bar's material.
private struct TopBarBackdrop: View {
    var body: some View {
        GeometryReader { g in
            VStack(spacing: 0) {
                if Design.chrome == .frame {
                    Rectangle().fill(.clear).glassEffect(.regular, in: Rectangle()).frame(height: max(g.safeAreaInsets.top, 52))
                }
                Color(nsColor: DiffTheme.background)
            }
            .ignoresSafeArea()
        }
    }
}

private struct StudioClip: ViewModifier {
    func body(content: Content) -> some View {
        if Design.direction == .studio { content.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) } else { content }
    }
}

/// The top bar's own frosted material (material), or none, so what is under it shows.
private struct TopBarMaterial: ViewModifier {
    func body(content: Content) -> some View {
        if Design.chrome == .material {
            content.toolbarBackgroundVisibility(.visible, for: .windowToolbar).toolbarBackground(.regularMaterial, for: .windowToolbar)
        } else {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
    }
}

/// The desktop, blurred, behind the whole window (Frosted).
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
