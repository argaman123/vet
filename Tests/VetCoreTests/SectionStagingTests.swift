import Foundation
import Testing
@testable import VetCore

private func lines(_ s: String) -> TextLines { TextLines(s) }
private func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

@Test func stagesOneOfTwoHunks() {
    let head = lines("a\nb\nc\nd\ne\n"), work = lines("a\nB\nc\nd\nE\n")
    let s = SectionStaging(head: head, index: head, work: work)
    #expect(s.hunks.count == 2)
    let staged = text(s.indexText(setting: s.hunks[0], staged: true))
    #expect(staged == "a\nB\nc\nd\ne\n")
    let s2 = SectionStaging(head: head, index: lines(staged), work: work)
    #expect(s2.state(of: s2.hunks[0]) == .staged)
    #expect(s2.state(of: s2.hunks[1]) == .unstaged)
}

@Test func unstagesBackToHead() {
    let head = lines("a\nb\nc\nd\ne\n"), work = lines("a\nB\nc\nd\nE\n")
    let s = SectionStaging(head: head, index: work, work: work)
    #expect(text(s.indexText(setting: s.hunks[1], staged: false)) == "a\nB\nc\nd\ne\n")
}

@Test func pureInsertionAndDeletion() {
    let head = lines("a\nb\nc\n"), work = lines("a\nx\nb\n")
    let s = SectionStaging(head: head, index: head, work: work)
    #expect(s.hunks.count == 2) // insert x after a; delete c
    #expect(text(s.indexText(setting: s.hunks[0], staged: true)) == "a\nx\nb\nc\n")
    #expect(text(s.indexText(setting: s.hunks[1], staged: true)) == "a\nb\n")
}

@Test func addedFileWholeHunk() {
    let work = lines("one\ntwo\n")
    let s = SectionStaging(head: lines(""), index: lines(""), work: work)
    #expect(s.hunks.count == 1)
    #expect(text(s.indexText(setting: s.hunks[0], staged: true)) == "one\ntwo\n")
}

@Test func preservesNoFinalNewline() {
    let head = lines("a\nb"), work = lines("a\nB")
    let s = SectionStaging(head: head, index: head, work: work)
    #expect(text(s.indexText(setting: s.hunks[0], staged: true)) == "a\nB")
    // Adding lines after a last line that had no newline must not glue them together.
    let work2 = lines("a\nb\nc\n")
    let s2 = SectionStaging(head: head, index: head, work: work2)
    #expect(text(s2.indexText(setting: s2.hunks[0], staged: true)) == "a\nb\nc\n")
}

@Test func preservesCRLF() {
    let head = lines("a\r\nb\r\nc\r\n"), work = lines("a\r\nB\r\nc\r\n")
    let s = SectionStaging(head: head, index: head, work: work)
    #expect(text(s.indexText(setting: s.hunks[0], staged: true)) == "a\r\nB\r\nc\r\n")
    let mixed = "one\r\ntwo\nthree\r\nfour"
    #expect(text(TextLines(mixed).joined()) == mixed)
}

@Test func leavesUnrelatedIndexContentAlone() {
    // Line 2 was staged as X, then the working file reverted it to b.
    let head = lines("a\nb\nc\n"), index = lines("a\nX\nc\n"), work = lines("a\nb\nC\n")
    let s = SectionStaging(head: head, index: index, work: work)
    #expect(s.hunks.count == 1) // only c → C differs between HEAD and work
    #expect(text(s.indexText(setting: s.hunks[0], staged: true)) == "a\nX\nC\n")
    #expect(text(s.indexText(setting: s.hunks[0], staged: false)) == "a\nX\nc\n")
}

@Test func partialDetected() {
    let head = lines("a\nb\nc\nd\n"), work = lines("a\nB\nC\nd\n"), index = lines("a\nB\nc\nd\n")
    let s = SectionStaging(head: head, index: index, work: work)
    #expect(s.hunks.count == 1)
    #expect(s.state(of: s.hunks[0]) == .partial)
    // Staging the partial section finishes it.
    #expect(text(s.indexText(setting: s.hunks[0], staged: true)) == "a\nB\nC\nd\n")
}

@Test func snapshotChangesWithWork() {
    let head = lines("a\n")
    let s1 = SectionStaging(head: head, index: head, work: lines("b\n"))
    let s2 = SectionStaging(head: head, index: head, work: lines("c\n"))
    #expect(s1.snapshotID != s2.snapshotID)
}

@Test func insertionAlreadyStagedIsStaged() {
    let head = lines("a\nb\n"), work = lines("a\nx\nb\n")
    let s = SectionStaging(head: head, index: work, work: work)
    #expect(s.state(of: s.hunks[0]) == .staged)
    #expect(text(s.indexText(setting: s.hunks[0], staged: false)) == "a\nb\n")
}

@Test func wordChangesFound() {
    let h = LineDiff.hunks(head: lines("let x = 1\n"), work: lines("let y = 1\n"))
    #expect(h.first?.workCols == [0: [4..<5]])
}

@Test func composedAndDecomposedAreDifferentBytes() {
    // "é" as one scalar vs "e" + combining accent: equal as Swift Strings, different bytes.
    let head = TextLines("caf\u{00E9}\n"), work = TextLines("cafe\u{0301}\n")
    let s = SectionStaging(head: head, index: head, work: work)
    #expect(s.hunks.count == 1)
    #expect(s.state(of: s.hunks[0]) == .unstaged)
    #expect(s.indexText(setting: s.hunks[0], staged: true) == work.joined())
    // A combining mark right after a newline must not glue two lines together.
    #expect(TextLines("a\n\u{0301}b\n").count == 2)
}

@Test func stagingSelectedLinesTakesOnlyTheSelectedNewLines() {
    // VS Code's intersectDiffWithRange: the new side is cut to the selection; the old side is
    // paired line by line when both sides are the same size, else replaced whole.
    let head = lines("a\nb\n"), added = lines("a\nx\ny\nz\nb\n")
    let s = SectionStaging(head: head, index: head, work: added)
    #expect(text(s.indexText(stagingWorkLines: 1..<3)) == "a\nx\ny\nb\n")

    let replaced = lines("a\nX\nY\nZ\nb\n"), before = lines("a\nold\nb\n")
    let r = SectionStaging(head: before, index: before, work: replaced)
    #expect(text(r.indexText(stagingWorkLines: 2..<3)) == "a\nY\nb\n")
}
