import Foundation

/// One line of a file and its own terminator ("\n", "\r\n", or "" for a last line with no newline).
public struct Line: Sendable, Hashable {
    public let text: Substring
    public let terminator: String
    /// What diffs compare: the text plus its terminator, so a missing final newline or a
    /// line-ending change counts as a change (as git does).
    var key: String { String(text) + terminator }
}

/// A file split into lines, keeping every line's own terminator so `joined()` is byte-exact.
public struct TextLines: Sendable {
    public let lines: [Line]

    public init(lines: [Line]) { self.lines = lines }

    public init(_ data: Data) {
        let s = String(decoding: data, as: UTF8.self)
        var lines: [Line] = []
        var start = s.startIndex
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            if c == "\n" || c == "\r\n" {
                lines.append(Line(text: s[start..<i], terminator: c == "\n" ? "\n" : "\r\n"))
                start = next
            }
            i = next
        }
        if start < s.endIndex { lines.append(Line(text: s[start...], terminator: "")) }
        self.lines = lines
    }

    public init(_ string: String) { self.init(Data(string.utf8)) }

    public var count: Int { lines.count }

    public func joined() -> Data { Data(joinedString().utf8) }

    public func joinedString() -> String { lines.map { String($0.text) + $0.terminator }.joined() }

    public subscript(range: Range<Int>) -> ArraySlice<Line> { lines[range] }
}
