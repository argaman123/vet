import AppKit
import Observation
import VetCore

/// Vet's side of the link to Claude: drafts go to the Claude chat you're looking at (through the
/// vet-bridge mod) or, if it isn't connected, to the clipboard. Nothing is ever sent for you.
@MainActor @Observable
final class ClaudeLink {
    let router = BridgeRouter()
    private var server: BridgeServer?
    /// The Claude session's folder, for following its project.
    private(set) var claudeFolder: String?
    private(set) var connected = false
    /// Shown briefly after a draft goes out ("Draft is in Claude's message box").
    private(set) var toast: String?
    private var toastSerial = 0
    var onTurnComplete: ((String) -> Void)?
    /// The Claude chat you're working in moved to another folder (you switched chats or projects).
    var onFolderChanged: ((String) -> Void)?

    func start() {
        router.onTurnComplete = { cwd in Task { @MainActor in self.onTurnComplete?(cwd) } }
        router.onSessionsChanged = { Task { @MainActor in self.refreshStatus() } }
        let s = BridgeServer(router: router)
        do { try s.start(); server = s } catch { NSLog("Vet bridge: couldn't start: \(error)") }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in MainActor.assumeIsolated { self.refreshStatus() } }
    }

    func stop() { server?.stop() }

    private func refreshStatus() {
        let s = router.showingSession()
        connected = s != nil
        if let cwd = s?.cwd, cwd != claudeFolder {
            claudeFolder = cwd
            onFolderChanged?(cwd)
        }
    }

    /// Puts `text` into Claude's message box as a draft, or on the clipboard as a fallback.
    func sendDraft(_ text: String) {
        refreshStatus()
        if connected {
            router.enqueue(text)
            show("Draft is in Claude's message box. Check it and press send.")
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            show("Copied for Claude (the Claude link isn't connected). Paste it into the chat.")
        }
    }

    private func show(_ message: String) {
        toast = message
        toastSerial += 1
        let serial = toastSerial
        Task {
            try? await Task.sleep(for: .seconds(5))
            if self.toastSerial == serial { self.toast = nil }
        }
    }

    // MARK: Installing the Claude Desktop mod

    static var modFolder: URL? {
        // Shipped next to the app's sources while Vet is built from the repo.
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("bridge-mod"),
                          URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                              .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bridge-mod")]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".claude-plugin/marketplace.json").path) }
    }

    /// Adds the bridge-mod marketplace and installs vet-bridge with the `claude` command line tool.
    func installMod() async -> String {
        guard let folder = Self.modFolder else { return "Couldn't find the bridge mod folder." }
        let env = await LoginEnvironment.shared.values()
        func claude(_ args: [String]) -> (Int32, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", "claude " + args.map { "'\($0)'" }.joined(separator: " ")]
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            guard (try? p.run()) != nil else { return (-1, "claude not found") }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        let add = claude(["plugin", "marketplace", "add", folder.path])
        let install = claude(["plugin", "install", "vet-bridge@vet"])
        if install.0 == 0 { return "Installed. New Claude Code sessions will connect to Vet." }
        return "Install failed:\n\(add.1)\n\(install.1)"
    }
}
