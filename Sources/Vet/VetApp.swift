import AppKit
import SwiftUI
import VetCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var shared: AppDelegate?

    static func main() {
        signal(SIGPIPE, SIG_IGN) // a git process that exits early must not take Vet down with it
        let app = NSApplication.shared
        let delegate = AppDelegate()
        shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    let state = ShellState()
    let projects = ProjectStore()
    let workspace = Workspace()
    private var main: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMenu()
        main = MainWindowController(content: ContentView(state: state, projects: projects, workspace: workspace))
        main.show()
        NSApp.activate()
        workspace.onOpenProject = { [weak self] url in self?.projects.open(url) }
        projects.mayLeave = { [weak self] in self?.workspace.confirmLeave() ?? true }
        main.mayClose = { [weak self] in self?.workspace.confirmLeave() ?? true }
        workspace.onShowFiles = { [weak self] in self?.state.selected = .files }
        Task { _ = await ShellEnvironment.load() } // warm up: Run and the language servers need it
        workspace.startLink()
        workspace.onClaudeFinished = { [weak self] count in
            guard let self, self.state.selected != .review else { return }
            self.state.badges[.review] = count
        }
    }

    @objc func openFolder(_ sender: Any?) {
        projects.showOpenPanel()
    }

    /// ⌘S when no code pane has focus (say you just clicked the file tree): saves the open
    /// file of the tab you're looking at.
    @objc func vetSave(_ sender: Any?) {
        switch state.selected {
        case .files: workspace.files.saveEditor()
        case .review: workspace.review.diffSave?()
        default: NSSound.beep()
        }
    }

    @objc func goBack(_ sender: Any?) {
        state.selected = .files
        workspace.files.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        state.selected = .files
        workspace.files.goForward()
    }

    private var quitting = false

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

    private static func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Vet", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Vet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        let open = NSMenuItem(title: "Open Folder…", action: #selector(AppDelegate.openFolder(_:)), keyEquivalent: "o")
        file.addItem(open)
        file.addItem(.separator())
        // Routed to the focused code pane (CodeTextView.vetSave), else to AppDelegate.vetSave.
        file.addItem(withTitle: "Save", action: #selector(CodeTextView.vetSave(_:)), keyEquivalent: "s")
        fileItem.submenu = file
        menu.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)

        let goItem = NSMenuItem()
        let go = NSMenu(title: "Go")
        go.addItem(withTitle: "Back", action: #selector(AppDelegate.goBack(_:)), keyEquivalent: "[")
        go.addItem(withTitle: "Forward", action: #selector(AppDelegate.goForward(_:)), keyEquivalent: "]")
        goItem.submenu = go
        menu.addItem(goItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        return menu
    }
}
