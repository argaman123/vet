import CryptoKit
import Foundation

/// Section ("hunk") staging, done the way VS Code's git extension stages selected ranges:
///
/// - **Stage** a section: apply the index→working-file changes that touch it to the index.
/// - **Unstage** a section: revert the HEAD→index changes that touch it.
/// - A change with the same number of lines on both sides is applied line by line, only over
///   the section's own lines, so a neighbouring change is never swept along. An unequal change
///   is applied whole (its line correspondence is ambiguous).
///
/// The new index is always the CURRENT index with only those changes applied; nothing else in
/// it is touched. Whether a section counts as staged uses the same "touches" rule, so the
/// checkbox always agrees with what clicking it does.
public struct SectionStaging: Sendable {
    public let head: TextLines
    public let index: TextLines
    public let work: TextLines
    /// HEAD → working-file sections, in file order. These are what the diff shows.
    public let hunks: [Hunk]
    /// Changes when HEAD, the index or the working file changes; a click made against an
    /// older snapshot must be refused.
    public let snapshotID: String

    private let headToIndex: [Hunk]  // .head = HEAD lines, .work = index lines
    private let indexToWork: [Hunk]  // .head = index lines, .work = working-file lines

    public init(head: TextLines, index: TextLines, work: TextLines) {
        self.head = head
        self.index = index
        self.work = work
        hunks = LineDiff.hunks(head: head, work: work)
        // Staging slices same-size changes line by line, which needs the minimal line alignment:
        // a displayed hunk joined across a short unchanged gap doesn't pair up line by line.
        headToIndex = LineDiff.lineChanges(head: head, work: index)
        indexToWork = LineDiff.lineChanges(head: index, work: work)
        snapshotID = Self.snapshot(head: head.joined(), index: index.joined(), work: work.joined())
    }

    /// Identifies one combination of HEAD, index and working-file bytes.
    public static func snapshot(head: Data, index: Data, work: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: head)
        hasher.update(data: Data([0]))
        hasher.update(data: index)
        hasher.update(data: Data([0]))
        hasher.update(data: work)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func state(of hunk: Hunk) -> StageState {
        if !indexToWork.contains(where: { Self.touches(hunk.work, $0.work) }) { return .staged }
        if !headToIndex.contains(where: { Self.touches(hunk.head, $0.head) }) { return .unstaged }
        return .partial
    }

    /// The full new index text after staging (or unstaging) `hunk`.
    public func indexText(setting hunk: Hunk, staged: Bool) -> Data {
        var lines = index.lines
        if staged {
            // Index→work changes touching the section's working-file lines, applied to the index.
            for x in indexToWork.filter({ Self.touches(hunk.work, $0.work) }).reversed() {
                let (from, to) = Self.restrict(x.head, x.work, to: hunk.work)
                lines.replaceSubrange(from, with: work.lines[to])
            }
        } else {
            // HEAD→index changes touching the section's HEAD lines, reverted in the index.
            for x in headToIndex.filter({ Self.touches(hunk.head, $0.head) }).reversed() {
                let (headPart, indexPart) = Self.restrict(x.work, x.head, to: hunk.head)
                lines.replaceSubrange(headPart, with: head.lines[indexPart])
            }
        }
        return TextLines(lines: lines).joined()
    }

    /// Stages just these working-file lines (VS Code's "stage selected ranges"): the index→work
    /// changes touching them are applied, same-size ones only over the selected lines.
    public func indexText(stagingWorkLines selection: Range<Int>) -> Data {
        var lines = index.lines
        for x in indexToWork.filter({ Self.touches(selection, $0.work) }).reversed() {
            let (from, to) = Self.restrict(x.head, x.work, to: selection)
            lines.replaceSubrange(from, with: work.lines[to])
        }
        return TextLines(lines: lines).joined()
    }

    /// For a change `target ↔ source` (target is the side being rewritten, source supplies the
    /// new lines), the part that lies within `section` (a range on the source side). Same-size
    /// changes pair line by line; anything else is used whole.
    static func restrict(_ target: Range<Int>, _ source: Range<Int>, to section: Range<Int>) -> (Range<Int>, Range<Int>) {
        guard target.count == source.count, !section.isEmpty else { return (target, source) }
        let lo = max(source.lowerBound, section.lowerBound), hi = min(source.upperBound, section.upperBound)
        guard lo < hi else { return (target, source) }
        let offset = target.lowerBound - source.lowerBound
        return ((lo + offset)..<(hi + offset), lo..<hi)
    }

    /// Whether a change over `other` affects the lines in `range` (both on the same side).
    /// Overlapping lines always count. Where either side is a position between lines (an
    /// insertion or a deletion), changes right at its edges count too.
    static func touches(_ range: Range<Int>, _ other: Range<Int>) -> Bool {
        switch (range.isEmpty, other.isEmpty) {
        case (false, false): return range.overlaps(other)
        case (true, true): return range.lowerBound == other.lowerBound
        case (true, false): return other.lowerBound <= range.lowerBound && range.lowerBound <= other.upperBound
        case (false, true): return range.lowerBound <= other.lowerBound && other.lowerBound <= range.upperBound
        }
    }
}
