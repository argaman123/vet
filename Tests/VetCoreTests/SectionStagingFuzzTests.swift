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
