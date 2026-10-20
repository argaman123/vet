import AppKit
import VetCore

/// The enclosing class and function lines pinned at the top of a code pane while you scroll,
/// as WebStorm and VS Code show them. Clicking one scrolls to it.
final class StickyLinesView: NSView {
    var onClick: ((Int) -> Void)?
    /// Horizontal scroll of the pane, so pinned lines move with the code.
    var scrollX: CGFloat = 0 { didSet { if oldValue != scrollX { needsDisplay = true } } }
    /// Width of a line-number gutter the view covers (0 when it covers code only); pinned rows
    /// show their own line numbers there.
    var gutterWidth: CGFloat = 0
    /// Display line → the number to show (nil hides it), for panes whose rows aren't file lines.
    var number: (Int) -> Int? = { $0 + 1 }
    private(set) var rows: [(line: Int, text: NSAttributedString)] = []
    /// Solid space above the rows, reaching up to the floating header's glass so no sliver of
    /// code shows between them.
    var lead: CGFloat = 0 { didSet { if oldValue != lead { needsDisplay = true } } }
    /// One dim line on a soft fade, without numbers or a solid band.
    var quiet = false { didSet { if oldValue != quiet { needsDisplay = true } } }
    /// Below the rows the code fades in over this much, instead of a hard edge.
    static let tail: CGFloat = 12
    /// The gap the floating header leaves under its glass.
    static let glassGap: CGFloat = 6

    override var isFlipped: Bool { true }

    func show(_ rows: [(line: Int, text: NSAttributedString)]) {
        let changed = rows.map(\.line) != self.rows.map(\.line)
        self.rows = rows
        isHidden = rows.isEmpty
        if changed { needsDisplay = true }
    }

    var height: CGFloat { rows.isEmpty ? 0 : lead + CGFloat(rows.count) * DiffTheme.lineHeight + Self.tail }

    override func draw(_ dirtyRect: NSRect) {
        // Opaque even when the code is a translucent veil, so the lines scrolled under don't show
        // through; the code then fades in below instead of meeting a line.
        let bg = DiffTheme.background.withAlphaComponent(1)
        let solid = lead + CGFloat(rows.count) * DiffTheme.lineHeight
        bg.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: solid).fill()
        NSGradient(starting: bg, ending: bg.withAlphaComponent(0))?.draw(in: NSRect(x: 0, y: solid, width: bounds.width, height: Self.tail), angle: 90)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: gutterWidth, y: 0, width: bounds.width - gutterWidth, height: bounds.height)).addClip()
        for (i, row) in rows.enumerated() {
            row.text.draw(at: NSPoint(x: gutterWidth + DiffTheme.inset.width - scrollX, y: lead + CGFloat(i) * DiffTheme.lineHeight))
        }
        NSGraphicsContext.restoreGraphicsState()
        if quiet { // the line recedes: a veil of the background over it
            bg.withAlphaComponent(0.45).setFill()
            NSRect(x: 0, y: lead, width: bounds.width, height: CGFloat(rows.count) * DiffTheme.lineHeight).fill()
        }
        if gutterWidth > 0, !quiet {
            let attrs: [NSAttributedString.Key: Any] = [.font: DiffTheme.numberFont, .foregroundColor: DiffTheme.lineNumber]
            for (i, row) in rows.enumerated() {
                guard let n = number(row.line) else { continue }
                let s = NSAttributedString(string: "\(n)", attributes: attrs)
                let size = s.size()
                s.draw(at: NSPoint(x: (gutterWidth == LineNumberGutter.width ? LineNumberGutter.numbersRight : gutterWidth - 8) - size.width, y: lead + CGFloat(i) * DiffTheme.lineHeight + (DiffTheme.lineHeight - size.height) / 2))
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y - lead
        let i = y < 0 ? -1 : Int(y / DiffTheme.lineHeight)
        if i >= 0, i < rows.count { onClick?(rows[i].line) }
    }

    override func resetCursorRects() { addCursorRect(NSRect(x: 0, y: lead, width: bounds.width, height: CGFloat(rows.count) * DiffTheme.lineHeight), cursor: .pointingHand) }

    /// The pinned rows for a pane whose first visible display line is `first`: up to `max`
    /// enclosing declarations whose own line is already scrolled past.
    static func rows(in storage: NSTextStorage, first: Int, max limit: Int = 3) -> [(line: Int, text: NSAttributedString)] {
        let ns = storage.string as NSString
        guard first > 0 else { return [] }
        // Line starts up to `first + limit` (pinned rows cover that many lines of the view).
        var starts: [Int] = [0]
        var loc = 0
        while starts.count <= first + limit {
            let r = ns.range(of: "\n", options: .literal, range: NSRange(location: loc, length: ns.length - loc))
            if r.location == NSNotFound { break }
            loc = NSMaxRange(r)
            starts.append(loc)
        }
        func lineText(_ i: Int) -> String {
            guard i < starts.count else { return "" }
            let end = i + 1 < starts.count ? starts[i + 1] - 1 : ns.length
            return ns.substring(with: NSRange(location: starts[i], length: max(0, end - starts[i])))
        }
        func indent(_ s: String) -> Int { s.prefix { $0 == " " || $0 == "\t" }.count }
        func isCode(_ i: Int) -> Bool {
            guard i < starts.count, starts[i] < ns.length else { return false }
            return storage.attribute(.vetFold, at: starts[i], effectiveRange: nil) == nil && storage.attribute(.vetNote, at: starts[i], effectiveRange: nil) == nil
                && storage.attribute(.vetRemoved, at: starts[i], effectiveRange: nil) == nil
        }
        var picked: [Int] = []
        var scan = first
        // The pinned block itself covers the first rows, so look below it as it grows.
        for _ in 0..<limit {
            var target = Swift.min(scan + picked.count, starts.count - 1)
            while target > 0, !isCode(target) || lineText(target).trimmingCharacters(in: .whitespaces).isEmpty { target -= 1 }
            var limitIndent = indent(lineText(target))
            var chain: [Int] = []
            var j = target - 1
            while j >= 0, limitIndent > 0 {
                let t = lineText(j)
                if isCode(j), !t.trimmingCharacters(in: .whitespaces).isEmpty, indent(t) < limitIndent {
                    limitIndent = indent(t)
                    if ScopeLabel.declaredName(t) != nil { chain.append(j) }
                }
                j -= 1
            }
            let newPicked = Array(chain.reversed().prefix(limit)).filter { $0 < first + chain.count }
            if newPicked == picked { break }
            picked = newPicked
            scan = first
        }
        return picked.map { i in
            let end = i + 1 < starts.count ? starts[i + 1] - 1 : ns.length
            return (i, storage.attributedSubstring(from: NSRange(location: starts[i], length: max(0, end - starts[i]))))
        }
    }
}
