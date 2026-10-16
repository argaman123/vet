import Foundation

/// A draft for the Claude chat: put into the message box, never sent.
public struct Draft: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public init(id: String = UUID().uuidString, text: String) { self.id = id; self.text = text }
}

public struct SessionInfo: Codable, Equatable, Sendable {
    public let sessionId: String
    public let cwd: String
}

/// Minimal HTTP/1.1 for the bridge socket.
public struct HTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let body: Data

    /// Parses a complete request (headers plus Content-Length bytes of body); nil while incomplete.
    public static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var length = 0
        for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
            length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let target = String(parts[1])
        let pathPart = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        var query: [String: String] = [:]
        if let q = target.split(separator: "?", maxSplits: 1).dropFirst().first {
            for pair in q.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if kv.count == 2 { query[kv[0]] = kv[1] }
            }
        }
        return HTTPRequest(method: String(parts[0]), path: pathPart, query: query, body: data[bodyStart..<(bodyStart + length)])
    }

    public static func response(status: Int, json: Data? = nil) -> Data {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 404: "Not Found"][status] ?? "OK"
        let body = json ?? Data()
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        if json != nil { head += "Content-Type: application/json\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}

/// The bridge's state: which Claude sessions are connected, which one you last typed into
/// (taken as the one you're looking at), and drafts waiting for it.
public final class BridgeRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: (cwd: String, seen: Date, active: Date?)] = [:]
    private var drafts: [Draft] = []
    public var onTurnComplete: (@Sendable (String) -> Void)?
    public var onSessionsChanged: (@Sendable () -> Void)?

    public init() {}

    /// The session that should get drafts: last one you typed into, else the newest.
    public func showingSession() -> SessionInfo? {
        lock.lock(); defer { lock.unlock() }
        let live = sessions.filter { Date().timeIntervalSince($0.value.seen) < 10 }
        let pick = live.max { ($0.value.active ?? .distantPast, $0.value.seen) < ($1.value.active ?? .distantPast, $1.value.seen) }
        return pick.map { SessionInfo(sessionId: $0.key, cwd: $0.value.cwd) }
    }

    public var connected: Bool { showingSession() != nil }

    public func enqueue(_ text: String) {
        lock.lock(); drafts.append(Draft(text: text)); lock.unlock()
    }

    public func handle(_ req: HTTPRequest, now: Date = Date()) -> (Int, Data?) {
        func info() -> SessionInfo? { try? JSONDecoder().decode(SessionInfo.self, from: req.body) }
        switch (req.method, req.path) {
        case ("POST", "/hello"), ("POST", "/active"), ("POST", "/turn-complete"):
            guard let s = info() else { return (400, nil) }
            lock.lock()
            let old = sessions[s.sessionId]
            sessions[s.sessionId] = (s.cwd, now, req.path == "/active" ? now : old?.active)
            lock.unlock()
            if req.path == "/turn-complete" { onTurnComplete?(s.cwd) }
            if old == nil || req.path == "/active" { onSessionsChanged?() }
            return (200, Data("{}".utf8))
        case ("GET", "/next"):
            guard let id = req.query["session"] else { return (400, nil) }
            lock.lock()
            if let cwd = sessions[id]?.cwd { sessions[id] = (cwd, now, sessions[id]?.active) } // polling keeps it alive
            lock.unlock()
            guard showingSession()?.sessionId == id else { return (204, nil) }
            lock.lock(); defer { lock.unlock() }
            guard let d = drafts.first else { return (204, nil) }
            return (200, try? JSONEncoder().encode(d))
        case ("POST", "/ack"):
            guard let d = try? JSONDecoder().decode([String: String].self, from: req.body), let id = d["id"] else { return (400, nil) }
            lock.lock(); drafts.removeAll { $0.id == id }; lock.unlock()
            return (200, Data("{}".utf8))
        default:
            return (404, nil)
        }
    }
}
