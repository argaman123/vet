import Foundation

// A port of VS Code's diff post-processing (microsoft/vscode,
// src/vs/editor/common/diff/defaultLinesDiffComputer/heuristicSequenceOptimizations.ts;
// MIT License, Copyright (c) Microsoft Corporation).

/// A sequence the heuristics can shift diffs through.
protocol DiffSequence {
    var elements: [Int32] { get }
    /// How good a place `length` (a position between elements) is for a diff to start or end.
    /// Higher is better; never negative.
    func boundaryScore(_ length: Int) -> Int
}

extension DiffSequence {
    var count: Int { elements.count }
    /// Element equality, out-of-range positions never equal (JavaScript's `undefined`).
    @inline(__always) func same(_ i: Int, _ j: Int) -> Bool {
        i >= 0 && j >= 0 && i < elements.count && j < elements.count && elements[i] == elements[j]
    }
}

enum DiffHeuristics {
    static func optimize<S: DiffSequence>(_ s1: S, _ s2: S, _ diffs: [SeqDiff]) -> [SeqDiff] {
        var result = joinByShifting(s1, s2, diffs)
        // Sometimes, calling this function twice improves the result.
        result = joinByShifting(s1, s2, result)
        return shift(s1, s2, result)
    }

    /// Slides pure insertions and deletions through equal elements, first left then right, and
    /// joins them with a neighbouring diff when they meet it.
    static func joinByShifting<S: DiffSequence>(_ s1: S, _ s2: S, _ diffs: [SeqDiff]) -> [SeqDiff] {
        guard !diffs.isEmpty else { return diffs }
        var result: [SeqDiff] = [diffs[0]]
        for i in 1..<diffs.count {
            let prev = result[result.count - 1]
            var cur = diffs[i]
            if cur.a.isEmpty || cur.b.isEmpty {
                let length = cur.a.lowerBound - prev.a.upperBound
                var d = 1
                while d <= length {
                    if !s1.same(cur.a.lowerBound - d, cur.a.upperBound - d) || !s2.same(cur.b.lowerBound - d, cur.b.upperBound - d) { break }
                    d += 1
                }
                d -= 1
                if d == length {
                    result[result.count - 1] = SeqDiff(a: prev.a.lowerBound..<(cur.a.upperBound - length),
                                                       b: prev.b.lowerBound..<(cur.b.upperBound - length))
                    continue
                }
                cur = cur.delta(-d)
            }
            result.append(cur)
        }

        var result2: [SeqDiff] = []
        for i in 0..<(result.count - 1) {
            let next = result[i + 1]
            var cur = result[i]
            if cur.a.isEmpty || cur.b.isEmpty {
                let length = next.a.lowerBound - cur.a.upperBound
                var d = 0
                while d < length {
                    if !s1.same(cur.a.lowerBound + d, cur.a.upperBound + d) || !s2.same(cur.b.lowerBound + d, cur.b.upperBound + d) { break }
                    d += 1
                }
                if d == length {
                    result[i + 1] = SeqDiff(a: (cur.a.lowerBound + length)..<next.a.upperBound,
                                            b: (cur.b.lowerBound + length)..<next.b.upperBound)
                    continue
                }
                if d > 0 { cur = cur.delta(d) }
            }
            result2.append(cur)
        }
        result2.append(result[result.count - 1])
        return result2
    }

    /// Moves each pure insertion or deletion (up to 100 steps, never into a neighbour) to the
    /// position with the best boundary score.
    static func shift<S: DiffSequence>(_ s1: S, _ s2: S, _ diffs: [SeqDiff]) -> [SeqDiff] {
        var diffs = diffs
        for i in diffs.indices {
            let prev = i > 0 ? diffs[i - 1] : nil
            let diff = diffs[i]
            let next = i + 1 < diffs.count ? diffs[i + 1] : nil
            let valid1 = (prev.map { $0.a.upperBound + 1 } ?? 0, next.map { $0.a.lowerBound - 1 } ?? s1.count)
            let valid2 = (prev.map { $0.b.upperBound + 1 } ?? 0, next.map { $0.b.lowerBound - 1 } ?? s2.count)
            if diff.a.isEmpty {
                diffs[i] = shiftToBetterPosition(diff, s1, s2, valid1, valid2)
            } else if diff.b.isEmpty {
                diffs[i] = shiftToBetterPosition(diff.swapped(), s2, s1, valid2, valid1).swapped()
            }
        }
        return diffs
    }

    private static func shiftToBetterPosition<S: DiffSequence>(_ diff: SeqDiff, _ s1: S, _ s2: S,
                                                              _ valid1: (Int, Int), _ valid2: (Int, Int)) -> SeqDiff {
        let maxShiftLimit = 100
        var deltaBefore = 1
        while diff.a.lowerBound - deltaBefore >= valid1.0 && diff.b.lowerBound - deltaBefore >= valid2.0
            && s2.same(diff.b.lowerBound - deltaBefore, diff.b.upperBound - deltaBefore) && deltaBefore < maxShiftLimit {
            deltaBefore += 1
        }
        deltaBefore -= 1
        var deltaAfter = 0
        while diff.a.lowerBound + deltaAfter < valid1.1 && diff.b.upperBound + deltaAfter < valid2.1
            && s2.same(diff.b.lowerBound + deltaAfter, diff.b.upperBound + deltaAfter) && deltaAfter < maxShiftLimit {
            deltaAfter += 1
        }
        if deltaBefore == 0 && deltaAfter == 0 { return diff }

        var bestDelta = 0, bestScore = -1
        for delta in -deltaBefore...deltaAfter {
            let score = s1.boundaryScore(diff.a.lowerBound + delta) + s2.boundaryScore(diff.b.lowerBound + delta)
                + s2.boundaryScore(diff.b.upperBound + delta)
            if score > bestScore {
                bestScore = score
                bestDelta = delta
            }
        }
        return diff.delta(bestDelta)
    }

    /// Joins diffs separated by at most 2 equal elements on either side.
    static func removeShortMatches(_ diffs: [SeqDiff]) -> [SeqDiff] {
        var result: [SeqDiff] = []
        for s in diffs {
            if let last = result.last,
               s.a.lowerBound - last.a.upperBound <= 2 || s.b.lowerBound - last.b.upperBound <= 2 {
                result[result.count - 1] = SeqDiff(a: last.a.hull(s.a), b: last.b.hull(s.b))
            } else {
                result.append(s)
            }
        }
        return result
    }

    /// Joins line diffs whose unchanged gap holds at most 4 non-whitespace characters when
    /// either neighbour spans more than 5 lines (both sides together).
    static func removeVeryShortMatchingLinesBetweenDiffs(_ s1: LineSequence, _ diffs: [SeqDiff]) -> [SeqDiff] {
        var diffs = diffs
        guard !diffs.isEmpty else { return diffs }
        var counter = 0
        var shouldRepeat: Bool
        repeat {
            shouldRepeat = false
            var result: [SeqDiff] = [diffs[0]]
            for i in 1..<diffs.count {
                let cur = diffs[i]
                let last = result[result.count - 1]
                let unchanged = last.a.upperBound..<cur.a.lowerBound
                if s1.nonWhitespaceLength(unchanged, limit: 5) <= 4
                    && (last.a.count + last.b.count > 5 || cur.a.count + cur.b.count > 5) {
                    shouldRepeat = true
                    result[result.count - 1] = last.join(cur)
                } else {
                    result.append(cur)
                }
            }
            diffs = result
            counter += 1
        } while counter <= 10 && shouldRepeat
        return diffs
    }

    /// Grows diffs to whole words when most of a word pair changed anyway.
    static func extendToEntireWords(_ s1: CharSlice, _ s2: CharSlice, _ diffs: [SeqDiff]) -> [SeqDiff] {
        let equalMappings = SeqDiff.invert(diffs, length1: s1.count)
        var nextEqual = 0
        var additional: [SeqDiff] = []
        var lastPoint = (0, 0)

        func scanWord(_ pair: (Int, Int), _ equalMapping: SeqDiff) {
            if pair.0 < lastPoint.0 || pair.1 < lastPoint.1 { return }
            guard let w1 = s1.wordContaining(pair.0), let w2 = s2.wordContaining(pair.1) else { return }
            var w = SeqDiff(a: w1, b: w2)
            guard let equalPart = w.intersect(equalMapping) else { return }
            var equalChars1 = equalPart.a.count
            var equalChars2 = equalPart.b.count

            // The words do not touch previous equal mappings, but they might touch the next ones.
            while nextEqual < equalMappings.count {
                let next = equalMappings[nextEqual]
                guard next.a.intersectsStrictly(w.a) || next.b.intersectsStrictly(w.b) else { break }
                guard let v1 = s1.wordContaining(next.a.lowerBound), let v2 = s2.wordContaining(next.b.lowerBound) else { break }
                let v = SeqDiff(a: v1, b: v2)
                guard let part = v.intersect(next) else { break }
                equalChars1 += part.a.count
                equalChars2 += part.b.count
                w = w.join(v)
                if w.a.upperBound >= next.a.upperBound {
                    nextEqual += 1  // the word extends beyond this equal mapping
                } else {
                    break
                }
            }
            if Double(equalChars1 + equalChars2) < Double(w.a.count + w.b.count) * 2 / 3 {
                additional.append(w)
            }
            lastPoint = w.ends
        }

        while nextEqual < equalMappings.count {
            let next = equalMappings[nextEqual]
            nextEqual += 1
            if next.a.isEmpty { continue }
            scanWord(next.starts, next)
            // The equal part is not empty, so -1 is a character that is equal on both sides.
            scanWord((next.a.upperBound - 1, next.b.upperBound - 1), next)
        }
        return merge(diffs, additional)
    }

    private static func merge(_ d1: [SeqDiff], _ d2: [SeqDiff]) -> [SeqDiff] {
        var result: [SeqDiff] = []
        var i = 0, j = 0
        while i < d1.count || j < d2.count {
            let next: SeqDiff
            if i < d1.count && (j >= d2.count || d1[i].a.lowerBound < d2[j].a.lowerBound) {
                next = d1[i]; i += 1
            } else {
                next = d2[j]; j += 1
            }
            if let last = result.last, last.a.upperBound >= next.a.lowerBound {
                result[result.count - 1] = last.join(next)
            } else {
                result.append(next)
            }
        }
        return result
    }

    /// Joins character diffs separated by short single-line text when the diffs around it are
    /// long, then marks almost-blank line prefixes and suffixes of long diffs as changed.
    static func removeVeryShortMatchingTextBetweenLongDiffs(_ s1: CharSlice, _ s2: CharSlice, _ diffs: [SeqDiff]) -> [SeqDiff] {
        var diffs = diffs
        guard !diffs.isEmpty else { return diffs }

        func shouldJoin(_ before: SeqDiff, _ after: SeqDiff) -> Bool {
            let unchanged = before.a.upperBound..<after.a.lowerBound
            if s1.countLines(in: unchanged) > 5 || unchanged.count > 500 { return false }
            let text = JSText.trimmed(s1.elements[unchanged])
            if text.count > 20 || text.contains(where: { $0 == 10 || $0 == 13 }) { return false }

            let max = Double(2 * 40 + 50)
            func cap(_ v: Int) -> Double { Swift.min(Double(v), max) }
            func size(_ lines: Int, _ length: Int) -> Double { pow(cap(lines * 40 + length), 1.5) }
            let beforeSize = pow(size(s1.countLines(in: before.a), before.a.count) + size(s2.countLines(in: before.b), before.b.count), 1.5)
            let afterSize = pow(size(s1.countLines(in: after.a), after.a.count) + size(s2.countLines(in: after.b), after.b.count), 1.5)
            return beforeSize + afterSize > pow(pow(max, 1.5), 1.5) * 1.3
        }

        var counter = 0
        var shouldRepeat: Bool
        repeat {
            shouldRepeat = false
            var result: [SeqDiff] = [diffs[0]]
            for i in 1..<diffs.count {
                let cur = diffs[i]
                let last = result[result.count - 1]
                if shouldJoin(last, cur) {
                    shouldRepeat = true
                    result[result.count - 1] = last.join(cur)
                } else {
                    result.append(cur)
                }
            }
            diffs = result
            counter += 1
        } while counter <= 10 && shouldRepeat

        // Remove short suffixes/prefixes.
        var newDiffs: [SeqDiff] = []
        for i in diffs.indices {
            let prev = i > 0 ? diffs[i - 1] : nil
            let cur = diffs[i]
            let next = i + 1 < diffs.count ? diffs[i + 1] : nil
            var newDiff = cur
            func shouldMarkAsChanged(_ text: ArraySlice<Int32>) -> Bool {
                !text.isEmpty && JSText.trimmed(text).count <= 3 && cur.a.count + cur.b.count > 100
            }
            let full = s1.extendToFullLines(cur.a)
            let prefix = s1.elements[full.lowerBound..<cur.a.lowerBound]
            if shouldMarkAsChanged(prefix) { newDiff = newDiff.deltaStart(-prefix.count) }
            let suffix = s1.elements[cur.a.upperBound..<full.upperBound]
            if shouldMarkAsChanged(suffix) { newDiff = newDiff.deltaEnd(suffix.count) }

            let available = SeqDiff.between(prev?.ends ?? (0, 0), next?.starts ?? (Int.max, Int.max))
            guard let result = newDiff.intersect(available) else { continue }
            if let last = newDiffs.last, result.starts == last.ends {
                newDiffs[newDiffs.count - 1] = last.join(result)
            } else {
                newDiffs.append(result)
            }
        }
        return newDiffs
    }
}

/// JavaScript's notion of whitespace (`\s`, `String.prototype.trim`), on UTF-16 code units.
enum JSText {
    static func isWhitespace(_ u: Int32) -> Bool {
        switch u {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }

    static func trimmed(_ s: ArraySlice<Int32>) -> ArraySlice<Int32> {
        var lo = s.startIndex, hi = s.endIndex
        while lo < hi && isWhitespace(s[lo]) { lo += 1 }
        while hi > lo && isWhitespace(s[hi - 1]) { hi -= 1 }
        return s[lo..<hi]
    }
}
