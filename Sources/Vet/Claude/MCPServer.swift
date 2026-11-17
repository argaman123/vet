import Foundation
import Network

/// A tiny MCP server (Streamable HTTP, JSON responses) on 127.0.0.1, running while Vet is open,
/// so Claude Code can talk to the IDE you're reviewing in. Connect once with:
///   claude mcp add --transport http --scope user vet http://127.0.0.1:47821/mcp
/// Only this Mac can reach it (loopback only); requests from web pages are refused.
final class MCPServer: @unchecked Sendable {
    /// 47821, or VET_MCP_PORT (test runs use another port so they never answer for your Vet).
    static let port: UInt16 = UInt16(ProcessInfo.processInfo.environment["VET_MCP_PORT"] ?? "") ?? 47821
    static var url: String { "http://127.0.0.1:\(port)/mcp" }

    /// What a tool answers: text, and optionally a PNG (a screenshot).
    struct Reply: Sendable {
        var text: String
        var isError = false
        var png: Data?
    }

    struct Tool: @unchecked Sendable { // immutable after creation
        let name: String
        let description: String
        let inputSchema: [String: Any]
        let run: @MainActor ([String: Any]) async -> Reply
        init(_ name: String, _ description: String, schema: [String: Any], run: @escaping @MainActor ([String: Any]) -> (text: String, isError: Bool)) {
            self.name = name; self.description = description; inputSchema = schema
            self.run = { args in let r = run(args); return Reply(text: r.text, isError: r.isError) }
        }
        /// A tool that waits for something (a page's text, a screenshot, a few seconds of output).
        init(_ name: String, _ description: String, schema: [String: Any], async run: @escaping @MainActor ([String: Any]) async -> Reply) {
            self.name = name; self.description = description; inputSchema = schema; self.run = run
        }
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dev.vet.mcp")
    /// Claude chats waiting for the user's notes (`GET /vet/wait?root=…`, held open by a command
    /// Claude runs in the background), oldest first. Answering one ends that command, and Claude
    /// takes a turn: this is how Vet reaches a chat without the user typing there.
    private var waiters: [(id: UUID, root: String, c: NWConnection)] = []
    private let waitersLock = NSLock() // connection callbacks run on `queue`, wake on the main actor
    /// The projects a chat is waiting on, whenever that changes (on the main actor).
    var onWaitersChanged: (@MainActor @Sendable ([String]) -> Void)?
    /// A chat started waiting on `root`: if notes were already sent, the message to wake it with.
    var pendingMessage: (@MainActor @Sendable (String) -> String?)?
    /// Text added to a tool's reply (by tool name): how to listen, while no chat is listening.
    /// Chats read Vet's instructions only when they start, but every reply when it comes.
    var appendix: (@MainActor @Sendable (String) -> String?)?
    private let tools: [Tool]
    private(set) var running = false

    init(tools: [Tool]) { self.tools = tools }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.running = true }
            if case .failed = state { self?.running = false }
        }
        l.start(queue: queue)
        listener = l
    }

    func stop() { listener?.cancel(); listener = nil; running = false }

    // MARK: HTTP

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, buffer: Data())
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let request = HTTPRequest(buf) {
                Task { await self.respond(c, request) }
            } else if done || error != nil || buf.count > 8 << 20 {
                c.cancel()
            } else {
                self.read(c, buffer: buf)
            }
        }
    }

    private func respond(_ c: NWConnection, _ r: HTTPRequest) async {
        // Browsers send an Origin; MCP clients don't. Refuse cross-site requests (DNS rebinding).
        if let origin = r.headers["origin"], !origin.hasPrefix("http://127.0.0.1"), !origin.hasPrefix("http://localhost") {
            send(c, status: "403 Forbidden", body: Data())
            return
        }
        if r.path.hasPrefix("/vet/wait"), r.method == "GET" { await addWaiter(c, root: Self.query(r.path)["root"] ?? ""); return }
        guard r.path.hasPrefix("/mcp") else { send(c, status: "404 Not Found", body: Data()); return }
        guard r.method == "POST" else { send(c, status: "405 Method Not Allowed", body: Data(), extra: ["Allow: POST"]); return }
        guard let json = try? JSONSerialization.jsonObject(with: r.body) else {
            send(c, status: "400 Bad Request", body: Self.encode(Self.error(nil, -32700, "Parse error")))
            return
        }
        if let batch = json as? [[String: Any]] {
            var out: [[String: Any]] = []
            for m in batch { if let reply = await handle(m) { out.append(reply) } }
            out.isEmpty ? send(c, status: "202 Accepted", body: Data()) : send(c, status: "200 OK", body: Self.encode(out), json: true)
        } else if let m = json as? [String: Any] {
            if let reply = await handle(m) { send(c, status: "200 OK", body: Self.encode(reply), json: true) }
            else { send(c, status: "202 Accepted", body: Data()) }
        } else {
            send(c, status: "400 Bad Request", body: Self.encode(Self.error(nil, -32600, "Invalid request")))
        }
    }

    private func send(_ c: NWConnection, status: String, body: Data, json: Bool = false, extra: [String] = []) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if json { head += "Content-Type: application/json\r\n" }
        for h in extra { head += h + "\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: Waiting chats

    /// One path for a folder however it's spelled (symlinks like /tmp, a trailing slash).
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func addWaiter(_ c: NWConnection, root: String) async {
        let root = Self.canonical(root), id = UUID()
        waitersLock.withLock { waiters.append((id, root, c)) }
        // The command was stopped (or the chat closed): forget it.
        c.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, done, error in
            if done || error != nil { self?.removeWaiter(id) }
        }
        c.stateUpdateHandler = { [weak self] state in
            switch state { case .failed, .cancelled: self?.removeWaiter(id); default: break }
        }
        publishWaiters()
        if let message = await pendingMessage?(root) { _ = wake(root: root, message: message) }
    }

    private func removeWaiter(_ id: UUID) {
        let removed = waitersLock.withLock { () -> Bool in
            guard let i = waiters.firstIndex(where: { $0.id == id }) else { return false }
            waiters.remove(at: i)
            return true
        }
        if removed { publishWaiters() }
    }

    private func publishWaiters() {
        let roots = waitersLock.withLock { waiters.map(\.root) }
        Task { @MainActor in self.onWaitersChanged?(roots) }
    }

    /// Wakes the chat that started waiting on `root` most recently (one chat handles the notes);
    /// false when none is waiting.
    @discardableResult
    func wake(root: String, message: String) -> Bool {
        let root = Self.canonical(root)
        let picked = waitersLock.withLock { () -> NWConnection? in
            guard let i = waiters.lastIndex(where: { $0.root == root }) else { return nil }
            return waiters.remove(at: i).c
        }
        guard let c = picked else { return false }
        c.stateUpdateHandler = nil
        send(c, status: "200 OK", body: Data((message + "\n").utf8), extra: ["Content-Type: text/plain; charset=utf-8"])
        publishWaiters()
        return true
    }

    private static func query(_ path: String) -> [String: String] {
        guard let q = URLComponents(string: "http://x" + path)?.queryItems else { return [:] }
        return Dictionary(q.compactMap { i in i.value.map { (i.name, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: JSON-RPC

    private func handle(_ m: [String: Any]) async -> [String: Any]? {
        let id = m["id"]
        guard let method = m["method"] as? String else { return id == nil ? nil : Self.error(id, -32600, "Invalid request") }
        if id == nil { return nil } // a notification (e.g. notifications/initialized)
        let params = m["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let version = params["protocolVersion"] as? String ?? "2025-06-18"
            return Self.result(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "vet", "title": "Vet", "version": "2.0"],
                "instructions": Self.instructions,
            ])
        case "ping":
            return Self.result(id, [:])
        case "tools/list":
            return Self.result(id, ["tools": tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema] }])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else {
                return Self.error(id, -32602, "Unknown tool")
            }
            nonisolated(unsafe) let args = params["arguments"] as? [String: Any] ?? [:]
            let out = await Self.call(tool, args)
            var text = out.text
            if let extra = await appendix?(name) { text += "\n\n" + extra }
            var content: [[String: Any]] = [["type": "text", "text": text]]
            if let png = out.png { content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]) }
            return Self.result(id, ["content": content, "isError": out.isError])
        default:
            return Self.error(id, -32601, "Method not found: \(method)")
        }
    }

    /// What every agent session learns about Vet when it connects (the MCP limit is 4,096
    /// characters): so Claude uses Vet's review order, notes and listener without being asked.
    static var instructions: String { """
        Vet is the user's code review IDE on this Mac. They read your changes in Vet, not in this chat, \
        and want to stay in Vet while reviewing. Use it without being asked:

        1. Review order. Whenever you finish a change (a feature, a fix, a set of edits), call \
        set_review_plan: `overview` is a one- or two-sentence summary of the whole change; `files` lists \
        the changed files in the order to read them. Each file's `summary` is a short overview of that \
        file only (one or two lines). Put everything specific in that file's `notes`, each with the \
        `line` (or `symbol`) it's about: why a function changed, what to check, a tricky bit. Vet shows \
        each note beside its change and opens it when the user arrives there. Do this before \
        committing, and again when the change grows.

        2. Notes. The user leaves review notes on lines in Vet and sends them to you from there. Handle \
        them with get_notes (fix the code, or answer a question), then answer each one in \
        resolve_notes `replies`: that's where the user reads your answer, beside the line. Don't answer \
        in the review order's summaries instead. Ask in this chat only when you can't decide something \
        yourself.

        3. Listening. Notes reach you without the user typing here because you keep one listener \
        running in the background in this chat, whenever you work in a project that's open in Vet \
        (vet_status shows it). Start it on your own, without being asked, as a background shell command \
        (in Claude Code: the Bash tool with run_in_background: true):
        \(listenCommand(root: "<the project's root folder>"))
        When a background command ends you get a new turn automatically, even while the chat is \
        idle (if your client can't do that, call get_notes whenever the user asks you to check Vet). \
        It ends when the user sends notes, and its output says what to do; after \
        handling them, start it again. One per chat: not if one is already running; not again if it \
        ended because Vet isn't running (curl fails to connect).

        4. Pointers. point_at_code puts a note from you under a line the user must not miss (a security \
        hole, data loss, a subtle behavior change). Rarely; summaries belong in the review order.

        5. Context. get_selection is what the user is looking at ("this", "here", "this line"). \
        vet_status lists the changes and what's reviewed. run_app, run_output and browser_view show their \
        app as they see it in Vet. When the user wants Vet itself to change (keys, colors, a new behavior \
        or display: "a mod for Vet"), read mod_api_docs and build it with install_mod.
        """
    }

    /// The command a chat runs (in the background) to wait for the user's notes on `root`.
    static func listenCommand(root: String) -> String {
        "curl -s --get --data-urlencode \"root=\(root)\" http://127.0.0.1:\(port)/vet/wait"
    }

    /// Added to replies while no chat listens on the project.
    static func listenHint(root: String) -> String {
        """
        Vet: no chat is listening for the user's notes. Start the listener now, without asking (a background \
        shell command): \(listenCommand(root: root))
        When it ends you get a turn automatically, even while idle; its output says what to do. Then \
        start it again. Skip this if you already have one running in this chat.
        """
    }

    @MainActor private static func call(_ tool: Tool, _ args: [String: Any]) async -> Reply { await tool.run(args) }

    private static func result(_ id: Any?, _ r: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": r] }
    private static func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
    private static func encode(_ o: Any) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data() }
}

/// One HTTP/1.1 request, once its headers and body have all arrived.
private struct HTTPRequest {
    let method: String, path: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = head.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        method = String(first[0]); path = String(first[1])
        var h: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            h[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        headers = h
        let length = Int(h["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        body = data[bodyStart..<(bodyStart + length)]
    }
}
