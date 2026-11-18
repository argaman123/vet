import Foundation

/// The coding agent working with Vet, by the name it gives itself when it connects (Claude Code says
/// "claude-code", Codex "codex-mcp-client"…). Labels use it, so Vet speaks of the agent you actually use.
enum Agent {
    private static let key = "agentName"
    /// The last agent that connected; "Agent" until one has.
    static var name: String { UserDefaults.standard.string(forKey: key) ?? "Agent" }

    /// From MCP's initialize: its clientInfo.
    static func connected(clientInfo: [String: Any]?) {
        guard let info = clientInfo else { return }
        let raw = ((info["name"] as? String) ?? "").lowercased()
        let known: [(String, String)] = [("claude", "Claude"), ("codex", "Codex"), ("cursor", "Cursor"), ("gemini", "Gemini"),
                                         ("copilot", "Copilot"), ("windsurf", "Windsurf"), ("zed", "Zed"), ("cline", "Cline")]
        let name = known.first { raw.contains($0.0) }?.1
            ?? (info["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? raw.split(whereSeparator: { !$0.isLetter }).first.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        if let name, !name.isEmpty { UserDefaults.standard.set(name, forKey: key) }
    }
}
