import AppKit
import VetCore

/// "Reference in Claude": the code you point at, as Claude reads it best (path, lines, the code
/// in a fenced block), on the clipboard, with Claude brought forward so ⌘V and a question follow.
@MainActor
enum ClaudeReference {
    static func send(path: String, lines: ClosedRange<Int>, code: String) {
        let range = lines.count > 1 ? "\(lines.lowerBound + 1)-\(lines.upperBound + 1)" : "\(lines.lowerBound + 1)"
        let lang = (path as NSString).pathExtension
        let text = "`\(path):\(range)`\n```\(lang)\n\(code)\n```\n"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        bringClaudeForward()
    }

    static let bundleID = "com.anthropic.claudefordesktop"

    /// Since macOS 14 an app can't pull another one forward on its own: Vet yields first, then
    /// Claude takes over (or is launched, frontmost).
    static func bringClaudeForward() {
        if let claude = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            NSApp.yieldActivation(to: claude)
            claude.activate(from: .current, options: [])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleID)
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
    }
}
