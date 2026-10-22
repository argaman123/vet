import AppKit

/// Every command Vet can run, by id: the menus, Search Everywhere's actions, key bindings and mods
/// all go through here. `app.*` are Vet's own, `editor.*` are text commands for the focused code
/// pane (NSTextView's, such as `editor.moveWordForward:`), and mods add `<mod id>.*`.
@MainActor
final class CommandRegistry {
    static let shared = CommandRegistry()

    struct Command {
        let id: String
        let title: String
        /// Listed in Search Everywhere (switch-style pairs keep both names there).
        var listed = true
        /// The mod that added it (nil for Vet's own).
        var owner: String?
        let run: @MainActor ([Any]) -> Void
    }

    private(set) var commands: [Command] = []
    private var index: [String: Int] = [:]

    func register(_ id: String, _ title: String, listed: Bool = true, owner: String? = nil, run: @escaping @MainActor ([Any]) -> Void) {
        let c = Command(id: id, title: title, listed: listed, owner: owner, run: run)
        if let i = index[id] { commands[i] = c } else { index[id] = commands.count; commands.append(c) }
    }

    func remove(owner: String) {
        commands.removeAll { $0.owner == owner }
        index = Dictionary(uniqueKeysWithValues: commands.enumerated().map { ($1.id, $0) })
    }

    func title(_ id: String) -> String? { index[id].map { commands[$0].title } }

    /// Runs a command; false when there's no such command.
    @discardableResult
    func run(_ id: String, _ args: [Any] = []) -> Bool {
        if id.hasPrefix("editor.") { return Self.performText(String(id.dropFirst(7))) }
        guard let i = index[id] else { return false }
        commands[i].run(args)
        return true
    }

    /// The kinds of NSTextView command a mod may run. Others (`setString:`, `setDelegate:`) would be
    /// called with the text view as their argument and could take Vet down.
    private static let textCommands = ["move", "delete", "insert", "select", "scroll", "center", "transpose", "yank",
                                       "page", "indent", "uppercase", "lowercase", "capitalize", "cancel", "complete"]

    /// An NSTextView command (`moveWordForward:`) in the focused code pane.
    static func performText(_ name: String) -> Bool {
        guard let pane = ModHost.shared.pane, textCommands.contains(where: { name.hasPrefix($0) }) else { return false }
        let sel = NSSelectorFromString(name.hasSuffix(":") ? name : name + ":")
        guard pane.responds(to: sel) else { return false }
        pane.doCommand(by: sel)
        return true
    }
}

extension AppDelegate {
    /// Vet's own commands. Menus call them by id, so a key binding or a mod runs exactly what the
    /// menu item does.
    func registerCommands() {
        let r = CommandRegistry.shared, review = workspace.review, run = workspace.run
        func add(_ id: String, _ title: String, listed: Bool = true, _ body: @escaping () -> Void) {
            r.register("app." + id, title, listed: listed) { _ in body() }
        }
        add("openFolder", "Open Folder…") { [unowned self] in projects.showOpenPanel() }
        add("save", "Save") { [unowned self] in save() }
        add("back", "Back") { [unowned self] in goBack() }
        add("forward", "Forward") { [unowned self] in goForward() }
        add("searchEverywhere", "Search Everywhere") { [unowned self] in ui.focusSearch = true }
        add("findInFiles", "Find in Files…") { [unowned self] in showFindInFiles() }
        add("showChanges", "Show Changes") { [unowned self] in go(to: .changes) }
        add("showFiles", "Show All Files") { [unowned self] in go(to: .files) }
        add("browser", "Show Browser") { [unowned self] in showBrowser() }
        add("previousChange", "Previous Change") { review.jumpToChange(forward: false) }
        add("nextChange", "Next Change") { review.jumpToChange(forward: true) }
        add("approveAndNext", "Approve Change and Next") { review.approveAndNext() }
        add("nextUnreviewed", "Next Unreviewed File") { [unowned self] in
            review.nextUnreviewed()
            if let p = review.selectedPath { ui.show(.diff(path: p)) }
        }
        add("commit", "Ask Claude to Commit Reviewed Files") { review.askClaudeToCommit() }
        add("sendNotes", "Send Notes to Claude") { review.sendNotes() }
        add("addNote", "Add Note") { if review.diff != nil { review.diffView.writeNoteHere() } }
        add("connectClaude", "Connect Claude Code…") { [unowned self] in connectClaudeCode() }
        add("clearReviewOrder", "Clear Claude's Review Order") { review.setPlan(nil) }
        add("rules", "Unimportant Files…") { [unowned self] in ui.editingRules = true }
        add("refresh", "Refresh") { Task { await review.refresh() } }
        add("runConfigs", "Edit Run Configurations…") { [unowned self] in ui.editingRunConfigs = true }
        add("run", "Run") { run.start(); run.outputVisible = true }
        add("stop", "Stop") { run.stop() }
        add("output.toggle", "Show or Hide Run Output", listed: false) { run.outputVisible.toggle() }
        add("output.show", "Show Run Output") { run.outputVisible = true }
        add("output.hide", "Hide Run Output") { run.outputVisible = false }
        add("fold.toggle", "Fold or Show Unchanged Lines", listed: false) { review.folding.toggle() }
        add("fold.on", "Fold Unchanged Lines") { review.folding = true }
        add("fold.off", "Show Unchanged Lines") { review.folding = false }
        add("foldReviewed.toggle", "Fold Reviewed Changes") { review.foldReviewed.toggle() }
        add("collapseAll", "Collapse All") { review.setAllCollapsed(true) }
        add("expandAll", "Expand All") { review.setAllCollapsed(false) }
        add("layout.unified", "Unified Diff") { review.unified = true }
        add("layout.split", "Side-by-Side Diff") { review.unified = false }
        add("text.bigger", "Bigger Code Text") { DiffTheme.setFontSize(DiffTheme.fontSize + 1) }
        add("text.smaller", "Smaller Code Text") { DiffTheme.setFontSize(DiffTheme.fontSize - 1) }
        add("text.actual", "Actual Code Text Size") { DiffTheme.setFontSize(DiffTheme.defaultFontSize) }
        add("mods.reload", "Reload Mods") { ModHost.shared.reload() }
        add("mods.openFolder", "Open Mods Folder") { NSWorkspace.shared.open(ModHost.shared.userFolder) }
        r.register("app.theme", "Set Theme", listed: false) { [unowned self] args in
            guard let id = args.first as? String else { return }
            DiffTheme.setTheme(id); ui.themeID = DiffTheme.palette.id
        }
        r.register("app.open", "Open File", listed: false) { [unowned self] args in
            // app.open <path relative to the project> [line]
            guard let root = workspace.root, let path = args.first as? String else { return }
            showFile(root.appendingPathComponent(path), line: (args.count > 1 ? (args[1] as? NSNumber)?.intValue : nil) ?? 0)
        }
    }

    /// Search Everywhere's actions: the listed commands (Run names the selected configuration).
    var actionList: [(id: String, title: String)] {
        let run = workspace.run
        return CommandRegistry.shared.commands.filter { c in
            guard c.listed else { return false }
            switch c.id {
            case "app.run": return !run.isRunning && run.selected != nil
            case "app.stop": return run.isRunning
            default: return true
            }
        }.map { c in (c.id, c.id == "app.run" ? "Run ‘\(run.selected?.name ?? "")’" : c.title) }
    }

    func runAction(_ id: String) { CommandRegistry.shared.run(id) }
}
