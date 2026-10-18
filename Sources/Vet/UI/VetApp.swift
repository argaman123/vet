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
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        workspace.onOpenProject = { [weak self] url in self?.projects.open(url) }
        projects.mayLeave = { [weak self] in self?.workspace.confirmLeave() ?? true }
        workspace.onOpenFile = { [weak self] url, line in self?.ui.show(.file(url: url, line: line)) }
        Task { _ = await ShellEnvironment.load() } // warm up: Run and the language servers need it
        workspace.startLink()
        SnapshotHook.install()
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
        }
        CommandMenu("Navigate") {
            Button("Back") { app.goBack() }.keyboardShortcut("[").disabled(!app.ui.canGoBack)
            Button("Forward") { app.goForward() }.keyboardShortcut("]").disabled(!app.ui.canGoForward)
            Divider()
            Button("Search Everywhere") { app.ui.focusSearch = true }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Find in Files…") { app.ui.tool = .find }.keyboardShortcut("f", modifiers: [.command, .shift])
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
