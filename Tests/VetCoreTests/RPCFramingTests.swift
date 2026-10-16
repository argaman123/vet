import Foundation
import Testing
@testable import VetCore

private func frame(_ json: String) -> Data { RPCFraming.encode(Data(json.utf8)) }

@Test func decodesMessagesHoweverTheBytesArrive() throws {
    let a = #"{"jsonrpc":"2.0","id":1,"result":{"name":"héllo ✓"}}"#
    let b = #"{"jsonrpc":"2.0","method":"$/progress","params":{}}"#
    let stream = frame(a) + frame(b)

    // Every split point: header cut mid-line, cut inside "\r\n\r\n", body cut mid-character.
    for cut in 1..<stream.count {
        var decoder = RPCFrameDecoder()
        let first = try decoder.append(stream.prefix(cut))
        let second = try decoder.append(stream.dropFirst(cut))
        #expect((first + second).map { String(decoding: $0, as: UTF8.self) } == [a, b], "cut at \(cut)")
    }

    // Byte by byte, and both messages in one read.
    var decoder = RPCFrameDecoder()
    var bodies: [Data] = []
    for byte in stream { bodies += try decoder.append(Data([byte])) }
    #expect(bodies.count == 2)
    var whole = RPCFrameDecoder()
    #expect(try whole.append(stream).map { String(decoding: $0, as: UTF8.self) } == [a, b])
}

@Test func acceptsOtherHeadersAndRejectsMissingLength() throws {
    var decoder = RPCFrameDecoder()
    let raw = "content-length: 2\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{}"
    #expect(try decoder.append(Data(raw.utf8)) == [Data("{}".utf8)])

    var broken = RPCFrameDecoder()
    #expect(throws: RPCFraming.MalformedHeader.self) { try broken.append(Data("Content-Type: x\r\n\r\n{}".utf8)) }
}

@Test func classifiesMessagesAndMatchesResponses() throws {
    let request = try #require(RPCMessage(json: JSONValue.decode(Data(#"{"jsonrpc":"2.0","id":"7","method":"workspace/configuration","params":{"items":[{},{}]}}"#.utf8))))
    #expect(request == .request(id: .string("7"), method: "workspace/configuration", params: ["items": [[:], [:]]]))
    #expect(LSPProtocol.reply(to: "workspace/configuration", params: ["items": [[:], [:]]], root: URL(fileURLWithPath: "/p")) == .success([nil, nil]))

    let failure = try #require(RPCMessage(json: JSONValue.decode(Data(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"nope"}}"#.utf8))))
    #expect(failure == .response(id: .int(3), result: .failure(RPCError(code: -32601, message: "nope"))))

    var pending = PendingRequests<String>()
    let id = pending.reserve()
    pending.insert("definition", for: id)
    #expect(pending.take(.string(String(id))) == "definition") // echoed back as a string still matches
    #expect(pending.take(.int(id)) == nil) // resolves once
}

@Test func readsLocationsAndLocationLinks() throws {
    let range: JSONValue = ["start": ["line": 1, "character": 2], "end": ["line": 1, "character": 5]]
    let name: JSONValue = ["start": ["line": 3, "character": 4], "end": ["line": 3, "character": 9]]
    let expected = [LSPLocation(uri: "file:///a.ts", range: LSPRange(start: .init(line: 1, character: 2), end: .init(line: 1, character: 5)))]
    #expect(LSPLocation.list(from: ["uri": "file:///a.ts", "range": range]) == expected)
    #expect(LSPLocation.list(from: [["uri": "file:///a.ts", "range": range], ["uri": "file:///a.ts", "range": range]]) == expected)
    #expect(LSPLocation.list(from: nil).isEmpty)
    let link: JSONValue = [["targetUri": "file:///b.kt", "targetRange": range, "targetSelectionRange": name]]
    #expect(LSPLocation.list(from: link).map(\.range.start) == [LSPPosition(line: 3, character: 4)])

    #expect(LSPURI.string(for: URL(fileURLWithPath: "/Users/me/a b/#1.ts")) == "file:///Users/me/a%20b/%231.ts")
    #expect(LSPURI.url(for: "file:///Users/me/a%20b/%231.ts")?.path == "/Users/me/a b/#1.ts")
    #expect(LSPURI.url(for: "jar:///lib.jar!/A.class") == nil)
}
