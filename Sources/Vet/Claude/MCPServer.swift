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

    struct Tool: @unchecked Sendable { // immutable after creation
        let name: String
        let description: String
        let inputSchema: [String: Any]
        let run: @MainActor ([String: Any]) -> (text: String, isError: Bool)
        init(_ name: String, _ description: String, schema: [String: Any], run: @escaping @MainActor ([String: Any]) -> (text: String, isError: Bool)) {
            self.name = name; self.description = description; inputSchema = schema; self.run = run
        }
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dev.vet.mcp")
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
                "instructions": """
                Vet is the user's code review IDE (macOS). After you finish a feature or a set of changes, call \
                set_review_plan with the changed files in the order the user should read them, a one- or two-line \
                summary per file and notes on the key functions. Use get_selection when the user refers to "this", \
                "here" or "the line I'm on". Use vet_status to see what is changed and already reviewed. When the \
                user wants Vet itself to change (keys, colors, a new behavior or display: "a mod for Vet"), read \
                mod_api_docs and build it with install_mod; Vet loads it at once.
                """,
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
            let out = await MainActor.run { tool.run(args) }
            return Self.result(id, ["content": [["type": "text", "text": out.text]], "isError": out.isError])
        default:
            return Self.error(id, -32601, "Method not found: \(method)")
        }
    }

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
