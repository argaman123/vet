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
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        searchEverywhere.app = self
        find.app = self
        workspace.onOpenProject = { [weak self] url in self?.projects.open(url) }
        projects.mayLeave = { [weak self] in self?.workspace.confirmLeave() ?? true }
        workspace.onOpenFile = { [weak self] url, line in self?.ui.show(.file(url: url, line: line)) }
        Task { _ = await ShellEnvironment.load() } // warm up: Run and the language servers need it
        workspace.startLink()
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

    func showFindInFiles() {
        ui.tool = .find
        find.focusSerial += 1
    }

    // MARK: Actions (Search Everywhere lists the menu commands)

    var actionList: [(id: String, title: String)] {
        let review = workspace.review, run = workspace.run
        var list: [(String, String)] = [
            ("openFolder", "Open Folder…"), ("save", "Save"), ("back", "Back"), ("forward", "Forward"),
            ("findInFiles", "Find in Files…"), ("previousChange", "Previous Change"), ("nextChange", "Next Change"),
            ("nextUnreviewed", "Next Unreviewed File"), ("commit", "Commit…"), ("sendNotes", "Send Notes to Claude"),
            ("rules", "Unimportant Files…"), ("refresh", "Refresh"), ("runConfigs", "Edit Run Configurations…"),
            // Both directions of each switch, so either name finds it.
            ("output.show", "Show Run Output"), ("output.hide", "Hide Run Output"),
            ("fold.on", "Fold Unchanged Lines"), ("fold.off", "Show Unchanged Lines"),
            ("layout.unified", "Unified Diff"), ("layout.split", "Side-by-Side Diff"),
        ]
        _ = review
        if run.isRunning { list.append(("stop", "Stop")) } else if run.selected != nil { list.append(("run", "Run ‘\(run.selected!.name)’")) }
        list += UIState.Tool.allCases.map { ("tool.\($0.rawValue)", "Show \($0.title)") }
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
        case "previousChange": review.jumpToChange(forward: false)
        case "nextChange": review.jumpToChange(forward: true)
        case "nextUnreviewed": review.nextUnreviewed(); if let p = review.selectedPath { ui.show(.diff(path: p)) }
        case "commit": ui.showCommit = true
        case "sendNotes": review.sendNotes()
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
                Button(tool.title) { app.ui.tool = tool }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
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
            Button("Next Unreviewed File") { app.workspace.review.nextUnreviewed(); if let p = app.workspace.review.selectedPath { app.ui.show(.diff(path: p)) } }
                .keyboardShortcut("u", modifiers: [.command, .option])
            Divider()
            Button("Commit…") { app.ui.showCommit = true }.keyboardShortcut("k")
            Divider()
            Button("Send Notes to Claude") { app.workspace.review.sendNotes() }.disabled(app.workspace.review.unsentNotes.isEmpty)
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
