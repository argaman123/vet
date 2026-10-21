import AppKit

/// Line numbers beside a single code pane; follows the pane's scrolling.
final class LineNumberGutter: NSView {
    /// Display line → file line (0-based), nil for rows without a number.
    var numbers: [Int?] = [] { didSet { needsDisplay = true } }
    var offset: CGFloat = 0 { didSet { needsDisplay = true; if !marks.isEmpty || !changeBars.isEmpty { window?.invalidateCursorRects(for: self) } } } // icons move with the text
    /// File line to emphasize (0-based), e.g. after jumping to a definition.
    var highlighted: Int? { didSet { needsDisplay = true } }
    /// Jump icons by display line: this overrides something (up) or is implemented/overridden (down).
    var marks: [Int: JumpMark] = [:] { didSet { if oldValue != marks { needsDisplay = true } } }
    var onMarkClick: ((Int, JumpMark, NSRect) -> Void)?
    /// What changed since the last commit, as JetBrains IDEs show it: a green bar beside new
    /// lines, a blue one beside modified lines, a small mark where lines were removed.
    var changeBars: [ChangeBar] = [] { didSet { if oldValue != changeBars { needsDisplay = true; window?.invalidateCursorRects(for: self) } } }
    var onChangeBarClick: ((ChangeBar, NSRect) -> Void)?
    static let width: CGFloat = 66
    /// Where line numbers end; the jump icons sit to their right, as in WebStorm.
    static let numbersRight: CGFloat = 42

    enum JumpMark: Equatable {
        case overrides, implemented
        var symbol: String { self == .overrides ? "arrow.up.circle" : "arrow.down.circle" }
        var help: String { self == .overrides ? "Go to the overridden declaration" : "Go to implementations" }
    }

    struct ChangeBar: Equatable {
        /// The file's lines now (empty where lines were only removed: they were above `lines.lowerBound`).
        let lines: Range<Int>
        /// What those lines were in the last commit.
        let old: [String]
        let oldStart: Int
        var kind: DiffTheme.Change { old.isEmpty ? .inserted : lines.isEmpty ? .deleted : .modified }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        DiffTheme.gutter.setFill()
        bounds.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: DiffTheme.numberFont, .foregroundColor: DiffTheme.lineNumber]
        let strong: [NSAttributedString.Key: Any] = [.font: DiffTheme.numberFont, .foregroundColor: DiffTheme.lineNumberCurrent]
        let first = max(0, Int((offset - DiffTheme.inset.height) / DiffTheme.lineHeight))
        let count = Int(bounds.height / DiffTheme.lineHeight) + 2
        for i in first..<max(first, min(numbers.count, first + count)) {
            guard let n = numbers[i] else { continue }
            let s = NSAttributedString(string: "\(n + 1)", attributes: n == highlighted ? strong : attrs)
            let size = s.size()
            let y = DiffTheme.inset.height + CGFloat(i) * DiffTheme.lineHeight - offset
            s.draw(at: NSPoint(x: Self.numbersRight - size.width, y: y + (DiffTheme.lineHeight - size.height) / 2))
        }
        for bar in changeBars where bar.lines.upperBound >= first && bar.lines.lowerBound <= first + count {
            let r = barRect(bar)
            switch bar.kind {
            case .inserted: DiffTheme.added.setFill(); NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
            case .modified: DiffTheme.modified.setFill(); NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
            case .deleted:
                // A small wedge on the line between the lines that stayed, pointing into the code.
                let t = NSBezierPath()
                t.move(to: NSPoint(x: r.minX, y: r.midY - 3.5))
                t.line(to: NSPoint(x: r.maxX, y: r.midY))
                t.line(to: NSPoint(x: r.minX, y: r.midY + 3.5))
                t.close()
                DiffTheme.removed.setFill()
                t.fill()
            }
        }
        for (line, mark) in marks where line >= first && line < first + count {
            guard let image = RibbonGutterView.markImage(mark) else { continue } // the same icons as the diff
            image.draw(in: iconRect(line, image.size))
        }
    }

    private func iconRect(_ line: Int, _ size: NSSize = NSSize(width: 13, height: 13)) -> NSRect {
        let y = DiffTheme.inset.height + CGFloat(line) * DiffTheme.lineHeight - offset
        return NSRect(x: Self.numbersRight + 6, y: y + (DiffTheme.lineHeight - size.height) / 2, width: size.width, height: size.height)
    }

    /// The bar beside a change's lines, between the icons and the code.
    private func barRect(_ bar: ChangeBar) -> NSRect {
        let top = DiffTheme.inset.height + CGFloat(bar.lines.lowerBound) * DiffTheme.lineHeight - offset
        if bar.lines.isEmpty { return NSRect(x: Self.width - 6, y: top - 4, width: 5, height: 8) }
        return NSRect(x: Self.width - 5, y: top + 1, width: 3, height: CGFloat(bar.lines.count) * DiffTheme.lineHeight - 2)
    }

    /// Where a bar takes clicks: a little wider than it is drawn.
    private func barHitRect(_ bar: ChangeBar) -> NSRect {
        let r = barRect(bar)
        return NSRect(x: Self.width - 8, y: r.minY - (bar.lines.isEmpty ? 0 : 1), width: 8, height: r.height + (bar.lines.isEmpty ? 0 : 2))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let line = Int(floor((p.y + offset - DiffTheme.inset.height) / DiffTheme.lineHeight))
        if let mark = marks[line], iconRect(line).insetBy(dx: -4, dy: -3).contains(p) { return onMarkClick?(line, mark, iconRect(line)) ?? () }
        if let bar = changeBars.first(where: { barHitRect($0).contains(p) }) { return onChangeBarClick?(bar, barRect(bar)) ?? () }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        for line in marks.keys { addCursorRect(iconRect(line).insetBy(dx: -4, dy: -3), cursor: .pointingHand) }
        for bar in changeBars {
            let r = barHitRect(bar)
            if r.maxY >= 0 && r.minY <= bounds.height { addCursorRect(r, cursor: .pointingHand) }
        }
    }

    func debugClickBar(_ n: Int) { onChangeBarClick?(changeBars[n], barRect(changeBars[n])) }
}
