/// What each pane of the ribbon diff shows, line by line, after folding unchanged regions.
/// Every display line has the same height, so positions are simply `line × lineHeight`.
public struct DiffLayout: Sendable {
    public enum DisplayLine: Sendable, Hashable {
        /// A real file line (0-based).
        case code(Int)
        /// "⋯ N unchanged lines"; `id` is the region's first HEAD line.
        case fold(id: Int, hidden: Int)
    }

    public enum SegmentKind: Sendable, Hashable {
        case same
        case fold(id: Int)
        case hunk(id: Int)
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

    public init(headCount: Int, workCount: Int, hunks: [Hunk], folding: Bool, expanded: Set<Int>) {
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
            guard folding, !expanded.contains(h.lowerBound), hidden >= Self.minimumFold, !hunks.isEmpty else {
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
        self.left = left
        self.right = right
        self.segments = segments
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
