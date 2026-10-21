import Foundation

/// The MCP tools for working alongside the user: their review notes, Run, pointing at a line,
/// and a look at Vet's browser.
@MainActor
enum WorkTools {
    static func make(_ app: AppDelegate) -> [MCPServer.Tool] {
        let str: [String: Any] = ["type": "string"]
        let int: [String: Any] = ["type": "integer"]
        let none: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]
        return [
            // MARK: Notes
            .init("get_notes", """
                The user's review notes: comments they left under lines while reviewing the diff, like \
                pull-request comments. Each has an id, the file, the line it's on now (1-based), that line's \
                text, and what they wrote. Fix what they ask, then call resolve_notes with the ids you handled.
                """, schema: none) { _ in
                notes(app)
            },
            .init("resolve_notes", "Clear review notes you've handled (they disappear from the diff). Pass the ids from get_notes.",
                  schema: ["type": "object", "required": ["ids"], "properties": ["ids": ["type": "array", "items": str]] as [String: Any]]) { args in
                let ids = args["ids"] as? [String] ?? []
                guard !ids.isEmpty else { return ("Pass the ids of the notes you handled.", true) }
                let n = app.workspace.review.removeNotes(ids)
                return n == 0 ? ("None of those notes exist (already cleared?).", true) : ("Cleared \(n) note\(n == 1 ? "" : "s").", false)
            },

            // MARK: Point at code
            .init("point_at_code", """
                Put a short note from you under a line in a changed file's diff, for the rare line the user \
                must not miss: a security hole, data loss, a subtle behavior change, something you're unsure \
                about. Use it rarely (Vet keeps at most 3 at a time); summaries and routine explanations \
                belong in set_review_plan. The user dismisses it in the diff; remove_pointer takes it back.
                """,
                  schema: ["type": "object", "required": ["path", "line", "text"], "properties": [
                    "path": str, "line": ["type": "integer", "description": "1-based line in the current file."],
                    "text": ["type": "string", "description": "One or two sentences."],
                  ] as [String: Any]]) { args in
                point(app, args)
            },
            .init("remove_pointer", "Take back a note you put with point_at_code.",
                  schema: ["type": "object", "required": ["id"], "properties": ["id": str] as [String: Any]]) { args in
                guard let id = args["id"] as? String, app.workspace.review.claudeNotes.contains(where: { $0.id == id }) else { return ("There's no such pointer (the user may have dismissed it).", true) }
                _ = app.workspace.review.removeNotes([id])
                return ("Removed.", false)
            },

            // MARK: Run
            .init("run_app", """
                Start the user's app with one of Vet's Run configurations (the selected one, or `name`), wait \
                up to `wait_seconds` (default 5, at most 30) and answer with its output so far. Vet shows the \
                output panel. If it's already running, says so; call stop_app first to restart.
                """,
                  schema: ["type": "object", "properties": ["name": str, "wait_seconds": int] as [String: Any]], async: { args in
                await runApp(app, args)
            }),
            .init("stop_app", "Stop the app Vet is running (and everything it started), and answer with the end of its output.",
                  schema: none, async: { _ in
                let run = app.workspace.run
                guard run.isRunning else { return .init(text: "Nothing is running.\n" + runStatus(run, lines: 20)) }
                await run.stopAndWait()
                return .init(text: runStatus(run, lines: 30))
            }),
            .init("run_output", "The Run panel's output: whether the app is running, crashed or exited, and its last lines (`lines`, default 100; `grep` keeps lines containing that text).",
                  schema: ["type": "object", "properties": ["lines": int, "grep": str] as [String: Any]]) { args in
                (runStatus(app.workspace.run, lines: args["lines"] as? Int ?? 100, grep: args["grep"] as? String), false)
            },

            // MARK: Browser
            .init("browser_view", """
                What Vet's browser shows the user right now: the address, the title, a page that failed to \
                load, the console messages and uncaught errors since the page loaded, the page's text, and a \
                screenshot (when the browser is on screen). Look only: to click or test flows, use your own \
                browser tools.
                """,
                  schema: ["type": "object", "properties": [
                    "text": ["type": "boolean", "description": "Include the page's text (default true)."],
                    "screenshot": ["type": "boolean", "description": "Include a screenshot (default true)."],
                  ] as [String: Any]], async: { args in
                await browserView(app, text: args["text"] as? Bool ?? true, screenshot: args["screenshot"] as? Bool ?? true)
            }),
        ]
    }

    private static func notes(_ app: AppDelegate) -> (String, Bool) {
        let list = app.workspace.review.notesForClaude().sorted { ($0.path, $0.line) < ($1.path, $1.line) }
        guard !list.isEmpty else { return ("No review notes.", false) }
        var out = "\(list.count) review note\(list.count == 1 ? "" : "s"):\n"
        for n in list {
            out += "\n[\(n.id)] \(n.path):\(n.line + 1)\(n.left ? " (on the old version, before the change)" : "")\(n.sent ? " (also sent as a chat draft)" : "")\n"
            out += "  > \(n.lineText.trimmingCharacters(in: .whitespaces))\n"
            out += n.text.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n") + "\n"
        }
        return (out, false)
    }

    private static func point(_ app: AppDelegate, _ args: [String: Any]) -> (String, Bool) {
        let review = app.workspace.review
        guard let root = app.workspace.root, let raw = args["path"] as? String, let line = args["line"] as? Int,
              let text = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return ("path, line and text are required, and a project must be open.", true)
        }
        let path = raw.hasPrefix(root.path + "/") ? String(raw.dropFirst(root.path.count + 1)) : raw
        guard review.changes.contains(where: { $0.path == path }) else { return ("\(path) isn't among the changed files: pointers show in diffs only.", true) }
        let open = review.claudeNotes
        guard open.count < 3 else {
            return ("There are already 3 pointers showing (\(open.map { "\($0.path):\($0.line + 1) [\($0.id)]" }.joined(separator: ", "))). Keep them for what matters most: remove one first.", true)
        }
        let lines = (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))?.components(separatedBy: "\n") ?? []
        guard line >= 1, line <= lines.count else { return ("\(path) has \(lines.count) lines.", true) }
        guard let note = review.addClaudeNote(path: path, line: line - 1, lineText: lines[line - 1], text: text) else { return ("No project is open.", true) }
        return ("Pointer \(note.id) is under \(path):\(line).", false)
    }

    private static func runApp(_ app: AppDelegate, _ args: [String: Any]) async -> MCPServer.Reply {
        let run = app.workspace.run
        guard !run.configs.isEmpty else {
            return .init(text: "No Run configurations yet. The user adds one in Run ▸ Edit Configurations… (a name and a command, e.g. npm start).", isError: true)
        }
        if run.isRunning { return .init(text: "Already running ‘\(run.selected?.name ?? "")’. Call stop_app first to restart.\n" + runStatus(run, lines: 30)) }
        if let name = args["name"] as? String {
            guard let config = run.configs.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                return .init(text: "No configuration named “\(name)”. There are: \(run.configs.map(\.name).joined(separator: ", ")).", isError: true)
            }
            run.selectedID = config.id
        }
        run.start()
        run.outputVisible = true
        let wait = min(30, max(0, args["wait_seconds"] as? Int ?? 5))
        for _ in 0..<(wait * 4) where run.isRunning { try? await Task.sleep(for: .milliseconds(250)) }
        return .init(text: runStatus(run, lines: 80))
    }

    private static func runStatus(_ run: RunModel, lines: Int, grep: String? = nil) -> String {
        let name = run.selected.map { "‘\($0.name)’ (\($0.command))" } ?? "nothing selected"
        let state = run.isRunning ? "running" : run.crashed ? "crashed" : run.output.isEmpty ? "not run yet" : "stopped"
        var all = run.output.components(separatedBy: "\n")
        if let grep, !grep.isEmpty { all = all.filter { $0.localizedCaseInsensitiveContains(grep) } }
        let tail = all.suffix(max(1, min(lines, 2000))).joined(separator: "\n")
        return "\(name): \(state).\n\(tail.isEmpty ? "(no output)" : tail)"
    }

    private static func browserView(_ app: AppDelegate, text: Bool, screenshot: Bool) async -> MCPServer.Reply {
        let b = app.workspace.browser
        guard !b.address.isEmpty else { return .init(text: "Vet's browser hasn't opened a page.") }
        var out = "Address: \(b.address)\nTitle: \(b.title.isEmpty ? "(none)" : b.title)\(b.isLoading ? "\n(still loading)" : "")\n"
        if let error = b.loadError { out += "The page didn't open: \(error)\n" }
        let console = b.console.suffix(60)
        out += console.isEmpty ? "Console: (nothing since the page loaded)\n" : "Console (\(b.console.count) since the page loaded, newest last):\n" + console.joined(separator: "\n") + "\n"
        if text, b.loadError == nil, let page = await b.pageText() {
            let trimmed = page.count > 8000 ? String(page.prefix(8000)) + "\n… (\(page.count - 8000) more characters)" : page
            out += "\nPage text:\n" + trimmed
        }
        var png: Data?
        if screenshot {
            png = await b.snapshot()
            if png == nil { out += "\n(No screenshot: the browser isn't on screen in Vet right now.)" }
        }
        return .init(text: out, png: png)
    }
}
