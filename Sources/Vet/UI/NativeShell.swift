import AppKit
import SwiftUI
import VetCore

extension EnvironmentValues {
    /// The file's header sits in the window's top row (the native shell), not over the code.
    @Entry var headerInRow = false
}

/// The window as one glass panel: the sidebar right on it (the project in the title row, then
/// history and the place switcher), the top row for the file and its controls, and the work in
/// a dark glass card. Everything around the card is the same glass, top to bottom.
struct NativeShell: View {
    let app: AppDelegate
    @AppStorage("sidebarWidth") private var sidebarWidth = 272.0
    @AppStorage("sidebarHidden") private var sidebarHidden = false
    @State private var dragStart: Double?
    @State private var windowWidth: CGFloat = 1200
    /// Full screen: no window buttons, and no toolbar (there it becomes a bar of its own over the
    /// top row, taking its clicks), so Search moves into the row.
    @State private var fullScreen = false

    var body: some View {
        // The sidebar is a glass panel of its own, over a work surface that fills the window.
        // Tests can hide the sidebar without writing the setting (it's shared with your own Vet).
        let sidebarHidden = DesignState.shared.sidebarHidden ?? self.sidebarHidden
        HStack(spacing: 0) {
            if !sidebarHidden {
                NativeSidebar(app: app, fullScreen: fullScreen) { self.sidebarHidden = true }
                    .frame(width: sidebarWidth - NativeShell.gap)
                    .menuPanel()
                    .padding(NativeShell.gap)
                    .overlay(alignment: .trailing) {
                        // Drag the gap between the sidebar and the card to resize.
                        Color.clear.frame(width: 8).contentShape(Rectangle())
                            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { g in
                                    let start = dragStart ?? sidebarWidth
                                    if dragStart == nil { dragStart = start }
                                    sidebarWidth = min(460, max(210, start + g.translation.width))
                                }
                                .onEnded { _ in dragStart = nil })
                            .offset(x: 4)
                    }
            }
            VStack(spacing: 0) {
                NativeTopRow(app: app, sidebarHidden: sidebarHidden, fullScreen: fullScreen) { self.sidebarHidden = false }
                    .frame(height: NativeShell.rowHeight)
                    .zIndex(1)
                MainArea(app: app)
                    .environment(\.headerInRow, true)
            }
        }
        .animation(Motion.move, value: sidebarHidden)
        .ignoresSafeArea() // up to the window's top edge: the rows sit beside the window buttons
        // The dark work surface over the window's glass, the same under everything that lies on it.
        .background { Color(red: 0.045, green: 0.045, blue: 0.06).opacity(0.5).ignoresSafeArea() }
        .background { NativeWindowGlass().ignoresSafeArea() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .overlay { GlassMenuOverlay(app: app) }
        .onChange(of: app.ui.menu != nil || app.ui.focusSearch) { _, open in PointerState.shared.blocked = open }
        .overlay { if app.ui.focusSearch { SearchOverlay(app: app) } }
        // The toolbar holds Search, at the right end of the row: it makes the title bar the 52-pt row
        // with the window's buttons centered in it, and (unlike a bare NSToolbar) SwiftUI's lets
        // clicks through to the rows under it everywhere else.
        .toolbar {
            ToolbarSpacer(.flexible)
            // Its own glass, like the row's; the padding lines it up with the card's edge.
            ToolbarItem { SearchCapsule(app: app, inToolbar: true).padding(.trailing, 5) }.sharedBackgroundVisibility(.hidden)
        }
        .toolbar(removing: .title)
        // AppKit's own switch: SwiftUI's hidden toolbar still leaves the full-screen bar in place.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
            guard let w = note.object as? NSWindow, w.toolbar != nil else { return }
            fullScreen = true
            w.toolbar?.isVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
            guard let w = note.object as? NSWindow, w.toolbar != nil else { return }
            fullScreen = false
            w.toolbar?.isVisible = true
        }
        // Again once the window is back: during the way out the switch doesn't always take.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard let w = note.object as? NSWindow, w.toolbar != nil else { return }
            fullScreen = false
            w.toolbar?.isVisible = true
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    /// The title row's height: the window buttons sit centered in it.
    static let rowHeight: CGFloat = 52
    /// Room the window's buttons take at the row's start.
    static let buttonsWidth: CGFloat = 86
    /// Room Search takes at the row's end (it lives in the toolbar).
    static let searchWidth: CGFloat = 32
    /// The row's control groups: rounded squares of glass (the mock's), Search's too.
    static let capsuleHeight: CGFloat = 34
    static let capsuleRadius: CGFloat = capsuleHeight / 2
    /// The one distance between things: the window's edge to a piece of glass, a piece of
    /// glass to what's in it, and one piece to the next. It is what the title row leaves around
    /// its groups, so every side matches.
    static let gap: CGFloat = (rowHeight - capsuleHeight) / 2
    static let panelRadius: CGFloat = Glass.panelRadius
    /// Where the project's name starts, sidebar shown or hidden.
    static let titleX: CGFloat = 88
    /// The work surface's color where it fills the window (what the edge fade ends in).
    static let surface = Color(red: 0.055, green: 0.055, blue: 0.065)
}

/// The window's own glass: one material behind everything, the same from top to bottom.
struct NativeWindowGlass: View {
    var body: some View {
        ZStack {
            BehindWindowBlur(material: .hudWindow)
            Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.56) // the glass itself; the work surface darkens it further (NativeShell)
        }
    }
}

/// A small icon button for the rows on the glass.
struct RowIcon: View {
    let symbol: String
    let help: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hand)
        .foregroundStyle(.secondary)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: Sidebar

private struct NativeSidebar: View {
    let app: AppDelegate
    let fullScreen: Bool
    let hide: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // The title row: the window's buttons, the project and its branch, the sidebar toggle.
            HStack(spacing: 6) {
                Color.clear.frame(width: fullScreen ? 2 : NativeShell.titleX - NativeShell.gap * 2 - 6)
                ProjectTitle(app: app)
                Spacer(minLength: 4)
                RowIcon(symbol: "sidebar.left", help: "Hide Sidebar", action: hide)
            }
            .padding(.horizontal, NativeShell.gap)
            .frame(height: NativeShell.rowHeight - NativeShell.gap * 2) // the panel starts a gap down: the row still centers on the window's buttons
            .padding(.bottom, NativeShell.gap)
            // History, and where you work: the changes, all files, the browser.
            HStack(spacing: 2) {
                RowIcon(symbol: "chevron.left", help: "Back (⌘[)", disabled: !app.ui.canGoBack) { app.goBack() }
                RowIcon(symbol: "chevron.right", help: "Forward (⌘])", disabled: !app.ui.canGoForward) { app.goForward() }
                PlaceSwitcher(app: app).padding(.leading, 6)
            }
            .padding(.horizontal, NativeShell.gap)
            .padding(.bottom, 6)
            SidebarView(app: app)
        }
    }
}

/// Where you work: the changes, all files, the browser, as one segmented row filling the sidebar.
private struct PlaceSwitcher: View {
    let app: AppDelegate
    /// In the top row (sidebar hidden): fixed-width segments, not the sidebar's full width.
    var compact = false
    @Namespace private var thumb
    var body: some View {
        // One piece of glass, the same as the top row's groups; the selection slides between the places.
        HStack(spacing: 2) {
            segment(.changes, "checklist", "Changes (⌘1)")
            segment(.files, "folder", "All Files (⌘2)")
            segment(.browser, "safari", "Browser (⌘3)")
        }
        .padding(3)
        .frame(height: compact ? 28 : 30)
        // The tabs' track: a sheet of the same glass, lying on the sidebar's.
        .modifier(TabsTrack(compact: compact))
        .animation(Motion.move, value: app.place)
    }

    private func segment(_ place: AppDelegate.Place, _ symbol: String, _ help: String) -> some View {
        let on = app.place == place
        return Button { app.go(to: place) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(minWidth: compact ? 36 : nil, maxWidth: compact ? 36 : .infinity, maxHeight: .infinity)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: ((compact ? NativeShell.capsuleRadius : Glass.fieldRadius) - 3), style: .continuous).fill(Glass.fillStrong)
                            .matchedGeometryEffect(id: "thumb", in: thumb)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.hand)
        .environment(\.hoverRadius, ((compact ? NativeShell.capsuleRadius : Glass.fieldRadius) - 3))
        .foregroundStyle(on ? .primary : .secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The project's name and branch, a menu of projects, branches and commit.
private struct ProjectTitle: View {
    let app: AppDelegate
    var body: some View {
        GlassMenuButton(app: app, items: { ProjectMenu.items(app) }) {
            HStack(spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(app.projects.current?.lastPathComponent ?? "Vet").font(.system(size: 14, weight: .semibold))
                    if let branch = app.workspace.review.branch {
                        Text(branch).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.secondary)
                    .offset(y: 1)
            }
            // The whole title takes the click, gaps too (they'd drag the window otherwise).
            .padding(.vertical, 8).padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
    }
}

// MARK: Top row

/// Above the card: the open file and its controls, then Run and Search, in glass capsules.
private struct NativeTopRow: View {
    let app: AppDelegate
    let sidebarHidden: Bool
    let fullScreen: Bool
    let showSidebar: () -> Void

    var body: some View {
        HStack(spacing: NativeShell.gap) {
            if sidebarHidden {
                // Everything the sidebar's rows held comes up here: the project, history, the places.
                // As one bar of the sidebar's glass, the window's buttons on it.
                HStack(spacing: 8) {
                    // The same place the sidebar's row gives the title, so it stays put when the sidebar goes.
                    Color.clear.frame(width: fullScreen ? 0 : NativeShell.titleX - NativeShell.gap - 8)
                    ProjectTitle(app: app)
                    RowIcon(symbol: "sidebar.left", help: "Show Sidebar", action: showSidebar)
                    HStack(spacing: 0) {
                        RowIcon(symbol: "chevron.left", help: "Back (⌘[)", disabled: !app.ui.canGoBack) { app.goBack() }
                        RowIcon(symbol: "chevron.right", help: "Forward (⌘])", disabled: !app.ui.canGoForward) { app.goForward() }
                    }
                    PlaceSwitcher(app: app, compact: true).fixedSize()
                }
                .padding(.trailing, 3)
                .frame(height: NativeShell.capsuleHeight)
                .windowGlass(radius: NativeShell.capsuleRadius)
            }
            HStack(spacing: NativeShell.gap) {
                switch app.ui.location {
                case .diff?:
                    if let doc = app.workspace.review.diff { DiffHeader(app: app, doc: doc) } else { Spacer() }
                case .file?: EditorHeader(app: app)
                case .browser?: BrowserHeader(app: app)
                case nil: Spacer()
                }
                RunCapsule(app: app)
                if fullScreen { SearchCapsule(app: app) }
                else {
                    // Search is in the toolbar, over this spot: its glass is drawn here.
                    Color.clear.frame(width: NativeShell.capsuleHeight, height: NativeShell.capsuleHeight)
                        .windowGlass(radius: NativeShell.capsuleRadius)
                }
            }
        }
        .environment(\.headerInRow, true)
        .font(.system(size: 13))
        .padding(.leading, sidebarHidden ? NativeShell.gap : 4)
        .padding(.trailing, NativeShell.gap)
    }
}

/// Controls grouped in one glass capsule in the top row (as macOS 26 toolbars group them).
/// Over the code (the classic header), just the controls.
struct RowGroup<Content: View>: View {
    @Environment(\.headerInRow) private var inRow
    @ViewBuilder let content: Content
    var body: some View {
        if inRow {
            HStack(spacing: 2) { content }
                .foregroundStyle(.secondary)
                .tint(.secondary)
                .padding(.horizontal, 5)
                .frame(height: NativeShell.capsuleHeight)
                .groupGlass()
        } else {
            content
        }
    }
}

/// Run (or Stop) and the configuration it runs.
private struct RunCapsule: View {
    let app: AppDelegate
    var body: some View {
        let run = app.workspace.run, ui = app.ui
        HStack(spacing: 4) {
            Button {
                if run.isRunning { run.stop() }
                else if run.configs.isEmpty { ui.editingRunConfigs = true }
                else { run.start(); run.outputVisible = true }
            } label: {
                Image(systemName: run.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(run.isRunning ? Color(nsColor: .systemRed) : Color(nsColor: DiffTheme.added))
                    .frame(width: 22, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hand)
            .help(run.isRunning ? "Stop (⌘.)" : run.selected.map { "Run ‘\($0.name)’ (⌘R)" } ?? "Run (⌘R)")
            GlassMenuButton(app: app, trailing: true, help: "Run Configurations", items: {
                run.configs.map { c in .item(title: c.name, checked: c.id == run.selected?.id) { run.selectedID = c.id } }
                    + (run.configs.isEmpty ? [] : [.divider])
                    + [.item(title: "Edit Configurations…") { ui.editingRunConfigs = true }]
            }) {
                Text(run.selected?.name ?? "Run").lineLimit(1)
                    .frame(height: 28).contentShape(Rectangle())
            }
        }
        .padding(.leading, 6).padding(.trailing, 12)
        .frame(height: NativeShell.capsuleHeight)
        .groupGlass()
    }
}

private struct SearchSurface: ViewModifier {
    let bare: Bool
    func body(content: Content) -> some View {
        if bare { content } else { content.groupGlass() }
    }
}

/// Search Everywhere: a capsule that opens the search panel (⇧⇧ or ⇧⌘O too).
private struct SearchCapsule: View {
    let app: AppDelegate
    /// In the window's toolbar: its glass is drawn by the row under it, not here.
    var inToolbar = false
    var body: some View {
        Button { app.ui.focusSearch = true } label: {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
                .frame(width: NativeShell.capsuleHeight, height: NativeShell.capsuleHeight).contentShape(Rectangle())
        }
        .buttonStyle(.hand)
        .environment(\.hoverRadius, NativeShell.capsuleRadius)
        .foregroundStyle(.secondary)
        .modifier(SearchSurface(bare: inToolbar))
        .help("Search Everywhere (⇧⇧)")
    }
}

/// Search Everywhere, as Spotlight sits: a glass panel in the middle of the window, near the top.
/// A click outside it or Esc closes it.
private struct SearchOverlay: View {
    let app: AppDelegate
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .onContinuousHover { if case .active = $0 { NSCursor.arrow.set() } } // not the I-beam of the code underneath
            SearchPanel(app: app)
                .glassPanel()
                                .popsIn(anchor: .top)
                .padding(.top, 120)
                .onExitCommand { close() }
        }
        .ignoresSafeArea()
    }
    private func close() { app.ui.focusSearch = false; app.ui.search = "" }
}

/// The search panel: the field, then files, symbols, actions and text, grouped as they arrive.
private struct SearchPanel: View {
    let app: AppDelegate
    @FocusState private var focused: Bool
    @State private var selected = 0

    var body: some View {
        let model = app.searchEverywhere
        // Before you type: the files you opened last. Then the results, grouped by kind.
        let typing = !app.ui.search.trimmingCharacters(in: .whitespaces).isEmpty
        let groups: [(title: String, items: [SearchItem])] = typing
            ? SearchEverywhereModel.order.map { kind in (SearchEverywhereModel.title(kind), model.items.filter { $0.kind == kind }) }.filter { !$0.items.isEmpty }
            : [("Recent", model.recentItems)].filter { !$0.items.isEmpty }
        let items = groups.flatMap(\.items)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Everywhere", text: Bindable(app.ui).search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { if items.indices.contains(selected) { model.choose(items[selected]) } }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, max(0, items.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .fieldGlass(radius: 18)
            .padding(8)
            if !items.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(groups, id: \.title) { group in
                                Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                                ForEach(group.items) { item in
                                    let index = items.firstIndex(where: { $0.id == item.id }) ?? 0
                                    SearchRow(app: app, item: item, selected: index == selected)
                                        .id(item.id)
                                        .onTapGesture { model.choose(item) }
                                }
                            }
                        }
                        .padding([.horizontal, .bottom], 6)
                    }
                    .onChange(of: selected) { _, i in if items.indices.contains(i) { proxy.scrollTo(items[i].id) } }
                }
                // As tall as its rows, up to a limit (a scroll view alone always takes the limit).
                .frame(height: min(380, CGFloat(items.count) * 29 + CGFloat(groups.count) * 26 + 12))
                .onContinuousHover { if case .active = $0 { NSCursor.arrow.set() } }
            }
        }
        .frame(width: 560)
        .onAppear { focused = true; selected = 0 }
        .onChange(of: app.ui.search) { _, _ in selected = 0 }
    }
}

private struct SearchRow: View {
    let app: AppDelegate
    let item: SearchItem
    let selected: Bool
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch item.kind {
                case .file: Image(nsImage: FileIcons.icon(for: item.title)).resizable().frame(width: 16, height: 16)
                case .symbol: Image(systemName: SearchEverywhereSuggestions.symbol(forKind: app.searchEverywhere.symbolKind(item)))
                case .action: Image(systemName: "command")
                case .text: Image(systemName: "text.alignleft")
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 18)
            Text(item.kind == .text ? SearchEverywhereSuggestions.codeLine(item) : AttributedString(item.title)).lineLimit(1)
                .font(item.kind == .text ? .system(size: 12, design: .monospaced) : .body)
            Text(item.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: Glass.panelRadius - 6, style: .continuous).fill(selected ? Glass.fillStrong : hovering ? Glass.fill : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}


// STUDY (not shipped): looks picked with VET_FRAME=f1…f6 and VET_BTN=flat|line|glass|bare.

/// The tabs' track: an outlined field in the menu panel; in the top row (menu hidden), one of its round buttons.
private struct TabsTrack: ViewModifier {
    let compact: Bool
    func body(content: Content) -> some View {
        if compact { content.windowGlass(radius: NativeShell.capsuleRadius) } else { content.fieldGlass() }
    }
}
