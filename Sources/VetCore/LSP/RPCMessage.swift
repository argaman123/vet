import Foundation

/// A JSON-RPC 2.0 request id. Vet sends integers; servers may use either.
public enum RPCID: Sendable, Hashable, CustomStringConvertible {
    case int(Int)
    case string(String)

    init?(_ json: JSONValue?) {
        switch json {
        case .string(let s)?: self = .string(s)
        case let value? where value.int != nil: self = .int(value.int!)
        default: return nil
        }
    }

    public var json: JSONValue {
        switch self {
        case .int(let i): .int(i)
        case .string(let s): .string(s)
        }
    }

    public var description: String {
        switch self {
        case .int(let i): String(i)
        case .string(let s): s
        }
    }
}

public struct RPCError: Error, Sendable, Hashable, CustomStringConvertible {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static let methodNotFound = -32601
    public static let requestCancelled = -32800

    public var description: String { "JSON-RPC error \(code): \(message)" }

    var json: JSONValue {
        var o: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        if let data { o["data"] = data }
        return .object(o)
    }
}

/// One JSON-RPC message, in either direction.
public enum RPCMessage: Sendable, Hashable {
    case request(id: RPCID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: RPCID, result: Result<JSONValue, RPCError>)

    /// Classifies a decoded message; nil when it is none of the three shapes.
    public init?(json: JSONValue) {
        guard case .object(let o) = json else { return nil }
        if case .string(let method)? = o["method"] {
            if let id = RPCID(o["id"]) {
                self = .request(id: id, method: method, params: o["params"])
            } else {
                self = .notification(method: method, params: o["params"])
            }
        } else if let id = RPCID(o["id"]) {
            if let error = o["error"]?.object {
                self = .response(id: id, result: .failure(RPCError(
                    code: error["code"]?.int ?? 0, message: error["message"]?.string ?? "", data: error["data"])))
            } else {
                self = .response(id: id, result: .success(o["result"] ?? .null))
            }
        } else {
            return nil
        }
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["jsonrpc": "2.0"]
        switch self {
        case .request(let id, let method, let params):
            o["id"] = id.json
            o["method"] = .string(method)
            if let params { o["params"] = params }
        case .notification(let method, let params):
            o["method"] = .string(method)
            if let params { o["params"] = params }
        case .response(let id, let result):
            o["id"] = id.json
            switch result {
            case .success(let value): o["result"] = value
            case .failure(let error): o["error"] = error.json
            }
        }
        return .object(o)
    }

    /// The framed bytes to write to a server's stdin.
    public func framed() throws -> Data {
        RPCFraming.encode(try json.encoded())
    }
}

/// Matches responses to the requests that are waiting for them.
public struct PendingRequests<Waiter> {
    private var waiters: [Int: Waiter] = [:]
    private var nextID = 1

    public init() {}

    /// A fresh id for a request about to be sent.
    public mutating func reserve() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    public mutating func insert(_ waiter: Waiter, for id: Int) {
        waiters[id] = waiter
    }

    /// The waiter for a response's id, removed so it resolves once. A server that echoes the id
    /// back as a string still matches.
    public mutating func take(_ id: RPCID) -> Waiter? {
        switch id {
        case .int(let i): waiters.removeValue(forKey: i)
        case .string(let s): Int(s).flatMap { waiters.removeValue(forKey: $0) }
        }
    }

    public mutating func take(_ id: Int) -> Waiter? { waiters.removeValue(forKey: id) }

    /// Every waiter, for failing them all when the server goes away.
    public mutating func takeAll() -> [Waiter] {
        defer { waiters.removeAll() }
        return Array(waiters.values)
    }

    public var isEmpty: Bool { waiters.isEmpty }
}
