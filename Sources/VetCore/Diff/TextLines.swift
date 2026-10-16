import Foundation

/// One line of a file and its own terminator ("\n", "\r\n", or "" for a last line with no newline).
public struct Line: Sendable, Hashable {
    public let text: Substring
    public let terminator: String
    /// What diffs compare: the exact bytes of the text plus its terminator. Bytes, not Swift
    /// string equality, which treats composed and decomposed "é" as equal and would hide a real
    /// change. Including the terminator makes a missing final newline or a line-ending change
    /// count as a change (as git does).
    var key: [UInt8] { Array(text.utf8) + Array(terminator.utf8) }
}

/// A file split into lines, keeping every line's own terminator so `joined()` is byte-exact.
public struct TextLines: Sendable {
    public let lines: [Line]

    public init(lines: [Line]) { self.lines = lines }

    public init(_ data: Data) {
        // Split on newline bytes, not Characters: a combining mark right after "\n" would
        // otherwise glue two lines into one grapheme.
        let s = String(decoding: data, as: UTF8.self)
        let u = s.utf8
        var lines: [Line] = []
        var start = u.startIndex
        var i = u.startIndex
        while i < u.endIndex {
            if u[i] == 0x0A {
                var textEnd = i
                if textEnd > start, u[u.index(before: textEnd)] == 0x0D { textEnd = u.index(before: textEnd) }
                lines.append(Line(text: s[start..<textEnd], terminator: textEnd == i ? "\n" : "\r\n"))
                start = u.index(after: i)
            }
            i = u.index(after: i)
        }
        if start < u.endIndex { lines.append(Line(text: s[start..<u.endIndex], terminator: "")) }
        self.lines = lines
    }

    public init(_ string: String) { self.init(Data(string.utf8)) }

    public var count: Int { lines.count }

    public func joined() -> Data { Data(joinedString().utf8) }

    public func joinedString() -> String { lines.map { String($0.text) + $0.terminator }.joined() }

    public subscript(range: Range<Int>) -> ArraySlice<Line> { lines[range] }
}
