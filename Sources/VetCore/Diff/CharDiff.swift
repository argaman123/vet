// Character-level refinement of a changed block of lines, ported from VS Code (microsoft/vscode,
// src/vs/editor/common/diff/defaultLinesDiffComputer/linesSliceCharSequence.ts,
// defaultLinesDiffComputer.ts `refineDiff` and rangeMapping.ts; MIT License,
// Copyright (c) Microsoft Corporation). Positions are 1-based lines and UTF-16 columns, as in
// VS Code, over "VS Code lines": a file's line texts without terminators, plus one empty last
// line when the file ends in a newline (or is empty).

/// A 1-based (line, UTF-16 column) position.
struct TextPos: Comparable {
    var line: Int
    var col: Int
    static func < (l: TextPos, r: TextPos) -> Bool { l.line < r.line || (l.line == r.line && l.col < r.col) }
}

struct TextRange {
    var start: TextPos
    var end: TextPos
}

/// `orig` text became `mod` text.
struct RangeMapping {
    var orig: TextRange
    var mod: TextRange
}

/// A file's line texts as UTF-16, VS Code style (see the top of this file), converted on demand.
final class UTF16Lines {
    let lines: TextLines
    /// Number of VS Code lines: the real ones plus the empty last line, if any.
    let count: Int
    private var cache: [[UInt16]?]

    init(_ lines: TextLines) {
        self.lines = lines
        count = lines.count + (lines.lines.last?.terminator.isEmpty == true ? 0 : 1)
        cache = Array(repeating: nil, count: lines.count)
    }

    /// Line `i` (0-based); the empty last line, or anything past the end, is empty.
    func line(_ i: Int) -> [UInt16] {
        guard i >= 0 && i < lines.count else { return [] }
        if let l = cache[i] { return l }
        let l = Array(lines.lines[i].text.utf16)
        cache[i] = l
        return l
    }

    func length(_ i: Int) -> Int {
        guard i >= 0 && i < lines.count else { return 0 }
        return cache[i]?.count ?? lines.lines[i].text.utf16.count
    }
}

/// A slice of a file as one sequence of UTF-16 code units, lines joined by "\n"
/// (VS Code's `LinesSliceCharSequence`, with whitespace always significant).
struct CharSlice: DiffSequence {
    private(set) var elements: [Int32] = []
    private var firstElementOffsetByLineIdx: [Int] = [0]
    private var lineStartOffsets: [Int] = []
    private let startLine: Int

    init(_ text: UTF16Lines, _ range: TextRange) {
        startLine = range.start.line
        for lineNumber in range.start.line...range.end.line {
            let line = text.line(lineNumber - 1)
            var lineStartOffset = 0
            if lineNumber == range.start.line && range.start.col > 1 {
                lineStartOffset = range.start.col - 1
            }
            lineStartOffsets.append(lineStartOffset)
            let from = min(lineStartOffset, line.count)
            let available = line.count - from
            let length = lineNumber == range.end.line ? min(range.end.col - 1 - lineStartOffset, available) : available
            if length > 0 {
                for i in from..<(from + length) { elements.append(Int32(line[i])) }
            }
            if lineNumber < range.end.line {
                elements.append(10)
                firstElementOffsetByLineIdx.append(elements.count)
            }
        }
    }

    // MARK: Boundary scores

    private enum Category: Int {
        case wordLower, wordUpper, wordNumber, end, other, separator, space, lineBreakCR, lineBreakLF
        var score: Int { [0, 0, 0, 10, 2, 30, 3, 10, 10][rawValue] }
    }

    private static func category(_ c: Int32?) -> Category {
        guard let c else { return .other }  // JavaScript's `undefined`
        switch c {
        case 10: return .lineBreakLF
        case 13: return .lineBreakCR
        case 32, 9: return .space
        case 97...122: return .wordLower
        case 65...90: return .wordUpper
        case 48...57: return .wordNumber
        case -1: return .end
        case 44, 59: return .separator
        default: return .other
        }
    }

    private func element(_ i: Int) -> Int32? { i >= 0 && i < elements.count ? elements[i] : nil }

    func boundaryScore(_ length: Int) -> Int {
        let prev = Self.category(length > 0 ? element(length - 1) : -1)
        let next = Self.category(length < elements.count ? element(length) : -1)
        if prev == .lineBreakCR && next == .lineBreakLF { return 0 }  // don't break between \r and \n
        if prev == .lineBreakLF { return 150 }  // prefer the line break before the change
        var score = 0
        if prev != next {
            score += 10
            if prev == .wordLower && next == .wordUpper { score += 1 }
        }
        return score + prev.score + next.score
    }

    // MARK: Positions

    func translateOffset(_ offset: Int) -> TextPos {
        // The last line whose first element is at or before `offset`.
        var lo = 0, hi = firstElementOffsetByLineIdx.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if firstElementOffsetByLineIdx[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        let lineOffset = offset - firstElementOffsetByLineIdx[lo]
        return TextPos(line: startLine + lo, col: 1 + lineStartOffsets[lo] + lineOffset)
    }

    func translateRange(_ r: Range<Int>) -> TextRange {
        let p1 = translateOffset(r.lowerBound), p2 = translateOffset(r.upperBound)
        return p2 < p1 ? TextRange(start: p2, end: p2) : TextRange(start: p1, end: p2)
    }

    func countLines(in r: Range<Int>) -> Int {
        translateOffset(r.upperBound).line - translateOffset(r.lowerBound).line
    }

    func extendToFullLines(_ r: Range<Int>) -> Range<Int> {
        let start = firstElementOffsetByLineIdx.last(where: { $0 <= r.lowerBound }) ?? 0
        let end = firstElementOffsetByLineIdx.first(where: { r.upperBound <= $0 }) ?? elements.count
        return start..<Swift.max(start, end)
    }

    // MARK: Words

    private static func isWordChar(_ c: Int32) -> Bool {
        (97...122).contains(c) || (65...90).contains(c) || (48...57).contains(c)
    }

    /// The run of ASCII letters and digits around `offset`, nil if that is not one.
    func wordContaining(_ offset: Int) -> Range<Int>? {
        guard offset >= 0 && offset < elements.count && Self.isWordChar(elements[offset]) else { return nil }
        var start = offset
        while start > 0 && Self.isWordChar(elements[start - 1]) { start -= 1 }
        var end = offset
        while end < elements.count && Self.isWordChar(elements[end]) { end += 1 }
        return start..<end
    }
}

enum CharDiff {
    /// Character diffs past this many edits are abandoned: the block counts as changed whole.
    /// VS Code has no such cap (only its 5 s deadline); it keeps hopeless blocks fast.
    static let maxEdits = 4_000

    struct Refinement {
        var mappings: [RangeMapping]
        /// The diff gave up (deadline or `maxEdits`); `mappings` is then the whole block.
        var gaveUp: Bool
    }

    /// The character changes inside the line diff `d` (0-based VS Code line offsets).
    static func refine(_ d: SeqDiff, _ t1: UTF16Lines, _ t2: UTF16Lines, timeout: DiffTimeout) -> Refinement? {
        guard let rm = textRange(d, t1, t2) else { return nil }
        let s1 = CharSlice(t1, rm.orig), s2 = CharSlice(t2, rm.mod)
        let result = s1.count + s2.count < 500
            ? DynamicProgrammingDiff.compute(s1.elements, s2.elements, timeout: timeout)
            : MyersDiff.compute(s1.elements, s2.elements, timeout: timeout, maxD: maxEdits)
        var diffs = DiffHeuristics.optimize(s1, s2, result.diffs)
        diffs = DiffHeuristics.extendToEntireWords(s1, s2, diffs)
        diffs = DiffHeuristics.removeShortMatches(diffs)
        diffs = DiffHeuristics.removeVeryShortMatchingTextBetweenLongDiffs(s1, s2, diffs)
        let mappings = diffs.map { RangeMapping(orig: s1.translateRange($0.a), mod: s2.translateRange($0.b)) }
        return Refinement(mappings: mappings, gaveUp: result.hitTimeout)
    }

    /// The text a line diff covers (VS Code's `LineRangeMapping.toRangeMapping2`): from the start
    /// of its first line to the start of the line after it, or, at the end of the file, to the
    /// end of its last line (or from the end of the line before it, when one side is empty).
    static func textRange(_ d: SeqDiff, _ t1: UTF16Lines, _ t2: UTF16Lines) -> RangeMapping? {
        let o = (d.a.lowerBound + 1, d.a.upperBound + 1), m = (d.b.lowerBound + 1, d.b.upperBound + 1)
        func valid(_ line: Int, _ t: UTF16Lines) -> Bool { line >= 1 && line <= t.count }
        func normalized(_ line: Int, _ t: UTF16Lines) -> TextPos {  // (line, end of line)
            if line < 1 { return TextPos(line: 1, col: 1) }
            if line > t.count { return TextPos(line: t.count, col: t.length(t.count - 1) + 1) }
            return TextPos(line: line, col: t.length(line - 1) + 1)
        }
        if valid(o.1, t1) && valid(m.1, t2) {
            return RangeMapping(orig: TextRange(start: TextPos(line: o.0, col: 1), end: TextPos(line: o.1, col: 1)),
                                mod: TextRange(start: TextPos(line: m.0, col: 1), end: TextPos(line: m.1, col: 1)))
        }
        if !d.a.isEmpty && !d.b.isEmpty {
            return RangeMapping(orig: TextRange(start: TextPos(line: o.0, col: 1), end: normalized(o.1 - 1, t1)),
                                mod: TextRange(start: TextPos(line: m.0, col: 1), end: normalized(m.1 - 1, t2)))
        }
        if o.0 > 1 && m.0 > 1 {
            return RangeMapping(orig: TextRange(start: normalized(o.0 - 1, t1), end: normalized(o.1 - 1, t1)),
                                mod: TextRange(start: normalized(m.0 - 1, t2), end: normalized(m.1 - 1, t2)))
        }
        return nil  // VS Code: "I don't think this can happen."
    }

    /// The whole lines a character change touches, 1-based [start, end) on each side
    /// (VS Code's `getLineRangeMapping`).
    static func lineRanges(_ r: RangeMapping, _ t1: UTF16Lines, _ t2: UTF16Lines) -> (orig: Range<Int>, mod: Range<Int>) {
        var startDelta = 0, endDelta = 0
        // original: ]xxx \n <- this line is not modified
        if r.mod.end.col == 1 && r.orig.end.col == 1
            && r.orig.start.line + startDelta <= r.orig.end.line && r.mod.start.line + startDelta <= r.mod.end.line {
            endDelta = -1
        }
        // original: xxx[ \n <- this line is not modified
        if r.mod.start.col - 1 >= t2.length(r.mod.start.line - 1) && r.orig.start.col - 1 >= t1.length(r.orig.start.line - 1)
            && r.orig.start.line <= r.orig.end.line + endDelta && r.mod.start.line <= r.mod.end.line + endDelta {
            startDelta = 1
        }
        return ((r.orig.start.line + startDelta)..<(r.orig.end.line + 1 + endDelta),
                (r.mod.start.line + startDelta)..<(r.mod.end.line + 1 + endDelta))
    }
}
