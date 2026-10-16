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
        workspace.startLink()
        workspace.onClaudeFinished = { [weak self] count in
            guard let self, self.state.selected != .review else { return }
            self.state.badges[.review] = count
        }
    }

    @objc func openFolder(_ sender: Any?) {
        projects.showOpenPanel()
    }

    @objc func goBack(_ sender: Any?) {
        state.selected = .files
        workspace.files.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        state.selected = .files
        workspace.files.goForward()
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspace.run.stop() // don't leave your dev server running after Vet quits
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
        // Routed to the focused code pane (CodeTextView.vetSave).
        file.addItem(withTitle: "Save", action: #selector(CodeTextView.vetSave(_:)), keyEquivalent: "s")
        fileItem.submenu = file
        menu.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
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
