import Foundation
import Testing
@testable import VetCore

private func s(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

@Test func unchangedRoundTripsByteExact() {
    for file in ["a\nb\n", "a\nb", "a\r\nb\nc\r\n", "a\nb\n\n", "\n", "only", "x\r\n\r\n"] {
        let t = TextLines(file)
        let rows = t.lines.map { EditedText.Row.text(String($0.text)) }
        #expect(s(EditedText.rebuild(rows: rows, original: t)) == file, "\(file.debugDescription)")
    }
}

@Test func editKeepsOtherLinesEndings() {
    let t = TextLines("one\r\ntwo\nthree\r\n")
    let out = EditedText.rebuild(rows: [.text("one"), .text("TWO!"), .text("three")], original: t)
    #expect(s(out) == "one\r\nTWO!\r\nthree\r\n") // changed line gets the dominant ending (CRLF)
}

@Test func foldsRestoreAndNotesSkip() {
    let t = TextLines("a\nb\nc\nd\ne\n")
    let out = EditedText.rebuild(rows: [.text("A"), .original(1..<4), .skip, .skip, .text("e")], original: t)
    #expect(s(out) == "A\nb\nc\nd\ne\n")
}

@Test func blankLinesAndFinalNewline() {
    let t = TextLines("a\nb\n")
    // You added a blank last line: kept.
    #expect(s(EditedText.rebuild(rows: [.text("a"), .text("b"), .text("")], original: t)) == "a\nb\n\n")
    // A file without a final newline stays without one, even when you add a line.
    let n = TextLines("a\nb")
    #expect(s(EditedText.rebuild(rows: [.text("a"), .text("b"), .text("c")], original: n)) == "a\nb\nc")
}
