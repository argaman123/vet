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
        if let claude = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first {
            claude.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
