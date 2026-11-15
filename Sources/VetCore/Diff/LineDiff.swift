import Foundation

// Ported from VS Code (microsoft/vscode,
// src/vs/editor/common/diff/defaultLinesDiffComputer/defaultLinesDiffComputer.ts; MIT License,
// Copyright (c) Microsoft Corporation). See THIRD-PARTY-NOTICES.md.

/// Line diff between two versions of a file: a port of VS Code's `DefaultLinesDiffComputer`,
/// except that lines compare by exact bytes, terminator
/// included, so whitespace, line-ending and final-newline changes are all real, stageable changes.
///
/// 1. Lines are aligned by a scored dynamic program (small files) or Myers' O(ND) diff with a
///    deadline, then the boundaries are shifted and nearly-touching changes joined.
/// 2. Each changed block is diffed again as one character sequence; the changed lines are the
///    ones those character changes touch (a block can split into several hunks), and the
///    character changes become the hunk's highlighted columns.
public enum LineDiff {
    /// Past this the diff gives up and the whole file is one change (VS Code's default).
    static let timeoutSeconds = 5.0

    /// The changes from `head` to `work`, in file order. With `wordChanges`, hunks that replace
    /// lines also carry the changed columns of each line.
    public static func hunks(head: TextLines, work: TextLines, wordChanges: Bool = true) -> [Hunk] {
        let al = align(head, work)
        guard var diffs = al.diffs else { return [al.whole] }
        diffs = DiffHeuristics.removeVeryShortMatchingLinesBetweenDiffs(al.s1, diffs)

        // Each section is one joined line change, exactly as staging aligns lines: what you see
        // is what a checkbox stages (VS Code further splits by character changes, which can pair
        // repeated lines differently from the line alignment). Character changes only choose the
        // highlighted columns.
        var hunks: [Hunk] = []
        for d in diffs {
            let h = d.a.clamped(toCount: al.a.count), w = d.b.clamped(toCount: al.b.count)
            if h.isEmpty && w.isEmpty { continue }
            var hunk = Hunk(id: hunks.count, head: h, work: w)
            if wordChanges, !h.isEmpty, !w.isEmpty, let refined = CharDiff.refine(d, al.t1, al.t2, timeout: al.timeout), !refined.gaveUp {
                hunk.headCols = columns(refined.mappings, lines: h, \.orig, al.t1)
                hunk.workCols = columns(refined.mappings, lines: w, \.mod, al.t2)
            }
            hunks.append(hunk)
        }
        return hunks
    }

    /// The line alignment alone, before changes separated by short unchanged gaps are joined:
    /// minimal blocks in which no line matches a line on the other side, so a block with as
    /// many lines on each side pairs up line by line (which staging relies on). Every block lies
    /// within one of `hunks`'s hunks.
    static func lineChanges(head: TextLines, work: TextLines) -> [Hunk] {
        let al = align(head, work)
        guard let diffs = al.diffs else { return [al.whole] }
        var hunks: [Hunk] = []
        for d in diffs {
            let h = d.a.clamped(toCount: al.a.count), w = d.b.clamped(toCount: al.b.count)
            if !h.isEmpty || !w.isEmpty { hunks.append(Hunk(id: hunks.count, head: h, work: w)) }
        }
        return hunks
    }

    struct Alignment {
        /// Line ids: equal ids, equal bytes.
        var a: [Int32], b: [Int32]
        var s1: LineSequence, s2: LineSequence
        var t1: UTF16Lines, t2: UTF16Lines
        var timeout: DiffTimeout
        /// The optimized line diffs (over VS Code lines); nil when the whole file is one change
        /// (one side is empty, or the deadline passed).
        var diffs: [SeqDiff]?
        var whole: Hunk { Hunk(id: 0, head: 0..<a.count, work: 0..<b.count) }
    }

    /// Interns lines, aligns them and shifts the changes to better boundaries.
    static func align(_ head: TextLines, _ work: TextLines) -> Alignment {
        // Intern each distinct line (by bytes) to an integer, so the diff compares ints.
        var ids: [[UInt8]: Int32] = [:]
        func id(_ line: Line) -> Int32 {
            let k = line.key
            if let v = ids[k] { return v }
            let v = Int32(ids.count)
            ids[k] = v
            return v
        }
        let a = head.lines.map(id), b = work.lines.map(id)
        let t1 = UTF16Lines(head), t2 = UTF16Lines(work)
        // VS Code's empty last line after a final newline; -1 is no real line's id.
        let s1 = LineSequence(elements: t1.count > a.count ? a + [-1] : a, lines: head)
        let s2 = LineSequence(elements: t2.count > b.count ? b + [-1] : b, lines: work)
        var al = Alignment(a: a, b: b, s1: s1, s2: s2, t1: t1, t2: t2, timeout: DiffTimeout(seconds: timeoutSeconds))
        if a == b { al.diffs = []; return al }
        if a.isEmpty || b.isEmpty { return al }

        let alignment: DiffAlgorithmResult
        if s1.count + s2.count < 1700 {
            // A match scores more the longer the line, so real code beats blank lines and braces.
            let scores = (0..<s2.count).map { j -> Double in
                let n = t2.length(j)
                return n == 0 ? 0.1 : 1 + log(1 + Double(n))
            }
            alignment = DynamicProgrammingDiff.compute(s1.elements, s2.elements, timeout: al.timeout, matchScore: scores)
        } else {
            alignment = MyersDiff.compute(s1.elements, s2.elements, timeout: al.timeout)
        }
        if alignment.hitTimeout { return al }
        al.diffs = DiffHeuristics.optimize(s1, s2, alignment.diffs)
        return al
    }

    /// A hunk in the making: 0-based line ranges and the character changes inside them.
    struct Piece {
        var head: Range<Int>
        var work: Range<Int>
        var inner: [RangeMapping]
    }

    /// Splits the line diff `d` into the hunks its character changes touch (VS Code's
    /// `lineRangeMappingFromRangeMappings`), keeping Vet's invariant that lines between hunks
    /// pair up and are byte-equal: where they are not (lines that differ only in bytes the
    /// character diff can't see, such as their terminator), the pieces around them are joined.
    static func pieces(_ d: SeqDiff, _ mappings: [RangeMapping]?, _ a: [Int32], _ b: [Int32],
                       _ t1: UTF16Lines, _ t2: UTF16Lines) -> [Piece] {
        // Drop VS Code's virtual last line.
        let dh = d.a.clamped(toCount: a.count), dw = d.b.clamped(toCount: b.count)
        if dh.isEmpty && dw.isEmpty { return [] }
        func clamp(_ r: Range<Int>, _ to: Range<Int>) -> Range<Int> {
            let lo = Swift.min(Swift.max(r.lowerBound, to.lowerBound), to.upperBound)
            return lo..<Swift.min(Swift.max(r.upperBound, lo), to.upperBound)
        }

        // Group character changes whose lines touch on either side.
        var subs: [Piece] = []
        var first: (orig: Range<Int>, mod: Range<Int>)?, last: (orig: Range<Int>, mod: Range<Int>)?
        func flush() {
            guard let f = first, let l = last else { return }
            let o = f.orig.hull(l.orig), m = f.mod.hull(l.mod)
            subs[subs.count - 1].head = clamp((o.lowerBound - 1)..<(o.upperBound - 1), dh)
            subs[subs.count - 1].work = clamp((m.lowerBound - 1)..<(m.upperBound - 1), dw)
        }
        for mapping in mappings ?? [] {
            let r = CharDiff.lineRanges(mapping, t1, t2)
            if let l = last, touches(l.orig, r.orig) || touches(l.mod, r.mod) {
                subs[subs.count - 1].inner.append(mapping)
            } else {
                flush()
                subs.append(Piece(head: dh, work: dw, inner: [mapping]))
                first = r
            }
            last = r
        }
        flush()
        if mappings == nil { subs = [Piece(head: dh, work: dw, inner: [])] }

        func equal(_ h: Range<Int>, _ w: Range<Int>) -> Bool {
            h.count == w.count && zip(a[h], b[w]).allSatisfy { $0 == $1 }
        }
        var out: [Piece] = []
        var ph = dh.lowerBound, pw = dw.lowerBound  // where the previous piece ended
        for s in subs {
            if s.head.lowerBound >= ph && s.work.lowerBound >= pw && equal(ph..<s.head.lowerBound, pw..<s.work.lowerBound) {
                out.append(s)
            } else if let l = out.last {
                out[out.count - 1] = Piece(head: l.head.lowerBound..<Swift.max(l.head.upperBound, s.head.upperBound),
                                           work: l.work.lowerBound..<Swift.max(l.work.upperBound, s.work.upperBound),
                                           inner: l.inner + s.inner)
            } else {
                out.append(Piece(head: ph..<Swift.max(ph, s.head.upperBound), work: pw..<Swift.max(pw, s.work.upperBound), inner: s.inner))
            }
            ph = out[out.count - 1].head.upperBound
            pw = out[out.count - 1].work.upperBound
        }
        if !equal(ph..<dh.upperBound, pw..<dw.upperBound) {
            if let l = out.last {
                out[out.count - 1] = Piece(head: l.head.lowerBound..<dh.upperBound, work: l.work.lowerBound..<dw.upperBound, inner: l.inner)
            } else {
                out = [Piece(head: dh, work: dw, inner: [])]
            }
        }
        return out.filter { !$0.head.isEmpty || !$0.work.isEmpty }
    }

    /// VS Code's `LineRange.intersectsOrTouches`.
    private static func touches(_ x: Range<Int>, _ y: Range<Int>) -> Bool {
        x.lowerBound <= y.upperBound && y.lowerBound <= x.upperBound
    }

    /// One side of the character changes as UTF-16 column ranges per line (0-based), limited to
    /// `lines`, merged, and never splitting a surrogate pair.
    static func columns(_ inner: [RangeMapping], lines: Range<Int>, _ side: KeyPath<RangeMapping, TextRange>,
                        _ text: UTF16Lines) -> [Int: [Range<Int>]] {
        var out: [Int: [Range<Int>]] = [:]
        for m in inner {
            let r = m[keyPath: side]
            guard r.start.line <= r.end.line else { continue }
            for lineNumber in r.start.line...r.end.line where lines.contains(lineNumber - 1) {
                let u = text.line(lineNumber - 1)
                var lo = Swift.min(Swift.max(lineNumber == r.start.line ? r.start.col - 1 : 0, 0), u.count)
                var hi = Swift.min(Swift.max(lineNumber == r.end.line ? r.end.col - 1 : u.count, lo), u.count)
                if lo > 0 && lo < u.count && UTF16.isTrailSurrogate(u[lo]) && UTF16.isLeadSurrogate(u[lo - 1]) { lo -= 1 }
                if hi > 0 && hi < u.count && UTF16.isTrailSurrogate(u[hi]) && UTF16.isLeadSurrogate(u[hi - 1]) { hi += 1 }
                if hi > lo { out[lineNumber - 1, default: []].append(lo..<hi) }
            }
        }
        for (line, ranges) in out {
            var merged: [Range<Int>] = []
            for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let l = merged.last, r.lowerBound <= l.upperBound {
                    merged[merged.count - 1] = l.lowerBound..<Swift.max(l.upperBound, r.upperBound)
                } else {
                    merged.append(r)
                }
            }
            out[line] = merged
        }
        return out
    }
}

/// The lines of a file as diff elements (VS Code's `LineSequence`); ids are exact bytes.
struct LineSequence: DiffSequence {
    let elements: [Int32]
    let lines: TextLines

    /// Boundaries next to blank or less-indented lines score higher.
    func boundaryScore(_ length: Int) -> Int {
        let before = length == 0 ? 0 : indentation(length - 1)
        let after = length == elements.count ? 0 : indentation(length)
        return 1000 - (before + after)
    }

    private func indentation(_ i: Int) -> Int {
        guard i >= 0 && i < lines.count else { return 0 }
        var n = 0
        for c in lines.lines[i].text.utf8 {
            guard c == 32 || c == 9 else { break }
            n += 1
        }
        return n
    }

    /// UTF-16 length of the lines in `r` without whitespace, counting no further than `limit`.
    func nonWhitespaceLength(_ r: Range<Int>, limit: Int) -> Int {
        var n = 0
        for i in r where i >= 0 && i < lines.count {
            for u in lines.lines[i].text.utf16 where !JSText.isWhitespace(Int32(u)) {
                n += 1
                if n >= limit { return n }
            }
        }
        return n
    }
}
