/// What each pane of the ribbon diff shows, line by line, after folding unchanged regions.
/// Every display line has the same height, so positions are simply `line × lineHeight`.
public struct DiffLayout: Sendable {
    public enum DisplayLine: Sendable, Hashable {
        /// A real file line (0-based).
        case code(Int)
        /// "⋯ N unchanged lines"; `id` is the region's first HEAD line.
        case fold(id: Int, hidden: Int)
        /// One row of space for a review note shown under a line (both sides get the rows).
        case note(id: String, row: Int)
    }

    /// A review note to show under a file line: `left` means a HEAD line, else a working-file line.
    public struct NoteAnchor: Sendable, Hashable {
        public let id: String
        public let left: Bool
        public let line: Int
        public let rows: Int
        public init(id: String, left: Bool, line: Int, rows: Int) {
            self.id = id; self.left = left; self.line = line; self.rows = rows
        }
    }

    public enum SegmentKind: Sendable, Hashable {
        case same
        case fold(id: Int)
        case hunk(id: Int)
        case note(id: String)
    }

    /// A stretch shown side by side: `left` and `right` are display-line ranges.
    public struct Segment: Sendable, Hashable {
        public let left: Range<Int>
        public let right: Range<Int>
        public let kind: SegmentKind
    }

    public let left: [DisplayLine]
    public let right: [DisplayLine]
    public let segments: [Segment]
    /// The file lines each fold hides, by fold id (HEAD side and working-file side).
    public let foldHead: [Int: Range<Int>]
    public let foldWork: [Int: Range<Int>]

    /// IntelliJ's defaults: 4 lines of context around each change.
    public static let context = 4
    public static let minimumFold = 4

    public init(headCount: Int, workCount: Int, hunks: [Hunk], folding: Bool, expanded: Set<Int>, notes: [NoteAnchor] = []) {
        var left: [DisplayLine] = [], right: [DisplayLine] = [], segments: [Segment] = []
        var foldHead: [Int: Range<Int>] = [:], foldWork: [Int: Range<Int>] = [:]
        func same(_ h: Range<Int>, _ w: Range<Int>) {
            guard !h.isEmpty else { return }
            let l = left.count, r = right.count
            left += h.map { .code($0) }
            right += w.map { .code($0) }
            segments.append(Segment(left: l..<left.count, right: r..<right.count, kind: .same))
        }
        var hp = 0, wp = 0
        let blocks: [(Range<Int>, Range<Int>, Hunk?)] = hunks.flatMap { h -> [(Range<Int>, Range<Int>, Hunk?)] in
            defer { hp = h.head.upperBound; wp = h.work.upperBound }
            return [(hp..<h.head.lowerBound, wp..<h.work.lowerBound, nil), (h.head, h.work, h)]
        } + [(hp..<headCount, wp..<workCount, nil)]
        for (k, (h, w, hunk)) in blocks.enumerated() {
            if let hunk {
                let l = left.count, r = right.count
                left += h.map { .code($0) }
                right += w.map { .code($0) }
                segments.append(Segment(left: l..<left.count, right: r..<right.count, kind: .hunk(id: hunk.id)))
                continue
            }
            let n = h.count
            let isFirst = k == 0, isLast = k == blocks.count - 1
            let keepTop = isFirst ? 0 : Self.context
            let keepBottom = isLast ? 0 : Self.context
            let hidden = n - keepTop - keepBottom
            // A note's line is never folded away. (Only asked when there's room for a fold:
            // a stretch shorter than its two context margins has no hidden range at all.)
            let hidesNote = hidden >= Self.minimumFold && notes.contains { a in
                a.left ? (h.lowerBound + keepTop..<h.upperBound - keepBottom).contains(a.line)
                       : (w.lowerBound + keepTop..<w.upperBound - keepBottom).contains(a.line)
            }
            guard folding, !expanded.contains(h.lowerBound), hidden >= Self.minimumFold, !hunks.isEmpty, !hidesNote else {
                same(h, w)
                continue
            }
            same(h.lowerBound..<(h.lowerBound + keepTop), w.lowerBound..<(w.lowerBound + keepTop))
            let l = left.count, r = right.count
            left.append(.fold(id: h.lowerBound, hidden: hidden))
            right.append(.fold(id: h.lowerBound, hidden: hidden))
            foldHead[h.lowerBound] = (h.lowerBound + keepTop)..<(h.upperBound - keepBottom)
            foldWork[h.lowerBound] = (w.lowerBound + keepTop)..<(w.upperBound - keepBottom)
            segments.append(Segment(left: l..<(l + 1), right: r..<(r + 1), kind: .fold(id: h.lowerBound)))
            same((h.upperBound - keepBottom)..<h.upperBound, (w.upperBound - keepBottom)..<w.upperBound)
        }
        // Notes: split the stretch holding each note's line just below it, and give both sides
        // the note's rows there (in a changed section, the rows go under the whole section).
        if notes.isEmpty {
            self.left = left
            self.right = right
            self.segments = segments
        } else {
            var outL: [DisplayLine] = [], outR: [DisplayLine] = [], outS: [Segment] = []
            func emit(_ l: ArraySlice<DisplayLine>, _ r: ArraySlice<DisplayLine>, _ kind: SegmentKind) {
                let a = outL.count, b = outR.count
                outL += l
                outR += r
                outS.append(Segment(left: a..<outL.count, right: b..<outR.count, kind: kind))
            }
            func emitNote(_ n: NoteAnchor) {
                let rows = (0..<max(1, n.rows)).map { DisplayLine.note(id: n.id, row: $0) }
                emit(rows[...], rows[...], .note(id: n.id))
            }
            func lineAt(_ d: DisplayLine) -> Int? { if case .code(let l) = d { l } else { nil } }
            for seg in segments {
                let l = left[seg.left], r = right[seg.right]
                let inside = notes.filter { a in (a.left ? l : r).contains { lineAt($0) == a.line } }
                guard !inside.isEmpty else { emit(l, r, seg.kind); continue }
                if case .same = seg.kind {
                    // Equal stretches line up one to one: cut right under each note's line.
                    var start = 0
                    let cuts = inside.map { a -> (Int, NoteAnchor) in
                        let side = a.left ? l : r
                        return (side.firstIndex { lineAt($0) == a.line }! - side.startIndex + 1, a)
                    }.sorted { $0.0 < $1.0 }
                    for (cut, a) in cuts {
                        if cut > start { emit(l.dropFirst(start).prefix(cut - start), r.dropFirst(start).prefix(cut - start), .same) }
                        emitNote(a)
                        start = cut
                    }
                    if start < l.count { emit(l.dropFirst(start), r.dropFirst(start), .same) }
                } else {
                    emit(l, r, seg.kind)
                    inside.forEach(emitNote)
                }
            }
            self.left = outL
            self.right = outR
            self.segments = outS
        }
        self.foldHead = foldHead
        self.foldWork = foldWork
    }

    /// Maps a (fractional) display-line position from one side to the other.
    public func map(_ position: Double, fromLeft: Bool) -> Double {
        for s in segments {
            let from = fromLeft ? s.left : s.right, to = fromLeft ? s.right : s.left
            let end = Double(from.upperBound)
            if position < end || s == segments.last {
                let f = from.isEmpty ? 0 : (position - Double(from.lowerBound)) / Double(from.count)
                return Double(to.lowerBound) + max(0, min(1, f)) * Double(to.count)
            }
        }
        return position
    }
}
