import Foundation
import Testing
@testable import VetCore

// Randomized check that staging or unstaging any section never loses or duplicates a line.
// Lines carry unique labels ("h3" from HEAD, "i2" only in the index, "w5" only in the working
// file), so the checks below don't depend on how SectionStaging computes regions.

private func L(_ a: [String]) -> TextLines { TextLines(a.map { $0 + "\n" }.joined()) }
private func S(_ d: Data) -> [String] {
    Array(String(decoding: d, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init).dropLast())
}

private struct XorShift: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
}

/// Block-shaped random edits of `base`: replacements, deletions, insertions, runs of new lines.
private func mutate(_ base: [String], tag: String, _ r: inout XorShift) -> [String] {
    var out: [String] = [], n = 0, run = 0
    for x in base {
        if run > 0 { run -= 1; n += 1; out.append("\(tag)\(n)"); continue }
        if Int.random(in: 0..<8, using: &r) == 0 { run = Int.random(in: 1..<6, using: &r); n += 1; out.append("\(tag)\(n)"); continue }
        switch Int.random(in: 0..<10, using: &r) {
        case 0: n += 1; out.append("\(tag)\(n)")
        case 1: break
        case 2: n += 1; out.append("\(tag)\(n)"); out.append(x)
        default: out.append(x)
        }
    }
    if Int.random(in: 0..<6, using: &r) == 0 { n += 1; out.append("\(tag)\(n)") }
    return out
}

/// The invariants that must hold for any correct section staging.
private func check(head: [String], index: [String], work: [String], fail: (String) -> Void) {
    let s = SectionStaging(head: L(head), index: L(index), work: L(work))
    let inIndex = Set(index), inWork = Set(work)
    for h in s.hunks {
        for staged in [true, false] {
            let out = S(s.indexText(setting: h, staged: staged))
            let ctx = "staged=\(staged) hunk \(h.head)->\(h.work)\n head=\(head)\n index=\(index)\n work=\(work)\n out=\(out)"
            // No duplicates, and nothing invented.
            if Set(out).count != out.count { fail("duplicate line: \(ctx)"); return }
            for x in out where !inIndex.contains(x) && !inWork.contains(x) && !head.contains(x) { fail("invented line \(x): \(ctx)"); return }
            // A HEAD line that both the index and the working file still have can never disappear.
            for x in head where inIndex.contains(x) && inWork.contains(x) && !out.contains(x) { fail("lost line \(x): \(ctx)"); return }
            // Index-only lines survive unless this operation replaced them; working-only lines
            // appear only when staging.
            if !staged { for x in out where x.hasPrefix("w") { fail("unstaging added \(x): \(ctx)"); return } }
            // The operation did what was asked to this section.
            let after = SectionStaging(head: L(head), index: L(out), work: L(work))
            if let same = after.hunks.first(where: { $0.head == h.head && $0.work == h.work }) {
                let want: StageState = staged ? .staged : .unstaged
                if after.state(of: same) != want { fail("section is \(after.state(of: same)), wanted \(want): \(ctx)"); return }
            }
        }
    }
}

@Test func reviewerCaseKeepsLineOne() {
    // HEAD 0-11; index changed 1-3 and 6-9; work changed 2-6 and 8. Staging the section at
    // line 8 used to drop line 1.
    let head = (0..<12).map { "h\($0)" }
    var work = head
    for k in 2...6 { work[k] = "w\(k)" }
    work[8] = "w8"
    var index = head
    for k in 1...3 { index[k] = "i\(k)" }
    for k in 6...9 { index[k] = "i\(k)" }
    var problems: [String] = []
    check(head: head, index: index, work: work) { problems.append($0) }
    #expect(problems.isEmpty, "\(problems.first ?? "")")
}

@Test func randomStagingNeverLosesOrDuplicatesLines() {
    var r = XorShift(s: 0x9E37_79B9_7F4A_7C15)
    var problems: [String] = []
    for _ in 0..<6_000 where problems.isEmpty {
        let head = (0..<Int.random(in: 0..<30, using: &r)).map { "h\($0)" }
        check(head: head, index: mutate(head, tag: "i", &r), work: mutate(head, tag: "w", &r)) { problems.append($0) }
    }
    #expect(problems.isEmpty, "\(problems.first ?? "")")
}

// MARK: Repeated lines, long files, whole-file round trips (review of round 3)

private let alphabet = ["}", "{", "", "  }", "foo()", "  x = 1", "a", "b", "return", "  return x"]

private func randomLines(_ n: Int, _ r: inout XorShift) -> [String] {
    (0..<n).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &r)] }
}

/// Block edits that reuse the same small alphabet, so lines repeat.
private func mutateRepeating(_ base: [String], _ r: inout XorShift) -> [String] {
    var out: [String] = []
    for x in base {
        switch Int.random(in: 0..<10, using: &r) {
        case 0: out.append(alphabet[Int.random(in: 0..<alphabet.count, using: &r)])
        case 1: break
        case 2: out += randomLines(Int.random(in: 1..<4, using: &r), &r); out.append(x)
        default: out.append(x)
        }
    }
    if Int.random(in: 0..<5, using: &r) == 0 { out += randomLines(2, &r) }
    return out
}

/// Stages (or unstages) every section one at a time, in a shuffled order, re-reading in between.
private func applyAll(head: [String], start: [String], work: [String], staged: Bool, _ r: inout XorShift) -> [String] {
    var index = start
    let targets = SectionStaging(head: L(head), index: L(index), work: L(work)).hunks.map { ($0.head, $0.work) }.shuffled(using: &r)
    for t in targets {
        let s = SectionStaging(head: L(head), index: L(index), work: L(work))
        guard let h = s.hunks.first(where: { $0.head.overlaps(t.0) || $0.work.overlaps(t.1) || ($0.head == t.0 && $0.work == t.1) }) else { continue }
        index = S(s.indexText(setting: h, staged: staged))
    }
    return index
}

@Test func reviewerDuplicationCase() {
    let head = ["}", "foo()", "a", "", "{", "  }", "}", "foo()", "foo()", "  x = 1"]
    let work = ["}", "  }", "  }", "  }", "foo()", "{", "  x = 1"]
    var r = XorShift(s: 1)
    #expect(applyAll(head: head, start: head, work: work, staged: true, &r) == work)
    #expect(applyAll(head: head, start: work, work: work, staged: false, &r) == head)
}

@Test func stagingEverySectionGivesTheFile() {
    var r = XorShift(s: 0xD1B5_4A32_D192_ED03)
    var problems: [String] = []
    for n in 0..<1_200 where problems.isEmpty {
        let long = n == 0 || n == 600 // twice a file long enough for the Myers path
        let head = randomLines(long ? 1_800 : Int.random(in: 0..<40, using: &r), &r)
        let work = mutateRepeating(head, &r)
        let staged = applyAll(head: head, start: head, work: work, staged: true, &r)
        if staged != work { problems.append("stage all ≠ work\n head=\(head.prefix(40))\n work=\(work.prefix(40))") }
        let unstaged = applyAll(head: head, start: work, work: work, staged: false, &r)
        if unstaged != head { problems.append("unstage all ≠ head\n head=\(head.prefix(40))\n work=\(work.prefix(40))") }
        // Stage selected lines over the whole file stages everything.
        let all = SectionStaging(head: L(head), index: L(head), work: L(work)).indexText(stagingWorkLines: 0..<max(1, work.count))
        if !work.isEmpty && S(all) != work { problems.append("stage all lines ≠ work\n head=\(head.prefix(40))\n work=\(work.prefix(40))") }
    }
    #expect(problems.isEmpty, "\(problems.first ?? "")")
}

/// What you see is what gets staged: ticking one section (index = HEAD) gives exactly HEAD with
/// that displayed section swapped for the working-file lines; unticking (index = work) the reverse.
@Test func stagingASectionIsExactlyWhatItShows() {
    var r = XorShift(s: 0x5851_F42D_4C95_7F2D)
    var problems: [String] = []
    for _ in 0..<3_000 where problems.isEmpty {
        let head = randomLines(Int.random(in: 0..<40, using: &r), &r)
        let work = mutateRepeating(head, &r)
        let fromHead = SectionStaging(head: L(head), index: L(head), work: L(work))
        for h in fromHead.hunks {
            let want = Array(head[..<h.head.lowerBound]) + Array(work[h.work]) + Array(head[h.head.upperBound...])
            let got = S(fromHead.indexText(setting: h, staged: true))
            if got != want { problems.append("stage \(h.head)->\(h.work)\n head=\(head)\n work=\(work)\n got=\(got)\n want=\(want)"); break }
        }
        let fromWork = SectionStaging(head: L(head), index: L(work), work: L(work))
        for h in fromWork.hunks {
            let want = Array(work[..<h.work.lowerBound]) + Array(head[h.head]) + Array(work[h.work.upperBound...])
            let got = S(fromWork.indexText(setting: h, staged: false))
            if got != want { problems.append("unstage \(h.head)->\(h.work)\n head=\(head)\n work=\(work)\n got=\(got)\n want=\(want)"); break }
        }
    }
    #expect(problems.isEmpty, "\(problems.first ?? "")")
}
