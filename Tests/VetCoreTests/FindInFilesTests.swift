import Testing
@testable import VetCore

private func parse(_ record: String, _ query: FindQuery) -> FindMatch? {
    GrepOutputParser.parse(record, query: query)
}

@Test func grepRecordWithEveryMatch() {
    let m = parse("src/a.ts\u{0}12\u{0}  const foo = foo + 1", FindQuery(text: "foo"))
    #expect(m == FindMatch(path: "src/a.ts", line: 12, preview: "  const foo = foo + 1", ranges: [8..<11, 14..<17]))
    #expect(m?.column == 8)
}

@Test func grepRecordCRLFAndNUL() {
    #expect(parse("a.txt\u{0}1\u{0}hello world\r", FindQuery(text: "world"))?.preview == "hello world")
    #expect(parse("a.txt\u{0}1\u{0}hello world\r\n", FindQuery(text: "world"))?.ranges == [6..<11])
    // A NUL inside the text belongs to the text.
    #expect(parse("a.txt\u{0}3\u{0}x\u{0}y foo", FindQuery(text: "foo"))?.ranges == [4..<7])
}

@Test func grepRecordMalformed() {
    #expect(parse("no separators", FindQuery(text: "no")) == nil)
    #expect(parse("a\u{0}x\u{0}text", FindQuery(text: "text")) == nil)
    #expect(parse("\u{0}1\u{0}text", FindQuery(text: "text")) == nil)
    #expect(parse("a\u{0}1\u{0}text", FindQuery(text: "")) == nil)
}

@Test func caseFolding() throws {
    let line = "Foo FOO foo"
    #expect(try FindMatcher(FindQuery(text: "foo")).ranges(in: line) == [0..<3, 4..<7, 8..<11])
    #expect(try FindMatcher(FindQuery(text: "foo", caseSensitive: true)).ranges(in: line) == [8..<11])
}

@Test func unicodeRangesAreUTF16() throws {
    let line = "naïve café 😀 Café"
    #expect(try FindMatcher(FindQuery(text: "café")).ranges(in: line) == [6..<10, 14..<18])
    #expect(try FindMatcher(FindQuery(text: "😀")).ranges(in: line) == [11..<13])
}

@Test func wholeWords() throws {
    let word = try FindMatcher(FindQuery(text: "foo", wholeWord: true))
    #expect(word.ranges(in: "foo foobar barfoo foo_x (foo)") == [0..<3, 25..<28])
    // Unicode-aware, unlike git's -w: "caf" is not a word inside "café".
    let caf = try FindMatcher(FindQuery(text: "caf", wholeWord: true))
    #expect(caf.ranges(in: "café caf") == [5..<8])
    #expect(caf.match(path: "a", line: 1, text: "café") == nil) // git -w reports it; Swift drops it
    // Like git's -w, a pattern may start or end with a non-word character.
    #expect(try FindMatcher(FindQuery(text: "-x", wholeWord: true)).ranges(in: "a -x b") == [2..<4])
}

@Test func regexRanges() throws {
    #expect(try FindMatcher(FindQuery(text: "\\d+", regex: true)).ranges(in: "let x1 = 42, y22 = 7") == [5..<6, 9..<11, 14..<16, 19..<20])
    #expect(try FindMatcher(FindQuery(text: "^", regex: true)).ranges(in: "abc") == [0..<0])
    #expect(try FindMatcher(FindQuery(text: "\\bfoo\\(", regex: true)).ranges(in: "afoo( foo(") == [6..<10])
    // Literal mode escapes everything.
    #expect(try FindMatcher(FindQuery(text: "b(c")).ranges(in: "a.b(c)") == [2..<5])
    #expect(try FindMatcher(FindQuery(text: ".")).ranges(in: "axb") == [])
    // git matched but ICU doesn't: keep the line, unhighlighted.
    #expect(try FindMatcher(FindQuery(text: ".")).match(path: "a", line: 2, text: "axb") == FindMatch(path: "a", line: 2, preview: "axb", ranges: []))
}

@Test func invalidRegexIsAnError() {
    #expect(throws: FindError.invalidRegex("a ( is never closed")) { try FindMatcher(FindQuery(text: "foo(", regex: true)) }
    #expect(throws: FindError.invalidRegex("a [ is never closed")) { try FindMatcher(FindQuery(text: "[abc", regex: true)) }
    #expect(throws: FindError.emptyQuery) { try FindMatcher(FindQuery(text: "")) }
    #expect(parse("a\u{0}1\u{0}foo(", FindQuery(text: "foo(", regex: true)) == nil)
    // The same text is fine as a literal.
    #expect(parse("a\u{0}1\u{0}foo(", FindQuery(text: "foo("))?.ranges == [0..<4])
}

@Test func longLinesAreCutAroundTheFirstMatch() throws {
    let line = String(repeating: "x", count: 1000) + "needle" + String(repeating: "y", count: 500) + "needle"
    let m = try #require(parse("min.js\u{0}1\u{0}" + line, FindQuery(text: "needle")))
    #expect(m.preview.utf16.count == 400)
    #expect(m.previewStart == 900)
    #expect(m.ranges == [100..<106]) // the second needle is outside the preview
    #expect(m.column == 1000)
    // Only the window is searched, but lookaround and anchors still see the whole line.
    let words = String(repeating: "a", count: 999) + " needle xneedle needle " + String(repeating: "y", count: 500)
    let w = try #require(parse("a\u{0}1\u{0}" + words, FindQuery(text: "needle", wholeWord: true)))
    #expect(w.ranges.map { $0.lowerBound + w.previewStart } == [1000, 1015])
    #expect(parse("a\u{0}1\u{0}" + words, FindQuery(text: "^a", regex: true))?.ranges == [0..<1])
    let end = try #require(parse("a\u{0}1\u{0}" + words, FindQuery(text: "y$", regex: true)))
    #expect(end.ranges == [399..<400])
    #expect(end.previewStart + 400 == words.utf16.count)
    // Never cut a surrogate pair in half.
    // (the window would start at 900, the second half of the emoji at 899...900)
    let emoji = String(repeating: "x", count: 899) + "😀" + String(repeating: "x", count: 99) + "needle" + String(repeating: "y", count: 600)
    let e = try #require(parse("a\u{0}1\u{0}" + emoji, FindQuery(text: "needle")))
    #expect(e.previewStart == 901)
    #expect(e.column == 1000)
    #expect(!UTF16.isTrailSurrogate(e.preview.utf16.first!))
}

@Test func recordSplitterHandlesAnyChunking() {
    let stream = Array("a.ts\u{0}1\u{0}café\nwe ird\nname.txt\u{0}22\u{0}bar foo\nlast\u{0}3\u{0}tail".utf8)
    var splitter = GrepOutputParser.RecordSplitter()
    var records: [GrepOutputParser.RecordSplitter.Record] = []
    for byte in stream { records += splitter.append([byte]) } // worst case: one byte at a time
    records += splitter.finish()
    #expect(records == [
        .init(path: "a.ts", line: 1, text: "café"),
        .init(path: "we ird\nname.txt", line: 22, text: "bar foo"), // a newline in a path
        .init(path: "last", line: 3, text: "tail"),
    ])
    var whole = GrepOutputParser.RecordSplitter()
    #expect(whole.append(stream).count == 2)
}

@Test func swiftSearchMatchesGitLines() throws {
    let matcher = try FindMatcher(FindQuery(text: "foo"))
    let found = matcher.search(path: "a.txt", text: "one foo\r\ntwo\u{2028}foo\nthree foo foo\nno")
    #expect(found == [
        FindMatch(path: "a.txt", line: 1, preview: "one foo", ranges: [4..<7]),
        FindMatch(path: "a.txt", line: 2, preview: "two\u{2028}foo", ranges: [4..<7]), // only \n ends a line
        FindMatch(path: "a.txt", line: 3, preview: "three foo foo", ranges: [6..<9, 10..<13]),
    ])
    #expect(matcher.search(path: "a", text: "nothing here").isEmpty)
    #expect(matcher.search(path: "a", text: "foo\nfoo\nfoo", limit: 2).count == 2)
}
