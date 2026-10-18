import Foundation

public struct FindQuery: Sendable, Equatable, Hashable {
    public var text: String
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var regex: Bool

    public init(text: String, caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.text = text
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
    }
}

/// One line that matched.
public struct FindMatch: Sendable, Equatable, Hashable {
    /// Relative to the searched folder.
    public let path: String
    /// 1-based.
    public let line: Int
    /// The line without its line ending; for a line over 400 UTF-16 units, the 400 around the first match.
    public let preview: String
    /// UTF-16 offsets of every match in `preview`. Empty when git matched a line Swift's regex
    /// engine doesn't (e.g. a case-folding difference), so the line still shows.
    public let ranges: [Range<Int>]
    /// UTF-16 offset in the full line where `preview` starts (0 unless the line was cut).
    public let previewStart: Int

    /// UTF-16 column of the first match in the full line (0-based), for placing the caret.
    public var column: Int { previewStart + (ranges.first?.lowerBound ?? 0) }

    public init(path: String, line: Int, preview: String, ranges: [Range<Int>], previewStart: Int = 0) {
        self.path = path
        self.line = line
        self.preview = preview
        self.ranges = ranges
        self.previewStart = previewStart
    }
}

public enum FindError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case emptyQuery
    case invalidRegex(String)
    case failed(String)

    public var description: String {
        switch self {
        case .emptyQuery: "Nothing to find."
        case .invalidRegex(let why): "Invalid regular expression: \(why)"
        case .failed(let why): "Search failed: \(why)"
        }
    }
    public var errorDescription: String? { description }
}

/// Finds a query's matches in a line, with the semantics `git grep` uses for the same flags:
/// literal or regex, case-insensitive unless asked, and whole words meaning "not preceded or
/// followed by a word character" (like `-w`, but Unicode-aware: `caf` is not a word in `café`).
public struct FindMatcher: @unchecked Sendable { // NSRegularExpression is immutable and thread-safe
    public static let previewLimit = 400
    static let contextBefore = 100

    public let query: FindQuery
    let regex: NSRegularExpression
    /// The same pattern without the word check, to tell "not a whole word" apart from "git and ICU disagree".
    let loose: NSRegularExpression?
    /// The pattern with `^` and `$` matching at line breaks, to rule out a whole file in one pass.
    let wholeText: NSRegularExpression

    public init(_ query: FindQuery) throws(FindError) {
        guard !query.text.isEmpty else { throw .emptyQuery }
        self.query = query
        let body = query.regex ? query.text : NSRegularExpression.escapedPattern(for: query.text)
        let options: NSRegularExpression.Options = query.caseSensitive ? [] : [.caseInsensitive]
        do {
            let plain = try NSRegularExpression(pattern: body, options: options)
            if query.wholeWord {
                regex = try NSRegularExpression(pattern: "(?<!\\w)(?:\(body))(?!\\w)", options: options)
                loose = plain
            } else {
                regex = plain
                loose = nil
            }
            wholeText = try NSRegularExpression(pattern: regex.pattern, options: options.union(.anchorsMatchLines))
        } catch {
            throw .invalidRegex(Self.explain(query.text, error))
        }
    }

    private static func explain(_ pattern: String, _ error: Error) -> String {
        let ns = error as NSError
        // ICU reports only "invalid value"; name the most common causes.
        var opens = 0, escaped = false, inClass = false
        for ch in pattern {
            if escaped { escaped = false; continue }
            switch ch {
            case "\\": escaped = true
            case "[": inClass = true
            case "]": inClass = false
            case "(" where !inClass: opens += 1
            case ")" where !inClass: opens -= 1
            default: break
            }
        }
        if escaped { return "it ends with a lone backslash" }
        if inClass { return "a [ is never closed" }
        if opens > 0 { return "a ( is never closed" }
        if opens < 0 { return "a ) has no matching (" }
        return ns.localizedDescription
    }

    /// UTF-16 ranges of every match in `line` (empty matches only when nothing longer matched).
    public func ranges(in line: String) -> [Range<Int>] {
        let ns = line as NSString
        return ranges(in: ns, within: NSRange(location: 0, length: ns.length))
    }

    /// Matches inside `window`, with lookaround seeing past its edges and `^`/`$` only at the
    /// line's own ends; offsets stay relative to the whole line.
    func ranges(in ns: NSString, within window: NSRange) -> [Range<Int>] {
        var found: [Range<Int>] = [], empty: Range<Int>? = nil
        regex.enumerateMatches(in: ns as String, options: [.withTransparentBounds, .withoutAnchoringBounds], range: window) { result, _, _ in
            guard let r = result?.range, r.location != NSNotFound else { return }
            if r.length == 0 { if empty == nil { empty = r.location..<r.location } } else { found.append(r.location..<(r.location + r.length)) }
        }
        if found.isEmpty, let empty { return [empty] }
        return found
    }

    /// A line `git grep` reported. Nil when it isn't a match in Swift's semantics after all
    /// (git's `-w` treats any non-ASCII byte as a word break; Swift doesn't).
    public func match(path: String, line: Int, text: String) -> FindMatch? {
        let ns = Self.trimmingLineEnd(text) as NSString
        if let m = preview(path: path, line: line, ns) { return m }
        if let loose, loose.firstMatch(in: ns as String, range: NSRange(location: 0, length: ns.length)) != nil { return nil }
        // git and ICU disagree (e.g. case folding): show the line's start, unhighlighted.
        let (start, end) = Self.window(around: 0, ns)
        return FindMatch(path: path, line: line, preview: ns.substring(with: NSRange(location: start, length: end - start)), ranges: [])
    }

    /// Searches a whole file's text line by line (for folders that aren't git repositories).
    /// Lines end at `\n` only, as in git, so line numbers agree.
    public func search(path: String, text: String, limit: Int = .max) -> [FindMatch] {
        let whole = text as NSString
        let length = whole.length
        // Most files don't match at all: one pass over the whole text rules them out.
        guard wholeText.firstMatch(in: text, range: NSRange(location: 0, length: length)) != nil else { return [] }
        var out: [FindMatch] = []
        var number = 0, start = 0
        while start < length {
            number += 1
            let newline = whole.range(of: "\n", options: .literal, range: NSRange(location: start, length: length - start))
            let end = newline.location == NSNotFound ? length : newline.location
            var lineEnd = end
            if lineEnd > start && whole.character(at: lineEnd - 1) == 0x0D { lineEnd -= 1 }
            let line = whole.substring(with: NSRange(location: start, length: lineEnd - start)) as NSString
            if let m = preview(path: path, line: number, line) {
                out.append(m)
                if out.count >= limit { break }
            }
            start = end + 1
        }
        return out
    }

    static func trimmingLineEnd(_ s: String) -> String {
        var s = s
        while let last = s.last, last == "\n" || last == "\r" || last == "\r\n" { s.removeLast() }
        return s
    }

    /// The line's matches, or nil when it has none. A line over `previewLimit` units is cut to
    /// the window around its first match, and only that window is searched (a minified bundle's
    /// one line can be megabytes long).
    func preview(path: String, line: Int, _ ns: NSString) -> FindMatch? {
        let length = ns.length
        if length <= Self.previewLimit {
            let found = ranges(in: ns, within: NSRange(location: 0, length: length))
            return found.isEmpty ? nil : FindMatch(path: path, line: line, preview: ns as String, ranges: found)
        }
        guard let first = regex.firstMatch(in: ns as String, range: NSRange(location: 0, length: length)) else { return nil }
        let (start, end) = Self.window(around: first.range.location, ns)
        let found = ranges(in: ns, within: NSRange(location: start, length: end - start)).compactMap { r -> Range<Int>? in
            let hi = min(r.upperBound, end)
            return r.isEmpty || r.lowerBound < hi ? (r.lowerBound - start)..<(hi - start) : nil
        }
        return FindMatch(path: path, line: line, preview: ns.substring(with: NSRange(location: start, length: end - start)),
                         ranges: found, previewStart: start)
    }

    /// `previewLimit` units of a long line, starting a little before `offset`, never splitting a surrogate pair.
    static func window(around offset: Int, _ ns: NSString) -> (Int, Int) {
        let length = ns.length
        guard length > previewLimit else { return (0, length) }
        var start = max(0, min(offset - contextBefore, length - previewLimit))
        var end = min(length, start + previewLimit)
        if start > 0 && UTF16.isTrailSurrogate(ns.character(at: start)) { start += 1 }
        if end < length && UTF16.isTrailSurrogate(ns.character(at: end)) { end -= 1 }
        return (start, end)
    }
}

/// Parses `git grep -n -z` output, where each record is `path\0line\0text\n`.
public enum GrepOutputParser {
    /// One record without its trailing newline. Nil for malformed records, an invalid query,
    /// or a line that isn't a match in Swift's semantics.
    public static func parse(_ line: String, query: FindQuery) -> FindMatch? {
        guard let matcher = try? FindMatcher(query) else { return nil }
        return parse(line, matcher: matcher)
    }

    public static func parse(_ line: String, matcher: FindMatcher) -> FindMatch? {
        let parts = line.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, let number = Int(parts[1]), number > 0 else { return nil }
        return matcher.match(path: String(parts[0]), line: number, text: String(parts[2]))
    }

    /// Splits a byte stream into records as chunks arrive. A path may contain newlines (it ends
    /// at the first NUL), and a chunk may end anywhere, even inside a UTF-8 sequence.
    public struct RecordSplitter: Sendable {
        public struct Record: Sendable, Equatable {
            public let path: String
            public let line: Int
            public let text: String
        }

        /// The unfinished record (it always starts at 0).
        private var buffer: [UInt8] = []
        /// Where its path and line number end, once seen, and where to look next: a megabyte line
        /// arriving in 16 KB pieces is scanned once, not once per piece.
        private var pathEnd: Int?
        private var lineEnd: Int?
        private var scanFrom = 0

        public init() {}

        public mutating func append(_ chunk: some Sequence<UInt8>) -> [Record] {
            buffer.append(contentsOf: chunk)
            var records: [Record] = []
            var start = 0
            while true {
                if pathEnd == nil {
                    guard let i = buffer[scanFrom...].firstIndex(of: 0) else { scanFrom = buffer.count; break }
                    pathEnd = i
                    scanFrom = i + 1
                }
                if lineEnd == nil {
                    guard let i = buffer[scanFrom...].firstIndex(of: 0) else { scanFrom = buffer.count; break }
                    lineEnd = i
                    scanFrom = i + 1
                }
                guard let textEnd = buffer[scanFrom...].firstIndex(of: 0x0A) else { scanFrom = buffer.count; break }
                if let record = Self.record(buffer[start..<pathEnd!], buffer[(pathEnd! + 1)..<lineEnd!], buffer[(lineEnd! + 1)..<textEnd]) {
                    records.append(record)
                }
                start = textEnd + 1
                scanFrom = start
                pathEnd = nil
                lineEnd = nil
            }
            if start > 0 {
                buffer.removeFirst(start)
                scanFrom -= start
                pathEnd = pathEnd.map { $0 - start }
                lineEnd = lineEnd.map { $0 - start }
            }
            return records
        }

        /// The last record when the stream ended without a final newline.
        public mutating func finish() -> [Record] {
            defer { buffer = []; pathEnd = nil; lineEnd = nil; scanFrom = 0 }
            guard let pathEnd = buffer.firstIndex(of: 0), let lineEnd = buffer[(pathEnd + 1)...].firstIndex(of: 0),
                  let record = Self.record(buffer[..<pathEnd], buffer[(pathEnd + 1)..<lineEnd], buffer[(lineEnd + 1)...]) else { return [] }
            return [record]
        }

        private static func record(_ path: ArraySlice<UInt8>, _ line: ArraySlice<UInt8>, _ text: ArraySlice<UInt8>) -> Record? {
            guard !path.isEmpty, !line.isEmpty, line.count < 12 else { return nil }
            var number = 0
            for b in line {
                guard (0x30...0x39).contains(b) else { return nil }
                number = number * 10 + Int(b - 0x30)
            }
            return Record(path: String(decoding: path, as: UTF8.self), line: number, text: String(decoding: text, as: UTF8.self))
        }
    }
}
