/// Line diff between two versions of a file.
public enum LineDiff {
    /// Lines longer than this get no word-level highlights (minified files).
    static let maxWordDiffLineLength = 2_000

    public static func hunks(head: TextLines, work: TextLines, wordChanges: Bool = true) -> [Hunk] {
        // Intern each distinct line (by bytes) to an integer, so the diff compares ints.
        var ids: [[UInt8]: Int] = [:]
        func id(_ line: Line) -> Int {
            let k = line.key
            if let v = ids[k] { return v }
            ids[k] = ids.count
            return ids.count - 1
        }
        let a = head.lines.map(id), b = work.lines.map(id)
        let diff = b.difference(from: a)
        var removed = [Bool](repeating: false, count: a.count)
        var inserted = [Bool](repeating: false, count: b.count)
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed[offset] = true
            case .insert(let offset, _, _): inserted[offset] = true
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            let iChanged = i < a.count && removed[i]
            let jChanged = j < b.count && inserted[j]
            if !iChanged && !jChanged { i += 1; j += 1; continue }
            let si = i, sj = j
            while (i < a.count && removed[i]) || (j < b.count && inserted[j]) {
                if i < a.count && removed[i] { i += 1 } else { j += 1 }
            }
            var hunk = Hunk(id: hunks.count, head: si..<i, work: sj..<j)
            if wordChanges { hunk.wordChanges = words(hunk, head: head, work: work) }
            hunks.append(hunk)
        }
        return hunks
    }

    /// Pairs changed lines one-to-one by position and finds the changed columns in each pair.
    static func words(_ h: Hunk, head: TextLines, work: TextLines) -> [WordChange] {
        var out: [WordChange] = []
        for k in 0..<min(h.head.count, h.work.count) {
            let hl = h.head.lowerBound + k, wl = h.work.lowerBound + k
            let x = Array(head.lines[hl].text.utf16), y = Array(work.lines[wl].text.utf16)
            guard x.count <= maxWordDiffLineLength, y.count <= maxWordDiffLineLength, x != y else { continue }
            let d = y.difference(from: x)
            var xs: [Int] = [], ys: [Int] = []
            for c in d {
                switch c {
                case .remove(let o, _, _): xs.append(o)
                case .insert(let o, _, _): ys.append(o)
                }
            }
            out.append(WordChange(headLine: hl, workLine: wl, headCols: ranges(xs), workCols: ranges(ys)))
        }
        return out
    }

    /// Merges sorted offsets into contiguous ranges.
    static func ranges(_ offsets: [Int]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for o in offsets.sorted() {
            if let last = out.last, last.upperBound == o { out[out.count - 1] = last.lowerBound..<(o + 1) }
            else { out.append(o..<(o + 1)) }
        }
        return out
    }
}
