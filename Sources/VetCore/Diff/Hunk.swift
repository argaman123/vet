/// Changed columns inside a pair of lines, in UTF-16 units (for NSRange).
public struct WordChange: Sendable, Hashable {
    public let headLine: Int
    public let workLine: Int
    public let headCols: [Range<Int>]
    public let workCols: [Range<Int>]
}

/// One changed section: `head` lines in the old file become `work` lines in the new one.
/// An empty range means a pure insertion (empty `head`) or a pure deletion (empty `work`).
public struct Hunk: Sendable, Hashable, Identifiable {
    public let id: Int
    public let head: Range<Int>
    public let work: Range<Int>
    public var wordChanges: [WordChange]

    public init(id: Int, head: Range<Int>, work: Range<Int>, wordChanges: [WordChange] = []) {
        self.id = id
        self.head = head
        self.work = work
        self.wordChanges = wordChanges
    }
}
