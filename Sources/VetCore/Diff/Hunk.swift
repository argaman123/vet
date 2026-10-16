/// One changed section: `head` lines in the old file become `work` lines in the new one.
/// An empty range means a pure insertion (empty `head`) or a pure deletion (empty `work`).
public struct Hunk: Sendable, Hashable, Identifiable {
    public let id: Int
    public let head: Range<Int>
    public let work: Range<Int>
    /// Changed characters, keyed by absolute line number, as UTF-16 column ranges (for NSRange)
    /// within the line's text. Lines missing here have no character-level highlight.
    public var headCols: [Int: [Range<Int>]]
    public var workCols: [Int: [Range<Int>]]

    public init(id: Int, head: Range<Int>, work: Range<Int>,
                headCols: [Int: [Range<Int>]] = [:], workCols: [Int: [Range<Int>]] = [:]) {
        self.id = id
        self.head = head
        self.work = work
        self.headCols = headCols
        self.workCols = workCols
    }
}
