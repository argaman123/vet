import Dispatch

// A port of VS Code's sequence diff algorithms (microsoft/vscode,
// src/vs/editor/common/diff/defaultLinesDiffComputer/algorithms; MIT License,
// Copyright (c) Microsoft Corporation). Names follow the original where practical.

/// One difference between two sequences: elements `a` of sequence 1 became elements `b` of
/// sequence 2. An empty side is a pure insertion or deletion.
struct SeqDiff: Hashable {
    var a: Range<Int>
    var b: Range<Int>

    func delta(_ o: Int) -> SeqDiff {
        SeqDiff(a: (a.lowerBound + o)..<(a.upperBound + o), b: (b.lowerBound + o)..<(b.upperBound + o))
    }
    func deltaStart(_ o: Int) -> SeqDiff {
        SeqDiff(a: (a.lowerBound + o)..<a.upperBound, b: (b.lowerBound + o)..<b.upperBound)
    }
    func deltaEnd(_ o: Int) -> SeqDiff {
        SeqDiff(a: a.lowerBound..<(a.upperBound + o), b: b.lowerBound..<(b.upperBound + o))
    }
    func join(_ o: SeqDiff) -> SeqDiff { SeqDiff(a: a.hull(o.a), b: b.hull(o.b)) }
    func swapped() -> SeqDiff { SeqDiff(a: b, b: a) }
    /// Both sides intersect or touch; nil otherwise.
    func intersect(_ o: SeqDiff) -> SeqDiff? {
        guard let i1 = a.meet(o.a), let i2 = b.meet(o.b) else { return nil }
        return SeqDiff(a: i1, b: i2)
    }
    var starts: (Int, Int) { (a.lowerBound, b.lowerBound) }
    var ends: (Int, Int) { (a.upperBound, b.upperBound) }

    static func between(_ start: (Int, Int), _ end: (Int, Int)) -> SeqDiff {
        SeqDiff(a: start.0..<end.0, b: start.1..<end.1)
    }

    /// The equal stretches around `diffs` (VS Code's `SequenceDiff.invert`).
    static func invert(_ diffs: [SeqDiff], length1: Int) -> [SeqDiff] {
        var out: [SeqDiff] = []
        for i in 0...diffs.count {
            let prev = i == 0 ? nil : diffs[i - 1]
            let next = i == diffs.count ? nil : diffs[i]
            let start = prev?.ends ?? (0, 0)
            let end = next?.starts ?? (length1, (prev.map { $0.b.upperBound - $0.a.upperBound } ?? 0) + length1)
            out.append(between(start, end))
        }
        return out
    }
}

extension Range where Bound == Int {
    /// The smallest range covering both (OffsetRange.join).
    func hull(_ o: Range<Int>) -> Range<Int> { Swift.min(lowerBound, o.lowerBound)..<Swift.max(upperBound, o.upperBound) }
    /// The intersection, empty when the ranges only touch, nil when they are apart (OffsetRange.intersect).
    func meet(_ o: Range<Int>) -> Range<Int>? {
        let lo = Swift.max(lowerBound, o.lowerBound), hi = Swift.min(upperBound, o.upperBound)
        return lo <= hi ? lo..<hi : nil
    }
    /// Shares at least one element (OffsetRange.intersects).
    func intersectsStrictly(_ o: Range<Int>) -> Bool {
        Swift.max(lowerBound, o.lowerBound) < Swift.min(upperBound, o.upperBound)
    }
    /// Clamps both bounds to `0...count`.
    func clamped(toCount n: Int) -> Range<Int> { Swift.min(lowerBound, n)..<Swift.min(upperBound, n) }
}

/// A deadline that, once passed, stays passed (VS Code's `DateTimeout`).
final class DiffTimeout {
    private let end: UInt64
    private var expired = false

    init(seconds: Double) {
        end = DispatchTime.now().uptimeNanoseconds &+ UInt64(seconds * 1_000_000_000)
    }

    func isValid() -> Bool {
        if !expired && DispatchTime.now().uptimeNanoseconds >= end { expired = true }
        return !expired
    }
}

struct DiffAlgorithmResult {
    var diffs: [SeqDiff]
    /// The algorithm gave up; `diffs` is then the whole input as one change.
    var hitTimeout: Bool

    static func trivial(_ n: Int, _ m: Int, timedOut: Bool = false) -> DiffAlgorithmResult {
        DiffAlgorithmResult(diffs: [SeqDiff(a: 0..<n, b: 0..<m)], hitTimeout: timedOut)
    }
}

/// Myers' O(ND) diff, greedy forward variant with quadratic worst-case space
/// (VS Code's `MyersDiffAlgorithm`). `maxD` caps the edit distance explored: past it, or past
/// the deadline, the result is the trivial whole-input change.
enum MyersDiff {
    private struct Snake {
        var prev: Int32
        var x: Int32
        var y: Int32
        var length: Int32
    }

    static func compute(_ seqX: [Int32], _ seqY: [Int32], timeout: DiffTimeout, maxD: Int = .max) -> DiffAlgorithmResult {
        let n = seqX.count, m = seqY.count
        if n == 0 || m == 0 { return .trivial(n, m) }

        // Diagonals k = x - y stay within -(m + 1)...(n + 1) and within -d...d.
        let bound = Swift.min(Swift.max(n, m), maxD) + 3
        var v = [Int32](repeating: 0, count: 2 * bound + 1)
        var paths = [Int32](repeating: -1, count: 2 * bound + 1)
        var pool: [Snake] = []
        var k = 0
        var timedOut = false

        seqX.withUnsafeBufferPointer { xs in
            seqY.withUnsafeBufferPointer { ys in
                v.withUnsafeMutableBufferPointer { vb in
                    paths.withUnsafeMutableBufferPointer { pb in
                        @inline(__always) func xAfterSnake(_ x0: Int, _ y0: Int) -> Int {
                            var x = x0, y = y0
                            while x < n && y >= 0 && y < m && xs[x] == ys[y] { x += 1; y += 1 }
                            return x
                        }
                        let first = xAfterSnake(0, 0)
                        vb[bound] = Int32(first)
                        if first != 0 {
                            pool.append(Snake(prev: -1, x: 0, y: 0, length: Int32(first)))
                            pb[bound] = Int32(pool.count - 1)
                        }
                        // VS Code's snake paths are garbage-collected objects; here they live in
                        // `pool`, so drop the ones no diagonal can reach any more once it grows.
                        var compactAt = 1 << 20
                        func compact() {
                            var reachable = [Bool](repeating: false, count: pool.count)
                            for head in pb {
                                var p = Int(head)
                                while p >= 0 && !reachable[p] { reachable[p] = true; p = Int(pool[p].prev) }
                            }
                            var newIndex = [Int32](repeating: -1, count: pool.count)
                            var kept: [Snake] = []
                            for i in pool.indices where reachable[i] {
                                var s = pool[i]
                                if s.prev >= 0 { s.prev = newIndex[Int(s.prev)] }  // a snake's prev is older
                                newIndex[i] = Int32(kept.count)
                                kept.append(s)
                            }
                            for i in pb.indices where pb[i] >= 0 { pb[i] = newIndex[Int(pb[i])] }
                            pool = kept
                            compactAt = Swift.max(1 << 20, 2 * kept.count)
                        }
                        var d = 0
                        outer: while true {
                            d += 1
                            if d > maxD || !timeout.isValid() { timedOut = true; return }
                            if pool.count >= compactAt { compact() }
                            let lower = -Swift.min(d, m + d % 2)
                            let upper = Swift.min(d, n + d % 2)
                            k = lower
                            while k <= upper {
                                let top = k == upper ? -1 : Int(vb[bound + k + 1])  // insert a symbol from Y
                                let left = k == lower ? -1 : Int(vb[bound + k - 1]) + 1  // delete a symbol of X
                                let x = Swift.min(Swift.max(top, left), n)
                                let y = x - k
                                if x > n || y > m { k += 2; continue }
                                let newMaxX = xAfterSnake(x, y)
                                vb[bound + k] = Int32(newMaxX)
                                let lastPath = x == top ? pb[bound + k + 1] : pb[bound + k - 1]
                                if newMaxX != x {
                                    pool.append(Snake(prev: lastPath, x: Int32(x), y: Int32(y), length: Int32(newMaxX - x)))
                                    pb[bound + k] = Int32(pool.count - 1)
                                } else {
                                    pb[bound + k] = lastPath
                                }
                                if newMaxX == n && newMaxX - k == m { break outer }
                                k += 2
                            }
                        }
                    }
                }
            }
        }
        if timedOut { return .trivial(n, m, timedOut: true) }

        var path = paths[bound + k]
        var result: [SeqDiff] = []
        var lastX = n, lastY = m
        while true {
            let endX = path >= 0 ? Int(pool[Int(path)].x + pool[Int(path)].length) : 0
            let endY = path >= 0 ? Int(pool[Int(path)].y + pool[Int(path)].length) : 0
            if endX != lastX || endY != lastY {
                result.append(SeqDiff(a: endX..<lastX, b: endY..<lastY))
            }
            guard path >= 0 else { break }
            lastX = Int(pool[Int(path)].x)
            lastY = Int(pool[Int(path)].y)
            path = pool[Int(path)].prev
        }
        result.reverse()
        return DiffAlgorithmResult(diffs: result, hitTimeout: false)
    }
}

/// O(NM) LCS that scores each match, preferring long diagonals
/// (VS Code's `DynamicProgrammingDiffing`). `matchScore[j]`, when given, is the score of
/// matching element `j` of sequence 2; otherwise every match scores 1.
enum DynamicProgrammingDiff {
    static func compute(_ s1: [Int32], _ s2: [Int32], timeout: DiffTimeout, matchScore: [Double]? = nil) -> DiffAlgorithmResult {
        let n = s1.count, m = s2.count
        if n == 0 || m == 0 { return .trivial(n, m) }

        // Cell (i, j) is stored at i * m + j; every cell is written before it is read.
        let lcs = UnsafeMutablePointer<Double>.allocate(capacity: n * m)
        let directions = UnsafeMutablePointer<UInt8>.allocate(capacity: n * m)
        let lengths = UnsafeMutablePointer<Int32>.allocate(capacity: n * m)
        defer { lcs.deallocate(); directions.deallocate(); lengths.deallocate() }
        let scores = matchScore ?? [Double](repeating: 1, count: m)

        let completed = s1.withUnsafeBufferPointer { x in
            s2.withUnsafeBufferPointer { y in
                scores.withUnsafeBufferPointer { score in
                    for i in 0..<n {
                        if !timeout.isValid() { return false }
                        let xi = x[i]
                        let row = i * m
                        var vertical = 0.0  // lcs(i, j - 1)
                        for j in 0..<m {
                            let idx = row + j
                            let horizontal = i == 0 ? 0 : lcs[idx - m]
                            var best = horizontal > vertical ? horizontal : vertical
                            if xi == y[j] {
                                var extended = 0.0
                                var length: Int32 = 1
                                if i > 0 && j > 0 {
                                    let diagonal = idx - m - 1
                                    extended = lcs[diagonal]
                                    if directions[diagonal] == 3 {
                                        // Prefer consecutive diagonals.
                                        extended += Double(lengths[diagonal])
                                        length += lengths[diagonal]
                                    }
                                }
                                extended += score[j]
                                if extended >= best {
                                    best = extended
                                    lengths[idx] = length
                                    directions[idx] = 3
                                    lcs[idx] = best
                                    vertical = best
                                    continue
                                }
                            }
                            lengths[idx] = 0
                            directions[idx] = best == horizontal ? 1 : 2
                            lcs[idx] = best
                            vertical = best
                        }
                    }
                    return true
                }
            }
        }
        if !completed { return .trivial(n, m, timedOut: true) }

        var result: [SeqDiff] = []
        var lastI = n, lastJ = m
        func reportAligned(_ i: Int, _ j: Int) {
            if i + 1 != lastI || j + 1 != lastJ {
                result.append(SeqDiff(a: (i + 1)..<lastI, b: (j + 1)..<lastJ))
            }
            lastI = i
            lastJ = j
        }
        var i = n - 1, j = m - 1
        while i >= 0 && j >= 0 {
            switch directions[i * m + j] {
            case 3: reportAligned(i, j); i -= 1; j -= 1
            case 1: i -= 1
            default: j -= 1
            }
        }
        reportAligned(-1, -1)
        result.reverse()
        return DiffAlgorithmResult(diffs: result, hitTimeout: false)
    }
}
