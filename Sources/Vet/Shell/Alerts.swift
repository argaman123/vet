import AppKit

/// The standard "Save changes?" question, as macOS apps ask it.
@MainActor
enum Alerts {
    enum UnsavedChoice { case save, discard, cancel }

    static func unsaved(_ what: String) -> UnsavedChoice {
        let alert = NSAlert()
        alert.messageText = "Save your changes to \(what)?"
        alert.informativeText = "Your edits will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// The file changed on disk while you were editing it.
    static func changedOnDisk(_ what: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(what) changed on disk while you were editing it."
        alert.informativeText = "Saving now replaces those changes (probably Claude's) with your version."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Save Anyway")
        alert.alertStyle = .warning
        return alert.runModal() == .alertSecondButtonReturn
    }
}
