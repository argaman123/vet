import SwiftUI
import VetCore

/// The window: a Liquid Glass sidebar with tools, the main area, and the toolbar.
struct RootView: View {
    let app: AppDelegate

    var body: some View {
        let ws = app.workspace, ui = app.ui
        shell
        .onChange(of: ui.search) { _, query in app.searchEverywhere.update(query) }
        .tint(Color(nsColor: DiffTheme.accent)) // the theme's accent on every control
        .focusEffectDisabled()
        // Up under the title bar too, or the window frame's own grey shows there.
        .background {
            // All glass: the window itself is clear Liquid Glass, the desktop showing through.
            if Design.shell == .native { EmptyView() }
            else if Design.surface == .full { LiquidGlass(style: .clear, tint: NSColor.black.withAlphaComponent(0.28)).ignoresSafeArea() }
            else if Design.frosted { BehindWindowBlur().ignoresSafeArea() }
        }
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
        .sheet(isPresented: Bindable(ui).editingRules) { RulesDialog(model: ws.review, isPresented: Bindable(ui).editingRules) }
        .sheet(isPresented: Bindable(ui).editingRunConfigs) { RunConfigEditor(run: ws.run, isPresented: Bindable(ui).editingRunConfigs) }
        .sheet(isPresented: Binding(get: { ws.navResults != nil }, set: { if !$0 { ws.navResults = nil } })) {
            if let results = ws.navResults {
                LocationPicker(title: results.title, locations: results.locations, root: ws.root) { ws.open($0) } cancel: { ws.navResults = nil }
            }
        }
    }

    /// The native shell (one glass window), or the classic split view with its toolbar.
    @ViewBuilder private var shell: some View {
        let ui = app.ui
        if Design.shell == .native {
            NativeShell(app: app)
        } else {
        NavigationSplitView {
            SidebarView(app: app)
                .background(Self.sidebarFill)
                .modifier(FloatingSidebar())
                .navigationSplitViewColumnWidth(min: 230, ideal: 290, max: 460)
        } detail: {
            MainArea(app: app)
                // Frame: the work stops below the top bar, which shows the window's frost like the sidebar.
                .background { TopBarBackdrop() }
                // Studio: the work sits on an inset panel, floating on the window.
                // (Only Studio clips: a clip would also cut the backdrop off at the top bar.)
                .modifier(StudioClip())
                .modifier(InsetPanel())
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
        }
    }

    private var subtitle: String {
        let review = app.workspace.review
        let branch = review.branch ?? ""
        guard review.isGitRepo, app.projects.current != nil else { return "" }
        let n = review.changes.count
        let changed = n == 0 ? "no changes" : "\(review.reviewedCount) of \(n) reviewed"
        let listening = app.workspace.claudeListening ? " · Claude listening" : ""
        return (branch.isEmpty ? changed : "\(branch) · \(changed)") + listening
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
            let staged = app.workspace.review.changes.filter { app.workspace.review.stage(of: $0) == .staged }.count
            Button(staged > 0 ? "Ask Claude to Commit \(staged) Reviewed" : "Ask Claude to Commit") { app.workspace.review.askClaudeToCommit() } // ⌘K in the menu bar
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

    /// The same menu as rows of a glass menu (the native window's title).
    @MainActor static func items(_ app: AppDelegate) -> [GlassMenuItem] {
        let review = app.workspace.review
        var items: [GlassMenuItem] = []
        if review.isGitRepo {
            let staged = review.changes.filter { review.stage(of: $0) == .staged }.count
            items += [.item(title: staged > 0 ? "Ask Claude to Commit \(staged) Reviewed" : "Ask Claude to Commit") { review.askClaudeToCommit() }, .divider]
        }
        items.append(.label("Projects"))
        items += app.projects.recent.map { url in
            .item(title: url.lastPathComponent, checked: url.standardizedFileURL == app.projects.current?.standardizedFileURL) { app.projects.open(url) }
        }
        items.append(.item(title: "Open Folder…") { app.projects.showOpenPanel() })
        func branch(_ b: GitBranch) -> GlassMenuItem {
            .item(title: b.name, checked: b.isCurrent, disabled: review.gitBusy) { review.checkout(b.name) }
        }
        let local = review.branches.filter { !$0.isRemote }, remote = review.branches.filter(\.isRemote)
        if !local.isEmpty {
            items.append(.label("Branches"))
            items += local.map(branch)
            if !remote.isEmpty { items.append(.submenu(title: "Remote Branches", items: remote.map(branch))) }
        }
        return items
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
        if Design.shell == .native {
            // One glass panel to the top edge: no title and a see-through title bar.
            w.isOpaque = false
            w.backgroundColor = .clear
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.styleMask.insert(.fullSizeContentView)
            w.toolbarStyle = .unified // the title row is the toolbar (NativeShell): 52 pt, buttons centered
        }
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
                // Frame and Full: the code is its own inset panel, so the window's frost shows here.
                if Design.surface == .standard || Design.surface == .float { Color(nsColor: DiffTheme.background) }
            }
            .ignoresSafeArea()
        }
    }
}

/// Frame and Full: the work is an inset rounded panel on the frosted window, under the top bar.
private struct InsetPanel: ViewModifier {
    func body(content: Content) -> some View {
        if Design.surface == .full {
            // All glass, as in the reference: the code sits in its own lighter frosted card, the
            // desktop showing through it, on the frosted window.
            content
                .background { LiquidGlass(style: .regular, cornerRadius: 14, tint: NSColor.black.withAlphaComponent(0.42)) }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12)) }
                .padding(EdgeInsets(top: 0, leading: 0, bottom: 10, trailing: 10))
        } else if Design.surface == .frame {
            content
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08)) }
                .shadow(color: .black.opacity(Design.surface == .frame ? 0.3 : 0.15), radius: 14, y: 4)
                .padding(EdgeInsets(top: 0, leading: 0, bottom: 10, trailing: 10))
        } else {
            content
        }
    }
}

/// Float: the sidebar is a Liquid Glass panel floating on the window.
private struct FloatingSidebar: ViewModifier {
    func body(content: Content) -> some View {
        if Design.surface == .float {
            content
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .background { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.clear).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
                .padding(8)
        } else {
            content
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
/// macOS 26's Liquid Glass as a view (what a glass window and a glass card are made of).
struct LiquidGlass: NSViewRepresentable {
    var style: NSGlassEffectView.Style = .regular
    var cornerRadius: CGFloat = 0
    var tint: NSColor?
    func makeNSView(context: Context) -> NSGlassEffectView {
        let v = NSGlassEffectView()
        update(v)
        return v
    }
    func updateNSView(_ v: NSGlassEffectView, context: Context) { update(v) }
    private func update(_ v: NSGlassEffectView) {
        v.style = style
        v.cornerRadius = cornerRadius
        v.tintColor = tint
    }
}

struct BehindWindowBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
