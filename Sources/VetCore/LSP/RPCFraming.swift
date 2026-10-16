import Foundation

/// The LSP base protocol: each JSON-RPC message is `Content-Length: N\r\n\r\n` (other headers
/// allowed) followed by N bytes of UTF-8 JSON.
public enum RPCFraming {
    public static func encode(_ body: Data) -> Data {
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        return out
    }

    public struct MalformedHeader: Error, CustomStringConvertible {
        public let header: String
        public var description: String { "malformed JSON-RPC header: \(header.debugDescription)" }
    }
}

/// Splits a byte stream into message bodies, however the bytes arrive: a header split across
/// reads, several messages in one read, or a body spread over many.
public struct RPCFrameDecoder: Sendable {
    private var buffer: [UInt8] = []
    private var start = 0 // consumed prefix of `buffer`, dropped lazily
    private var pendingLength: Int? // body length once the current header is parsed

    public init() {}

    /// Appends `data` and returns every message body it completes, in order.
    /// Throws on a header without a usable Content-Length; the stream can't be resynchronized then.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(contentsOf: data)
        var bodies: [Data] = []
        while true {
            if pendingLength == nil {
                guard let end = headerEnd() else { break }
                let header = String(decoding: buffer[start..<end], as: UTF8.self)
                pendingLength = try Self.contentLength(in: header)
                start = end + 4
            }
            guard let length = pendingLength, buffer.count - start >= length else { break }
            bodies.append(Data(buffer[start..<start + length]))
            start += length
            pendingLength = nil
        }
        // Compact once the consumed prefix dominates, so appends stay amortized O(n).
        if start > 0 && start * 2 >= buffer.count {
            buffer.removeFirst(start)
            start = 0
        }
        return bodies
    }

    /// Index of the `\r\n\r\n` ending the header that starts at `start`.
    private func headerEnd() -> Int? {
        var i = start
        while i + 3 < buffer.count {
            if buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10 { return i }
            i += 1
        }
        return nil
    }

    private static func contentLength(in header: String) throws -> Int {
        for line in header.split(separator: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            if name.caseInsensitiveCompare("Content-Length") == .orderedSame,
               let n = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)), n >= 0 {
                return n
            }
        }
        throw RPCFraming.MalformedHeader(header: header)
    }
}
