import Foundation

/// Who last changed one line, from `git blame`.
public struct BlameLine: Sendable, Equatable {
    /// 1-based line number in the blamed text.
    public let line: Int
    /// Full commit sha; all zeros when the line isn't committed yet.
    public let commit: String
    public let author: String
    public let authorTime: Date
    /// The commit's subject line.
    public let summary: String
    public let isUncommitted: Bool

    public init(line: Int, commit: String, author: String, authorTime: Date, summary: String, isUncommitted: Bool) {
        self.line = line
        self.commit = commit
        self.author = author
        self.authorTime = authorTime
        self.summary = summary
        self.isUncommitted = isUncommitted
    }
}

/// Parses `git blame --line-porcelain` output (plain `--porcelain` too, where a commit's
/// headers appear only the first time it shows up).
public enum BlamePorcelainParser {
    public static let uncommittedSHA = String(repeating: "0", count: 40)
    /// Git calls uncommitted lines "Not Committed Yet", or "External file (--contents)" when the
    /// text came from `--contents`; both read as this, as in VS Code.
    public static let uncommittedAuthor = "Not Committed Yet"
    public static let uncommittedSummary = "Uncommitted changes"

    public static func parse(_ data: Data) -> [BlameLine] {
        struct Commit { var author = "", time = Date(timeIntervalSince1970: 0), summary = "" }
        var commits: [String: Commit] = [:] // one copy of each commit's strings, shared by its lines
        var result: [BlameLine] = []
        var sha: String?
        var finalLine = 0
        var pending = Commit()

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            while start < bytes.count {
                var end = start
                while end < bytes.count && bytes[end] != 0x0A { end += 1 }
                let line = UnsafeBufferPointer(rebasing: bytes[start..<end])
                start = end + 1
                guard let first = line.first else { continue }
                if first == 0x09 { // "\t<text>" ends the record for one line
                    guard let current = sha else { continue }
                    let info: Commit
                    if let known = commits[current] { info = known } else { info = pending; commits[current] = pending }
                    let uncommitted = current == uncommittedSHA
                    result.append(BlameLine(line: finalLine, commit: current,
                                            author: uncommitted ? uncommittedAuthor : info.author, authorTime: info.time,
                                            summary: uncommitted ? uncommittedSummary : info.summary, isUncommitted: uncommitted))
                    sha = nil
                } else if let header = parseHeader(line) {
                    // "<sha> <orig line> <final line>[ <lines in group>]"
                    sha = header.sha
                    finalLine = header.finalLine
                    pending = commits[header.sha] ?? Commit()
                } else if sha != nil {
                    if let v = value(line, key: "author ") { pending.author = v }
                    else if let v = value(line, key: "author-time ") {
                        pending.time = Date(timeIntervalSince1970: TimeInterval(Int64(v) ?? 0))
                    } else if let v = value(line, key: "summary ") { pending.summary = v }
                    // author-tz only says where the author was: the epoch time is already absolute.
                    // Other keys (author-mail, committer-*, boundary, previous, filename) aren't needed.
                }
            }
        }
        return result
    }

    /// Every line of an untracked or unborn file, which git can't blame: all uncommitted.
    public static func uncommitted(_ text: Data, at time: Date) -> [BlameLine] {
        let count = text.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } + (text.last.map { $0 == 0x0A ? 0 : 1 } ?? 0)
        return (0..<count).map {
            BlameLine(line: $0 + 1, commit: uncommittedSHA, author: uncommittedAuthor, authorTime: time,
                      summary: uncommittedSummary, isUncommitted: true)
        }
    }

    private static func parseHeader(_ line: UnsafeBufferPointer<UInt8>) -> (sha: String, finalLine: Int)? {
        guard line.count > 41, line[40] == 0x20, line[..<40].allSatisfy(isHex) else { return nil }
        let fields = line[41...].split(separator: 0x20)
        guard fields.count >= 2, let final = Int(String(decoding: fields[1], as: UTF8.self)) else { return nil }
        return (String(decoding: line[..<40], as: UTF8.self), final)
    }

    private static func isHex(_ b: UInt8) -> Bool { (0x30...0x39).contains(b) || (0x61...0x66).contains(b) }

    private static func value(_ line: UnsafeBufferPointer<UInt8>, key: StaticString) -> String? {
        let k = UnsafeBufferPointer(start: key.utf8Start, count: key.utf8CodeUnitCount)
        guard line.count >= k.count, line[..<k.count].elementsEqual(k) else { return nil }
        return String(decoding: line[k.count...], as: UTF8.self)
    }
}
