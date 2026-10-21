import AppKit

/// The caret's shape in a code pane. Mods set it (a Vim mod shows a block in Normal mode); Vet
/// itself always uses the bar.
enum CaretStyle: String, Sendable { case bar, block, underline }

/// A block or underline caret: a layer that inverts what's under it, so the character in the
/// block stays readable in any theme. Sits above the text and never takes clicks.
final class CaretOverlay: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.82, alpha: 1).cgColor
        layer?.compositingFilter = "differenceBlendMode"
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension CodeTextView {
    /// Hides the system caret for a block or underline one (drawn by `caretOverlay`).
    func applyCaretStyle() {
        insertionPointColor = caretStyle == .bar ? DiffTheme.text : .clear
        updateCaretOverlay()
    }

    /// Moves the block or underline caret to the insertion point (hidden for a selection, an
    /// unfocused pane or the bar caret).
    func updateCaretOverlay() {
        let r = selectedRange()
        let focused = window?.firstResponder === self && (window?.isKeyWindow == true || SnapshotHook.isTesting) // tests run in the background
        guard caretStyle != .bar, r.length == 0, focused, let storage = textStorage else {
            caretOverlay?.isHidden = true
            return
        }
        let overlay = caretOverlay ?? {
            let o = CaretOverlay(frame: .zero)
            addSubview(o)
            caretOverlay = o
            return o
        }()
        let ns = storage.string as NSString
        let width = ("0" as NSString).size(withAttributes: [.font: DiffTheme.font]).width
        let onCharacter = r.location < ns.length && ns.character(at: r.location) != 10
        let x: CGFloat
        var w = width
        if onCharacter, let f = segmentFrame(NSRange(location: r.location, length: 1)) {
            x = f.minX
            w = max(width, f.width)
        } else if r.location > 0, let f = segmentFrame(NSRange(location: r.location - 1, length: 1)), ns.character(at: r.location - 1) != 10 {
            x = f.maxX // the end of a line: just after its last character
        } else {
            x = textContainerOrigin.x // an empty line
        }
        let line = displayLines(of: NSRange(location: r.location, length: 0)).lowerBound
        let row = NSRect(x: x, y: y(ofLine: line), width: w, height: DiffTheme.lineHeight)
        overlay.frame = caretStyle == .block ? row : NSRect(x: row.minX, y: row.maxY - 2, width: w, height: 2)
        overlay.isHidden = false
    }
}

extension CodeTextView {
    /// A mod's marked ranges (see `modMarks`), in Find's match color.
    func drawModMarks(in rect: NSRect) {
        DiffTheme.searchMatch.setFill()
        for r in modMarks {
            guard let f = segmentFrame(r), f.intersects(rect) else { continue }
            let line = self.line(at: NSPoint(x: f.minX, y: f.midY))
            NSBezierPath(roundedRect: NSRect(x: f.minX, y: y(ofLine: line), width: max(2, f.width), height: DiffTheme.lineHeight), xRadius: 2, yRadius: 2).fill()
        }
    }
}
