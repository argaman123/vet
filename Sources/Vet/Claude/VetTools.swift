import AppKit
import VetCore

/// The tools Vet offers Claude over MCP.
@MainActor
enum VetTools {
    static func make(_ app: AppDelegate) -> [MCPServer.Tool] {
        let str: [String: Any] = ["type": "string"]
        let int: [String: Any] = ["type": "integer"]
        return [
            .init("vet_status", "What Vet is showing: the project, branch, every changed file with its review state (reviewed = marked in Vet, section by section; git's staging isn't used), the open file, and the current review plan.",
                  schema: ["type": "object", "properties": [:] as [String: Any]]) { _ in
                (status(app), false)
            },
            .init("set_review_plan", """
                Tell Vet the order the user should review the changed files in, with a short summary of each \
                (what changed and why it matters) and optional notes on key functions or lines. Vet lists the \
                files in this order and shows each summary when the file opens. Paths are relative to the \
                project root. Call again to replace the plan; an empty files list clears it.
                """,
                  schema: ["type": "object", "required": ["files"], "properties": [
                    "overview": ["type": "string", "description": "One or two sentences on the whole change."],
                    "files": ["type": "array", "items": ["type": "object", "required": ["path", "summary"], "properties": [
                        "path": str, "summary": str,
                        "notes": ["type": "array", "items": ["type": "object", "required": ["text"], "properties": [
                            "line": ["type": "integer", "description": "1-based line in the current file."],
                            "symbol": ["type": "string", "description": "A function or type name."],
                            "text": str,
                        ] as [String: Any]]],
                    ] as [String: Any]]],
                  ] as [String: Any]]) { args in
                setPlan(app, args)
            },
            .init("get_selection", "What the user is looking at in Vet right now: the open file (diff or editor), the selected lines and their text (or the caret's line), and the visible range. Use it when the user says \"this\", \"here\" or \"the line I'm on\".",
                  schema: ["type": "object", "properties": [:] as [String: Any]]) { _ in
                selection(app)
            },
            .init("open_in_vet", "Show a file in Vet: its diff if it's changed, else the editor, scrolled to a line.",
                  schema: ["type": "object", "required": ["path"], "properties": ["path": str, "line": int]]) { args in
                open(app, args)
            },
        ] + ModTools.make() + WorkTools.make(app)
    }

    private static func status(_ app: AppDelegate) -> String {
        let review = app.workspace.review
        guard let root = app.workspace.root else { return "No project is open in Vet." }
        var out = "Project: \(root.path)\nBranch: \(review.branch ?? "(detached)")\n"
        out += "Changed files (\(review.reviewedCount) of \(review.changes.count) reviewed):\n"
        for c in review.changes {
            let state = switch review.stage(of: c) { case .staged: "reviewed"; case .partial: "partly reviewed"; case .unstaged: "not reviewed" }
            out += "- \(c.path) [\(c.kind)] \(state)\n"
        }
        if case .diff(let p)? = app.ui.location { out += "Open: diff of \(p)\n" }
        if case .file(let u, _)? = app.ui.location { out += "Open: \(u.path) in the editor\n" }
        if let plan = review.plan { out += "Review plan: \(plan.files.count) files, set \(plan.created.formatted(date: .abbreviated, time: .shortened))\n" }
        return out
    }

    private static func setPlan(_ app: AppDelegate, _ args: [String: Any]) -> (String, Bool) {
        guard app.workspace.root != nil else { return ("No project is open in Vet.", true) }
        let raw = args["files"] as? [[String: Any]] ?? []
        if raw.isEmpty { app.workspace.review.setPlan(nil); return ("Review plan cleared.", false) }
        let changed = Set(app.workspace.review.changes.map(\.path))
        var files: [ReviewPlan.File] = [], unknown: [String] = []
        for f in raw {
            guard let path = (f["path"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "./ ")), !path.isEmpty else { continue }
            if !changed.contains(path) { unknown.append(path) }
            let notes = (f["notes"] as? [[String: Any]] ?? []).compactMap { n -> ReviewPlan.Note? in
                guard let t = n["text"] as? String else { return nil }
                return .init(line: (n["line"] as? Int).map { $0 - 1 }, symbol: n["symbol"] as? String, text: t)
            }
            files.append(.init(path: path, summary: f["summary"] as? String ?? "", notes: notes.isEmpty ? nil : notes))
        }
        app.workspace.review.setPlan(ReviewPlan(overview: args["overview"] as? String, files: files))
        let overview = (args["overview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        app.claudeDid(overview.isEmpty ? "Claude finished: \(files.count) file\(files.count == 1 ? "" : "s") to review, in order." : "Claude finished: \(overview)",
                      path: files.first?.path)
        var msg = "Vet now lists \(files.count) files in your order."
        if !unknown.isEmpty { msg += " Not among the changed files (shown anyway): \(unknown.joined(separator: ", "))." }
        let missing = changed.subtracting(files.map(\.path))
        if !missing.isEmpty { msg += " Changed but not in the plan (listed after it): \(missing.sorted().joined(separator: ", "))." }
        return (msg, false)
    }

    private static func selection(_ app: AppDelegate) -> (String, Bool) {
        switch app.ui.location {
        case .diff(let path)?:
            guard let s = app.workspace.review.diffView.selectionInfo() else { return ("Showing the diff of \(path); nothing selected.", false) }
            var out = "File: \(path) (diff, \(s.head ? "old side: the last commit" : "new side: the working file"))\n"
            out += "\(s.selected ? "Selected" : "Caret on") line\(s.lines.count > 1 ? "s" : "") \(s.lines.lowerBound + 1)\(s.lines.count > 1 ? "-\(s.lines.upperBound + 1)" : ""):\n```\n\(s.text)\n```\n"
            if let v = app.workspace.review.diffView.visibleWorkLines() { out += "Visible: lines \(v.lowerBound + 1)-\(v.upperBound + 1)\n" }
            return (out, false)
        case .file(let url, _)?:
            let view = app.workspace.files.editorView
            let s = view.selectionLines, v = view.visibleLines
            let path = app.workspace.files.relativePath ?? url.path
            var out = "File: \(path) (editor)\n"
            out += "\(s.selected ? "Selected" : "Caret on") line\(s.lines.count > 1 ? "s" : "") \(s.lines.lowerBound + 1)\(s.lines.count > 1 ? "-\(s.lines.upperBound + 1)" : ""):\n```\n\(view.text(lines: s.lines))\n```\n"
            out += "Visible: lines \(v.lowerBound + 1)-\(v.upperBound + 1)\n"
            return (out, false)
        case .browser?: return ("Vet is showing its browser at \(app.workspace.browser.address).", false)
        case nil: return ("Nothing is open in Vet.", false)
        }
    }

    private static func open(_ app: AppDelegate, _ args: [String: Any]) -> (String, Bool) {
        guard let root = app.workspace.root, let raw = args["path"] as? String else { return ("No project is open in Vet.", true) }
        let path = raw.hasPrefix(root.path + "/") ? String(raw.dropFirst(root.path.count + 1)) : raw
        let line = max(0, (args["line"] as? Int ?? 1) - 1)
        if app.workspace.review.changes.contains(where: { $0.path == path }) {
            app.showDiff(path)
            return ("Showing the diff of \(path).", false)
        }
        app.showFile(root.appendingPathComponent(path), line: line)
        return ("Showing \(path) at line \(line + 1).", false)
    }
}
