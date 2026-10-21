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
        .commands {
            VetCommands(app: app)
            ModsMenu(host: ModHost.shared)
        }
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
        registerCommands()
        ModHost.shared.start(app: self)
        mcp = MCPServer(tools: VetTools.make(self))
        mcp?.start()
        searchEverywhere.app = self
        find.app = self
        workspace.onOpenProject = { [weak self] url in self?.projects.open(url) }
        workspace.onShowDiff = { [weak self] path in self?.showDiff(path) }
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
        SnapshotHook.on("scrollto") { [weak self] args in
            // scrollto <y>: both diff panes to y (negative = past the top), drawn at once
            guard let self, let y = Double(args.first ?? "") else { return }
            self.workspace.review.diffView.debugScroll(to: y)
        }
        SnapshotHook.on("loading") { [weak self] args in
            // loading <line> <character>: the lookup popover at a symbol of the open editor file
            guard let self, args.count == 2, let line = Int(args[0]), let ch = Int(args[1]) else { return }
            let view = self.workspace.files.editorView
            NavigationAnchor.set(view.pane, view.pane.symbolRect(line: line, character: ch))
            ReferencesPresenter.shared.beginLoading("Finding usages of HttpClient…")
        }
        SnapshotHook.on("trace") { [weak self] _ in
            // trace: the diff's scroll position for 1.2 s, to VET_SNAPSHOT_DIR/trace.txt (for smoothness)
            guard let dir = ProcessInfo.processInfo.environment["VET_SNAPSHOT_DIR"] else { return }
            self?.workspace.review.diffView.debugTrace(seconds: 1.2) { ys in
                try? ys.map { String(format: "%.1f", $0) }.joined(separator: " ").write(toFile: dir + "/trace.txt", atomically: true, encoding: .utf8)
            }
        }
        SnapshotHook.on("scrolltest") { [weak self] args in
            // scrolltest <points>: scroll the diff down step by step; per-step cost to VET_SNAPSHOT_DIR/scroll.txt
            guard let dir = ProcessInfo.processInfo.environment["VET_SNAPSHOT_DIR"] else { return }
            let view = self?.workspace.review.diffView
            view?.debugScrollTest(distance: CGFloat(Double(args.first ?? "") ?? 1500)) { costs in
                let sorted = costs.sorted()
                let frames = view?.debugFrames ?? []
                let gaps = zip(frames.dropFirst(), frames).map { ($0 - $1) * 1000 }
                let period = gaps.sorted().first.map { max($0, 1) } ?? 8.3
                let dropped = gaps.reduce(0) { $0 + max(0, Int(($1 / period).rounded()) - 1) }
                let line = String(format: "steps %d  median %.1f ms  p90 %.1f ms  max %.1f ms  |  frames %d, dropped %d, longest gap %.1f ms", costs.count, sorted[sorted.count / 2], sorted[sorted.count * 9 / 10], sorted.last ?? 0, frames.count, dropped, gaps.max() ?? 0)
                try? (line + "\n" + costs.map { String(format: "%.1f", $0) }.joined(separator: " ")).write(toFile: dir + "/scroll.txt", atomically: true, encoding: .utf8)
            }
        }
        SnapshotHook.on("lensclick") { [weak self] args in
            guard let dir = ProcessInfo.processInfo.environment["VET_SNAPSHOT_DIR"], let self else { return }
            let r = self.workspace.review.diffView.debugClickLens(Int(args.first ?? "0") ?? 0)
            try? r.write(toFile: dir + "/lens.txt", atomically: true, encoding: .utf8)
        }
        SnapshotHook.on("changebar") { [weak self] args in
            // changebar <n>: the editor's change bars to VET_SNAPSHOT_DIR/bars.txt, and the nth one's popover
            guard let self, let dir = ProcessInfo.processInfo.environment["VET_SNAPSHOT_DIR"] else { return }
            let gutter = self.workspace.files.editorView.lineGutter
            try? gutter.changeBars.map { "\($0.kind) \($0.lines) old \($0.oldStart)+\($0.old.count)" }.joined(separator: "\n")
                .write(toFile: dir + "/bars.txt", atomically: true, encoding: .utf8)
            if let n = Int(args.first ?? ""), n < gutter.changeBars.count { gutter.debugClickBar(n) }
        }
        SnapshotHook.on("browser") { [weak self] args in
            self?.showBrowser()
            if let url = args.first { self?.workspace.browser.go(url) }
        }
        SnapshotHook.on("tool") { [weak self] args in if let t = UIState.Tool(rawValue: args.first ?? "") { self?.ui.tool = t } }
        SnapshotHook.on("diff") { [weak self] args in if let p = args.first { self?.showDiff(p) } }
        SnapshotHook.on("websnap") { [weak self] _ in
            // websnap: the browser's page as WebKit draws it, to VET_SNAPSHOT_DIR/web.png
            guard let self, let dir = ProcessInfo.processInfo.environment["VET_SNAPSHOT_DIR"] else { return }
            let web = self.workspace.browser.webView
            web.takeSnapshot(with: nil) { image, _ in
                guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: URL(fileURLWithPath: dir + "/web.png"))
            }
        }
        SnapshotHook.on("select") { [weak self] args in
            // select <line> <count>: select whole lines in the open editor file
            guard let self, args.count == 2, let line = Int(args[0]), let count = Int(args[1]) else { return }
            let pane = self.workspace.files.editorView.pane
            if let a = pane.range(line: line, character: 0), let b = pane.range(line: line + count, character: 0) {
                pane.setSelectedRange(NSRange(location: a.location, length: b.location - a.location))
            }
        }
        SnapshotHook.on("hovermore") { _ in HoverPresenter.shared.expand() } // F1 on a hover
        SnapshotHook.on("collapse") { [weak self] args in self?.workspace.review.setAllCollapsed(args.first != "off") }
        SnapshotHook.on("approve") { [weak self] _ in self?.workspace.review.approveAndNext() } // ⌘↩
        SnapshotHook.on("nextchange") { [weak self] args in self?.workspace.review.jumpToChange(forward: args.first != "back") } // ⌘↓ / ⌘↑
        SnapshotHook.on("claudeforward") { _ in ClaudeReference.bringClaudeForward() } // test: the hand-off alone, clipboard untouched
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
        SnapshotHook.on("caret") { [weak self] args in
            // caret <bar|block|underline>: the editor's caret shape (the diff's work pane too)
            guard let self, let style = CaretStyle(rawValue: args.first ?? "") else { return }
            self.workspace.files.editorView.pane.caretStyle = style
        }
        SnapshotHook.on("keys") { [weak self] args in
            // keys <vim notation…>: keys typed into the focused code pane (see ModHost.debugKeys)
            guard let self else { return }
            let pane = ModHost.shared.pane ?? self.workspace.files.editorView.pane
            ModHost.shared.debugKeys(args.joined(separator: "<space>"), pane: pane)
        }
        SnapshotHook.on("focuspane") { [weak self] args in
            // focuspane editor|diff: focus a code pane (the window stays in the background)
            guard let self else { return }
            let pane = args.first == "diff" ? self.workspace.review.diffView.workPane : self.workspace.files.editorView.pane
            pane.window?.makeFirstResponder(pane)
        }
        SnapshotHook.on("state") { [weak self] _ in
            // state: the focused pane's caret, selection and current line to VET_SNAPSHOT_DIR/state.txt
            guard let self, let dir = ProcessInfo.processInfo.environment["VET_SNAPSHOT_DIR"], let p = ModHost.shared.pane else { return }
            let r = p.selectedRange(), ns = p.string as NSString
            let line = p.displayLines(of: NSRange(location: r.location, length: 0)).lowerBound
            let lr = ns.lineRange(for: NSRange(location: min(r.location, ns.length), length: 0))
            var out = "pane=\(p.paneKind) caret=\(p.caretStyle.rawValue) sel=\(r.location)+\(r.length) line=\(line) col=\(r.location - lr.location)\n"
            out += "text: " + ns.substring(with: lr).trimmingCharacters(in: .newlines) + "\n"
            out += "prompt: \(ModHost.shared.ui.prompt.map { $0.prefix + $0.text } ?? "-")  marks: \(p.modMarks.count)  dirty-editor: \(self.workspace.files.editorView.isDirty)\n"
            try? out.write(toFile: dir + "/state.txt", atomically: true, encoding: .utf8)
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
        ModHost.shared.emit("fileOpened", ["path": path, "pane": "diff"])
    }

    /// Opens a file in the editor at a line.
    func showFile(_ url: URL, line: Int = 0, character: Int = 0) {
        workspace.files.show(url, line: line, character: character)
        if workspace.files.openURL == url {
            ui.show(.file(url: url, line: line))
            ModHost.shared.emit("fileOpened", ["path": workspace.files.relativePath ?? url.path, "pane": "editor"])
        }
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

    /// Runs a command by id (see Commands.swift).
    func run(_ id: String) { CommandRegistry.shared.run(id) }

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
            Button("Open Folder…") { app.run("app.openFolder") }.keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(app.projects.recent, id: \.self) { url in
                    Button(url.lastPathComponent) { app.projects.open(url) }
                }
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { app.run("app.save") }.keyboardShortcut("s")
        }
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Array(UIState.Tool.allCases.enumerated()), id: \.element) { index, tool in
                Button(tool == .changes ? "Changes" : "All Files") { app.go(to: tool == .changes ? .changes : .files) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Button("Browser") { app.run("app.browser") }.keyboardShortcut("3")
            Divider()
            let _ = ModHost.shared.revision // mods add themes
            Picker("Theme", selection: Binding(get: { app.ui.themeID }, set: { DiffTheme.setTheme($0); app.ui.themeID = $0 })) {
                ForEach(Palette.available, id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker("Code Font", selection: Binding(get: { app.ui.codeFont }, set: { DiffTheme.setCodeFont($0); app.ui.codeFont = $0 })) {
                ForEach(CodeFont.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Divider()
            Button("Bigger Code Text") { app.run("app.text.bigger") }.keyboardShortcut("+")
            Button("Smaller Code Text") { app.run("app.text.smaller") }.keyboardShortcut("-")
            Button("Actual Code Text Size") { app.run("app.text.actual") }.keyboardShortcut("0")
            Divider()
            Button(app.workspace.run.outputVisible ? "Hide Run Output" : "Show Run Output") { app.run("app.output.toggle") }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            Button(app.workspace.review.folding ? "Show Unchanged Lines" : "Fold Unchanged Lines") { app.run("app.fold.toggle") }
            Toggle("Fold Reviewed Changes", isOn: Bindable(app.workspace.review).foldReviewed)
            // As in Xcode: fold or open everything (unchanged lines and reviewed changes).
            Button("Collapse All") { app.run("app.collapseAll") }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])
            Button("Expand All") { app.run("app.expandAll") }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
            Picker("Diff Layout", selection: Bindable(app.workspace.review).unified) {
                Text("Side by Side").tag(false)
                Text("Unified").tag(true)
            }
        }
        CommandMenu("Navigate") {
            Button("Back") { app.run("app.back") }.keyboardShortcut("[").disabled(!app.ui.canGoBack)
            Button("Forward") { app.run("app.forward") }.keyboardShortcut("]").disabled(!app.ui.canGoForward)
            Divider()
            Button("Search Everywhere") { app.run("app.searchEverywhere") }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Find in Files…") { app.run("app.findInFiles") }.keyboardShortcut("f", modifiers: [.command, .shift])
        }
        CommandMenu("Review") {
            // ⌘↑ ⌘↓ step through the changes; ⌘↩ approves the one you're on and moves to the next.
            // (Only in the diff: elsewhere the keys keep their usual meaning in text.)
            let inDiff = app.ui.location.map { if case .diff = $0 { true } else { false } } ?? false
            Button("Previous Change") { app.run("app.previousChange") }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!inDiff)
            Button("Next Change") { app.run("app.nextChange") }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!inDiff)
            Button("Connect Claude Code…") { app.run("app.connectClaude") }
            Button(app.workspace.review.plan == nil ? "No Review Order from Claude" : "Clear Claude's Review Order") { app.run("app.clearReviewOrder") }
                .disabled(app.workspace.review.plan == nil)
            Divider()
            Button("Approve Change and Next") { app.run("app.approveAndNext") }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Next Unreviewed File") { app.run("app.nextUnreviewed") }
                .keyboardShortcut("u", modifiers: [.command, .option])
            Divider()
            Button("Ask Claude to Commit Reviewed Files") { app.run("app.commit") }.keyboardShortcut("k")
            Divider()
            Button("Unimportant Files…") { app.run("app.rules") }
            Button("Refresh") { app.run("app.refresh") }.keyboardShortcut("r", modifiers: [.command, .option])
        }
        CommandMenu("Run") {
            let run = app.workspace.run
            Button(run.selected.map { "Run ‘\($0.name)’" } ?? "Run") { app.run("app.run") }.keyboardShortcut("r").disabled(run.isRunning || run.selected == nil)
            Button("Stop") { app.run("app.stop") }.keyboardShortcut(".").disabled(!run.isRunning)
            Divider()
            Button("Edit Configurations…") { app.run("app.runConfigs") }
        }
    }
}
