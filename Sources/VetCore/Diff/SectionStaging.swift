import CryptoKit
import Foundation

/// Section ("hunk") staging: which HEAD→work sections are in the index, and the exact new
/// index text for staging or unstaging one section.
///
/// The new index is always built from the CURRENT index bytes, replacing only the section's
/// region. Index content outside every section — e.g. a change that was staged and later
/// reverted in the working file — is never touched.
public struct SectionStaging: Sendable {
    public let head: TextLines
    public let index: TextLines
    public let work: TextLines
    /// HEAD → working-file sections, in file order.
    public let hunks: [Hunk]
    /// Changes when HEAD, the index or the working file changes; a click made against an
    /// older snapshot must be refused.
    public let snapshotID: String

    private let regions: [Region]

    struct Region {
        var headSpan: Range<Int>
        var indexSpan: Range<Int>
        var workSpan: Range<Int>
    }

    public init(head: TextLines, index: TextLines, work: TextLines) {
        self.head = head
        self.index = index
        self.work = work
        let hw = LineDiff.hunks(head: head, work: work)
        let hi = LineDiff.hunks(head: head, work: index, wordChanges: false)
        hunks = hw
        let toIndex = PositionMap(hunks: hi), toWork = PositionMap(hunks: hw)
        regions = hw.map { h in
            // Widen the section when an index change straddles its edges.
            let a = toIndex.enclosing(h.head.lowerBound)?.head.lowerBound ?? h.head.lowerBound
            let b = toIndex.enclosing(h.head.upperBound)?.head.upperBound ?? h.head.upperBound
            let a2 = toWork.enclosing(a)?.head.lowerBound ?? a
            let b2 = toWork.enclosing(b)?.head.upperBound ?? b
            return Region(headSpan: a2..<b2,
                          indexSpan: toIndex.map(a2, after: false)..<toIndex.map(b2, after: true),
                          workSpan: toWork.map(a2, after: false)..<toWork.map(b2, after: true))
        }
        var hasher = SHA256()
        hasher.update(data: head.joined())
        hasher.update(data: Data([0]))
        hasher.update(data: index.joined())
        hasher.update(data: Data([0]))
        hasher.update(data: work.joined())
        snapshotID = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func state(of hunk: Hunk) -> StageState {
        guard let r = region(hunk) else { return .unstaged }
        let idx = index[r.indexSpan].map(\.key)
        if idx == work[r.workSpan].map(\.key) { return .staged }
        if idx == head[r.headSpan].map(\.key) { return .unstaged }
        return .partial
    }

    /// The full new index text after staging (or unstaging) `hunk`.
    public func indexText(setting hunk: Hunk, staged: Bool) -> Data {
        guard let r = region(hunk) else { return index.joined() }
        let replacement = staged ? Array(work[r.workSpan]) : Array(head[r.headSpan])
        let lines = Array(index.lines[0..<r.indexSpan.lowerBound]) + replacement
            + Array(index.lines[r.indexSpan.upperBound..<index.count])
        return TextLines(lines: lines).joined()
    }

    private func region(_ hunk: Hunk) -> Region? {
        guard let k = hunks.firstIndex(where: { $0.id == hunk.id }) else { return nil }
        return regions[k]
    }
}

/// Maps line positions (between lines) from a diff's HEAD side to its other side.
struct PositionMap {
    let hunks: [Hunk]

    /// The hunk whose HEAD range strictly contains position `p`, if any.
    func enclosing(_ p: Int) -> Hunk? {
        hunks.first { $0.head.lowerBound < p && p < $0.head.upperBound }
    }

    /// Other-side position for HEAD position `p`. At a hunk's edge, `after` picks the far side
    /// of that hunk, so a section's start maps before neighbouring inserted lines and its end after them.
    func map(_ p: Int, after: Bool) -> Int {
        var delta = 0
        for h in hunks {
            if p < h.head.lowerBound { break }
            if h.head.isEmpty && p == h.head.lowerBound {
                // Lines inserted right at p: a section's start goes before them, its end after them.
                return after ? h.work.upperBound : h.work.lowerBound
            }
            if p == h.head.lowerBound { return h.work.lowerBound }
            if p < h.head.upperBound { return h.work.lowerBound } // inside a hunk; callers widen first
            if p == h.head.upperBound { return h.work.upperBound }
            delta = h.work.upperBound - h.head.upperBound
        }
        return p + delta
    }
}
