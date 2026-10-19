import AppKit
import SwiftUI
import VetCore

@main
struct VetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    init() {
        signal(SIGPIPE, SIG_IGN) // a git process that exits early must not take Vet down with it
    }

    var body: some Scene {
        Window("Vet", id: "main") {
            RootView(app: app)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified)
        .commands { VetCommands(app: app) }
    }
}

/// Owns the app's state and handles quitting (unsaved edits, stopping what Vet started).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let projects = ProjectStore()
    let workspace = Workspace()
    let ui = UIState()
    let searchEverywhere = SearchEverywhereModel()
    let find = FindModel()
    /// Claude talks to Vet through this while Vet is open.
    private(set) var mcp: MCPServer?
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Vet is a dark app with its own surfaces (the theme's window, sidebar and bar colors).
        NSApp.appearance = NSAppearance(named: .darkAqua)
        CodeFont.registerBundled()
        installDoubleShift()
        hideFocusRings()
        mcp = MCPServer(tools: VetTools.make(self))
        mcp?.start()
        searchEverywhere.app = self
        find.app = self
        workspace.onOpenProject = { [weak self] url in self?.projects.open(url) }
        projects.mayLeave = { [weak self] in self?.workspace.confirmLeave() ?? true }
        workspace.onOpenFile = { [weak self] url, line in self?.ui.show(.file(url: url, line: line)) }
        Task { _ = await ShellEnvironment.load() } // warm up: Run and the language servers need it
        SnapshotHook.install()
        SnapshotHook.on("open") { [weak self] args in
            guard let self, let root = self.projects.current, let path = args.first else { return }
            self.showFile(root.appendingPathComponent(path), line: args.count > 1 ? Int(args[1]) ?? 0 : 0)
        }
        SnapshotHook.on("frames") { [weak self] args in self?.workspace.files.editorView.debugFrames(line: Int(args.first ?? "0") ?? 0) }
        SnapshotHook.on("se") { [weak self] args in
            guard let self else { return }
            self.ui.search = args.joined(separator: " ")
            Task {
                try? await Task.sleep(for: .seconds(2))
                let out = "query=\(self.ui.search)\n" + self.searchEverywhere.items.map { "\($0.kind) \($0.id) | \($0.title) | \($0.detail)" }.joined(separator: "\n")
                if let dir = ProcessInfo.processInfo.environment["VET_SNAPSHOT_DIR"] { try? out.write(toFile: dir + "/search.txt", atomically: true, encoding: .utf8) }
            }
        }
        SnapshotHook.on("theme") { [weak self] args in if let id = args.first { DiffTheme.setTheme(id); self?.ui.themeID = id } }
        SnapshotHook.on("font") { [weak self] args in
            if let f = CodeFont(rawValue: args.joined(separator: " ")) { DiffTheme.setCodeFont(f); self?.ui.codeFont = f }
        }
        SnapshotHook.on("usages") { [weak self] args in
            // usages <line> <character>: Find Usages from the open editor file
            guard let self, args.count == 2, let line = Int(args[0]), let ch = Int(args[1]), let url = self.workspace.files.openURL else { return }
            let view = self.workspace.files.editorView
            NavigationAnchor.set(view.pane, view.pane.symbolRect(line: line, character: ch))
            self.workspace.navigate(.references, url: url, text: view.currentText, line: line, character: ch)
        }
        SnapshotHook.on("checkout") { [weak self] args in if let b = args.first { self?.workspace.review.checkout(b) } }
        SnapshotHook.on("center") { _ in
            for w in NSApp.windows where w.isVisible && w.frame.width > 400 { w.setFrame(NSRect(x: 218, y: 92, width: 1440, height: 900), display: true) }
        }
        SnapshotHook.on("views") { _ in
            // views: the main window's view tree (class, frame, effect material) to VET_SNAPSHOT_DIR/views.txt
            guard let dir = ProcessInfo.processInfo.environment["VET_SNAPSHOT_DIR"],
                  let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }), let root = w.contentView?.superview else { return }
            var out = ""
            func walk(_ v: NSView, _ d: Int) {
                let f = v.convert(v.bounds, to: nil)
                var extra = ""
                if let e = v as? NSVisualEffectView { extra = " material=\(e.material.rawValue) blend=\(e.blendingMode.rawValue)" }
                if let l = v.layer, let bg = l.backgroundColor { extra += " bg=\(bg)" }
                out += String(repeating: "  ", count: d) + "\(type(of: v)) \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))\(v.isHidden ? " hidden" : "")\(extra)\n"
                if d < 14 { v.subviews.forEach { walk($0, d + 1) } }
            }
            walk(root, 0)
            try? out.write(toFile: dir + "/views.txt", atomically: true, encoding: .utf8)
        }
        SnapshotHook.on("stagehunk") { [weak self] args in
            // stagehunk <n>: mark the open diff's nth change reviewed
            guard let self, let staging = self.workspace.review.diff?.staging, let n = Int(args.first ?? "0"), n < staging.hunks.count else { return }
            self.workspace.review.setHunk(staging.hunks[n].id, staged: true, snapshot: staging.snapshotID)
        }
        SnapshotHook.on("type") { [weak self] args in
            // type <needle> <text…>: type text after the first match of needle in the diff's new side
            guard let self, args.count >= 2 else { return }
            self.workspace.review.diffView.debugType(args.dropFirst().joined(separator: " "), after: args[0])
        }
        SnapshotHook.on("decorate") { [weak self] _ in self?.workspace.files.editorView.debugDecorate() }
        SnapshotHook.on("hover") { [weak self] args in
            guard args.count == 2, let line = Int(args[0]), let character = Int(args[1]) else { return }
            self?.workspace.files.editorView.debugHover(line: line, character: character)
        }
        // Tests pin a throwaway project and never follow Claude into a real one.
        if let project = SnapshotHook.testProject { projects.open(project) }
        if !SnapshotHook.isTesting { NSApp.activate() } // tests run in the background, never stealing focus
    }

    // MARK: Commands shared by the menu bar and the toolbar

    func save() {
        switch ui.location {
        case .diff: workspace.review.diffSave?()
        case .file: workspace.files.saveEditor()
        default: NSSound.beep()
        }
    }

    func goBack() { if let target = ui.goBack() { apply(target) } }
    func goForward() { if let target = ui.goForward() { apply(target) } }

    /// Shows a history entry without recording it again.
    private func apply(_ location: UIState.Location) {
        switch location {
        case .diff(let path):
            if !workspace.review.select(path) { _ = ui.goForward() }
        case .file(let url, let line):
            workspace.files.show(url, line: line, record: false)
        case .browser:
            break
        }
    }

    /// Opens a changed file's diff (asks about unsaved diff edits first).
    func showDiff(_ path: String) {
        guard workspace.review.select(path) else { return }
        ui.show(.diff(path: path))
    }

    /// Opens a file in the editor at a line.
    func showFile(_ url: URL, line: Int = 0, character: Int = 0) {
        workspace.files.show(url, line: line, character: character)
        if workspace.files.openURL == url { ui.show(.file(url: url, line: line)) }
    }

    func showBrowser() { ui.show(.browser) }

    /// Registers Vet's MCP server with Claude Code (once, for every project): Claude can then set
    /// the review order, read your selection and open files here while Vet is running.
    func connectClaudeCode() {
        let cmd = "claude mcp add --transport http --scope user vet \(MCPServer.url)"
        let a = NSAlert()
        a.messageText = "Connect Claude Code to Vet?"
        a.informativeText = "Runs this once, adding Vet to Claude Code for all projects:\n\n\(cmd)\n\nAfterwards, start a new Claude Code session. While Vet is open, Claude can set your review order, see what you've selected, and open files here."
        a.addButton(withTitle: "Connect")
        a.addButton(withTitle: "Copy Command")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            Task {
                let env = await ShellEnvironment.load()
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", "claude mcp remove --scope user vet >/dev/null 2>&1; " + cmd]
                p.environment = env
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch {}
                p.waitUntilExit()
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let done = NSAlert()
                done.messageText = p.terminationStatus == 0 ? "Vet is connected to Claude Code" : "Couldn't connect"
                done.informativeText = p.terminationStatus == 0 ? "Start a new Claude Code session to use it." : out.isEmpty ? "Is Claude Code installed (the claude command)?" : out
                done.runModal()
            }
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
        default: break
        }
    }

    /// No focus rings on text fields (search, address, configurations): the caret shows focus.
    private func hideFocusRings() {
        NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                // The field being typed in is the field editor's delegate, or (for the toolbar's
                // search field) the text field the field editor sits in.
                guard let w = NSApp.keyWindow else { return }
                // The toolbar's search field draws its ring from the moment it takes focus: turn it
                // off before then.
                if let frame = w.contentView?.superview { Self.noRings(in: frame) }
                guard let fr = w.firstResponder as? NSTextView, fr.isFieldEditor else { return }
                var field = fr.delegate as? NSTextField
                var v: NSView? = fr.superview
                while field == nil, let cur = v { field = cur as? NSTextField; v = cur.superview }
                guard let field, field.focusRingType != .none else { return }
                field.focusRingType = .none
                field.needsDisplay = true
                field.superview?.needsDisplay = true
            }
        }
    }

    private static func noRings(in v: NSView) {
        if let f = v as? NSSearchField, f.focusRingType != .none { f.focusRingType = .none; f.cell?.focusRingType = .none }
        for sub in v.subviews { noRings(in: sub) }
    }

    // Double Shift opens Search Everywhere (files, classes, symbols, actions), as in IntelliJ.
    private var lastShiftUp: TimeInterval = 0
    private var shiftDownClean = false
    private func installDoubleShift() {
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown { self.shiftDownClean = false; self.lastShiftUp = 0; return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .shift { self.shiftDownClean = true; return event } // Shift went down alone
            if flags.isEmpty, self.shiftDownClean { // ...and came up with nothing pressed in between
                self.shiftDownClean = false
                let now = event.timestamp
                if now - self.lastShiftUp < 0.4 { self.lastShiftUp = 0; self.ui.focusSearch = true } else { self.lastShiftUp = now }
            } else {
                self.shiftDownClean = false
            }
            return event
        }
    }

    /// The toolbar's switcher: the changes (diff), all files (project tree + editor), the browser.
    enum Place: Hashable { case changes, files, browser }
    var place: Place {
        if case .browser? = ui.location { return .browser }
        return ui.tool == .project ? .files : .changes
    }
    func go(to place: Place) {
        switch place {
        case .changes:
            ui.tool = .changes
            if let p = workspace.review.selectedPath { showDiff(p) }
        case .files:
            ui.tool = .project
            if case .browser? = ui.location, let url = workspace.files.openURL { showFile(url) }
        case .browser:
            showBrowser()
        }
    }

    func showFindInFiles() { FindPresenter.shared.show(app: self) }

    // MARK: Actions (Search Everywhere lists the menu commands)

    var actionList: [(id: String, title: String)] {
        let review = workspace.review, run = workspace.run
        var list: [(String, String)] = [
            ("openFolder", "Open Folder…"), ("save", "Save"), ("back", "Back"), ("forward", "Forward"),
            ("findInFiles", "Find in Files…"), ("previousChange", "Previous Change"), ("nextChange", "Next Change"),
            ("nextUnreviewed", "Next Unreviewed File"), ("commit", "Commit…"),
            ("rules", "Unimportant Files…"), ("refresh", "Refresh"), ("runConfigs", "Edit Run Configurations…"),
            // Both directions of each switch, so either name finds it.
            ("output.show", "Show Run Output"), ("output.hide", "Hide Run Output"),
            ("fold.on", "Fold Unchanged Lines"), ("fold.off", "Show Unchanged Lines"),
            ("layout.unified", "Unified Diff"), ("layout.split", "Side-by-Side Diff"),
        ]
        _ = review
        if run.isRunning { list.append(("stop", "Stop")) } else if run.selected != nil { list.append(("run", "Run ‘\(run.selected!.name)’")) }
        list += UIState.Tool.allCases.map { ("tool.\($0.rawValue)", "Show \($0.title)") }
        list.append(("browser", "Show Browser"))
        return list
    }

    func runAction(_ id: String) {
        let review = workspace.review, run = workspace.run
        switch id {
        case "openFolder": projects.showOpenPanel()
        case "save": save()
        case "back": goBack()
        case "forward": goForward()
        case "findInFiles": showFindInFiles()
        case "browser": showBrowser()
        case "previousChange": review.jumpToChange(forward: false)
        case "nextChange": review.jumpToChange(forward: true)
        case "nextUnreviewed": review.nextUnreviewed(); if let p = review.selectedPath { ui.show(.diff(path: p)) }
        case "commit": ui.showCommit = true
        case "rules": ui.editingRules = true
        case "refresh": Task { await review.refresh() }
        case "runConfigs": ui.editingRunConfigs = true
        case "output.show": run.outputVisible = true
        case "output.hide": run.outputVisible = false
        case "fold.on": review.folding = true
        case "fold.off": review.folding = false
        case "layout.unified": review.unified = true
        case "layout.split": review.unified = false
        case "run": run.start(); run.outputVisible = true
        case "stop": run.stop()
        default:
            if id.hasPrefix("tool."), let tool = UIState.Tool(rawValue: String(id.dropFirst(5))) { ui.tool = tool }
        }
    }

    // MARK: Quitting

    /// Asks about unsaved edits, then stops your running app and the language servers before
    /// quitting (at most 5 s), so nothing Vet started is left behind.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateLater }
        guard workspace.confirmLeave() else { return .terminateCancel }
        quitting = true
        var replied = false
        func reply() {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        let run = workspace.run, navigator = workspace.navigator
        Task {
            async let stopped: Void = run.stopAndWait()
            async let servers: Void = navigator?.shutdownAndWait() ?? ()
            _ = await (stopped, servers)
            reply()
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            reply()
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspace.link.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The menu bar. Every toolbar action is here too, with its shortcut (people can hide the toolbar).
struct VetCommands: Commands {
    let app: AppDelegate

    var body: some Commands {
        SidebarCommands()
        ToolbarCommands()
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") { app.projects.showOpenPanel() }.keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(app.projects.recent, id: \.self) { url in
                    Button(url.lastPathComponent) { app.projects.open(url) }
                }
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { app.save() }.keyboardShortcut("s")
        }
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Array(UIState.Tool.allCases.enumerated()), id: \.element) { index, tool in
                Button(tool == .changes ? "Changes" : "All Files") { app.go(to: tool == .changes ? .changes : .files) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Button("Browser") { app.showBrowser() }.keyboardShortcut("3")
            Divider()
            Picker("Theme", selection: Binding(get: { app.ui.themeID }, set: { DiffTheme.setTheme($0); app.ui.themeID = $0 })) {
                ForEach(Palette.all, id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker("Code Font", selection: Binding(get: { app.ui.codeFont }, set: { DiffTheme.setCodeFont($0); app.ui.codeFont = $0 })) {
                ForEach(CodeFont.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Divider()
            Button("Bigger Code Text") { DiffTheme.setFontSize(DiffTheme.fontSize + 1) }.keyboardShortcut("+")
            Button("Smaller Code Text") { DiffTheme.setFontSize(DiffTheme.fontSize - 1) }.keyboardShortcut("-")
            Button("Actual Code Text Size") { DiffTheme.setFontSize(DiffTheme.defaultFontSize) }.keyboardShortcut("0")
            Divider()
            Button(app.workspace.run.outputVisible ? "Hide Run Output" : "Show Run Output") { app.workspace.run.outputVisible.toggle() }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            Button(app.workspace.review.folding ? "Show Unchanged Lines" : "Fold Unchanged Lines") { app.workspace.review.folding.toggle() }
            Picker("Diff Layout", selection: Bindable(app.workspace.review).unified) {
                Text("Side by Side").tag(false)
                Text("Unified").tag(true)
            }
        }
        CommandMenu("Navigate") {
            Button("Back") { app.goBack() }.keyboardShortcut("[").disabled(!app.ui.canGoBack)
            Button("Forward") { app.goForward() }.keyboardShortcut("]").disabled(!app.ui.canGoForward)
            Divider()
            Button("Search Everywhere") { app.ui.focusSearch = true }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Find in Files…") { app.showFindInFiles() }.keyboardShortcut("f", modifiers: [.command, .shift])
        }
        CommandMenu("Review") {
            Button("Previous Change") { app.workspace.review.jumpToChange(forward: false) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next Change") { app.workspace.review.jumpToChange(forward: true) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Connect Claude Code…") { app.connectClaudeCode() }
            Button(app.workspace.review.plan == nil ? "No Review Order from Claude" : "Clear Claude's Review Order") { app.workspace.review.setPlan(nil) }
                .disabled(app.workspace.review.plan == nil)
            Divider()
            Button("Approve Change and Next") { app.workspace.review.approveAndNext() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Next Unreviewed File") { app.workspace.review.nextUnreviewed(); if let p = app.workspace.review.selectedPath { app.ui.show(.diff(path: p)) } }
                .keyboardShortcut("u", modifiers: [.command, .option])
            Divider()
            Button("Commit…") { app.ui.showCommit = true }.keyboardShortcut("k")
            Divider()
            Button("Unimportant Files…") { app.ui.editingRules = true }
            Button("Refresh") { Task { await app.workspace.review.refresh() } }.keyboardShortcut("r", modifiers: [.command, .option])
        }
        CommandMenu("Run") {
            let run = app.workspace.run
            Button(run.selected.map { "Run ‘\($0.name)’" } ?? "Run") { run.start() }.keyboardShortcut("r").disabled(run.isRunning || run.selected == nil)
            Button("Stop") { run.stop() }.keyboardShortcut(".").disabled(!run.isRunning)
            Divider()
            Button("Edit Configurations…") { app.ui.editingRunConfigs = true }
        }
    }
}
