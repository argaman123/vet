import Foundation
import Testing
@testable import VetCore

private let shaA = "f8c0f2ce3ece8b315d1e3644940c391e2153db19"
private let shaB = "d1c781b49d6c426e02054b9b2b63e1a9c2aefbf0"
private let zeros = String(repeating: "0", count: 40)

/// One `--line-porcelain` record, as git 2.54 prints it.
private func record(_ sha: String, _ orig: Int, _ final: Int, group: Int? = nil, author: String, time: Int, tz: String,
                    summary: String, extra: [String] = [], filename: String = "my file.txt", text: String) -> String {
    let header = ["\(sha) \(orig) \(final)" + (group.map { " \($0)" } ?? ""),
                  "author \(author)", "author-mail <a@example.com>", "author-time \(time)", "author-tz \(tz)",
                  "committer \(author)", "committer-mail <a@example.com>", "committer-time 1792305707", "committer-tz +0300",
                  "summary \(summary)"]
    return (header + extra + ["filename \(filename)", "\t\(text)"]).joined(separator: "\n")
}

private func lines(_ records: String...) -> Data { Data((records.joined(separator: "\n") + "\n").utf8) }

@Test func parsesHeaderFieldsOfEachLine() {
    let out = BlamePorcelainParser.parse(lines(
        record(shaA, 1, 1, group: 2, author: "Ada Lovelace", time: 1704144845, tz: "+0530",
               summary: "first: add file", extra: ["boundary"], text: "one"),
        // The second line of a group has no group count, even with --line-porcelain.
        record(shaA, 2, 2, author: "Ada Lovelace", time: 1704144845, tz: "+0530",
               summary: "first: add file", extra: ["boundary"], text: "two"),
        record(shaB, 2, 3, group: 1, author: "Zoë Ünicode", time: 1792306038, tz: "-0800",
               summary: "fix: the third line", extra: ["previous \(shaA) my file.txt"], text: "three")))
    #expect(out == [
        BlameLine(line: 1, commit: shaA, author: "Ada Lovelace", authorTime: Date(timeIntervalSince1970: 1704144845),
                  summary: "first: add file", isUncommitted: false),
        BlameLine(line: 2, commit: shaA, author: "Ada Lovelace", authorTime: Date(timeIntervalSince1970: 1704144845),
                  summary: "first: add file", isUncommitted: false),
        BlameLine(line: 3, commit: shaB, author: "Zoë Ünicode", authorTime: Date(timeIntervalSince1970: 1792306038),
                  summary: "fix: the third line", isUncommitted: false),
    ])
}

@Test func authorTimeIsAbsoluteWhateverTheZone() {
    // The same instant written from two zones is the same Date; author-tz never shifts it.
    let out = BlamePorcelainParser.parse(lines(
        record(shaA, 1, 1, group: 1, author: "East", time: 1704144845, tz: "+1400", summary: "s", text: "a"),
        record(shaB, 1, 2, group: 1, author: "West", time: 1704144845, tz: "-1200", summary: "s", text: "b")))
    #expect(out.map(\.authorTime) == [Date(timeIntervalSince1970: 1704144845), Date(timeIntervalSince1970: 1704144845)])
}

@Test func uncommittedLinesHaveZerosAndOneLabel() {
    let out = BlamePorcelainParser.parse(lines(
        record(zeros, 1, 1, group: 1, author: "External file (--contents)", time: 1792305707, tz: "+0300",
               summary: "Version of my file.txt from standard input", extra: ["previous \(shaA) my file.txt"], text: "zero"),
        record(shaA, 1, 2, group: 1, author: "Ada", time: 1704144845, tz: "+0530", summary: "first", text: "one"),
        record(zeros, 3, 3, group: 1, author: "Not Committed Yet", time: 1792305707, tz: "+0300",
               summary: "Version of my file.txt from my file.txt", text: "TWO")))
    #expect(out.map(\.isUncommitted) == [true, false, true])
    #expect(out.map(\.line) == [1, 2, 3])
    #expect(out[0].commit == zeros && out[2].commit == zeros)
    #expect(out[0].author == BlamePorcelainParser.uncommittedAuthor && out[2].author == BlamePorcelainParser.uncommittedAuthor)
    #expect(out[0].summary == BlamePorcelainParser.uncommittedSummary)
    #expect(out[0].authorTime == Date(timeIntervalSince1970: 1792305707))
}

@Test func filenamesWithSpacesAndQuotesDontBreakRecords() {
    let out = BlamePorcelainParser.parse(lines(
        record(shaA, 1, 1, group: 1, author: "A", time: 1, tz: "+0000", summary: "s",
               extra: ["previous \(shaB) old name with spaces.txt"], filename: "new name with spaces.txt", text: "a"),
        record(shaB, 1, 2, group: 1, author: "B", time: 2, tz: "+0000", summary: "s",
               filename: #""t\"ab\303\251.txt""#, text: "b")))
    #expect(out.map(\.line) == [1, 2])
    #expect(out.map(\.author) == ["A", "B"])
}

@Test func plainPorcelainReusesTheFirstRecordsHeaders() {
    // --porcelain prints a commit's headers once; later lines carry only the sha line.
    let text = """
    \(shaA) 1 1 3
    author Ada
    author-mail <a@example.com>
    author-time 1704144845
    author-tz +0530
    summary first
    boundary
    filename f.txt
    \ta
    \(shaA) 2 2
    \tb
    \(zeros) 3 3 1
    author Not Committed Yet
    author-time 1792305707
    summary Version of f.txt from f.txt
    filename f.txt
    \tc
    \(shaA) 3 4
    \td

    """
    let out = BlamePorcelainParser.parse(Data(text.utf8))
    #expect(out.map(\.line) == [1, 2, 3, 4])
    #expect(out.map(\.author) == ["Ada", "Ada", BlamePorcelainParser.uncommittedAuthor, "Ada"])
    #expect(out[3].summary == "first" && out[3].authorTime == Date(timeIntervalSince1970: 1704144845))
}

@Test func lineTextNeverReadsAsHeaders() {
    // The text after the tab can look like a header, be empty, or not be UTF-8.
    var data = lines(
        record(shaA, 1, 1, group: 3, author: "Ada", time: 1, tz: "+0000", summary: "s", text: "author Mallory"),
        record(shaA, 2, 2, author: "Ada", time: 1, tz: "+0000", summary: "s", text: "\(shaB) 9 9 9"),
        record(shaA, 3, 3, author: "Ada", time: 1, tz: "+0000", summary: "s", text: ""))
    data.append(contentsOf: Array(record(shaB, 1, 4, group: 1, author: "Bo", time: 2, tz: "+0000", summary: "t", text: "").utf8))
    data.append(contentsOf: [0xFF, 0xFE, 0x0D, 0x0A]) // invalid UTF-8 and a CR in the line's text
    let out = BlamePorcelainParser.parse(data)
    #expect(out.map(\.line) == [1, 2, 3, 4])
    #expect(out.map(\.author) == ["Ada", "Ada", "Ada", "Bo"])
}

@Test func untrackedTextIsAllUncommitted() {
    let now = Date(timeIntervalSince1970: 1792305707)
    #expect(BlamePorcelainParser.uncommitted(Data("a\nb\n".utf8), at: now).map(\.line) == [1, 2])
    #expect(BlamePorcelainParser.uncommitted(Data("a\nb".utf8), at: now).count == 2)
    #expect(BlamePorcelainParser.uncommitted(Data(), at: now).isEmpty)
    #expect(BlamePorcelainParser.uncommitted(Data("\n".utf8), at: now).allSatisfy { $0.isUncommitted })
}
