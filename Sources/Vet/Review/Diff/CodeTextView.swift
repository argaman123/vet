import AppKit
import VetCore

/// One read-only pane of the diff: TextKit 2, no wrapping, a fixed 18-pt line height so every
/// display line sits at `inset + line × 18`. Draws full-width section backgrounds and fold bands.
final class CodeTextView: NSTextView {
    struct Band { let lines: Range<Int>; let color: NSColor }
    /// Full-width line backgrounds (sections, folds).
    var bands: [Band] = [] { didSet { needsDisplay = true } }
    /// Thin markers where the other side has lines this side doesn't (pure insertions/deletions).
    var markers: [(line: Int, color: NSColor)] = [] { didSet { needsDisplay = true } }
    var foldLines: [Int: Int] = [:] // display line → fold id
    var onFoldClick: ((Int) -> Void)?

    static func make() -> (NSScrollView, CodeTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = DiffTheme.background
        let tv = CodeTextView(usingTextLayoutManager: true)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = true
        tv.backgroundColor = DiffTheme.background
        tv.textColor = DiffTheme.text
        tv.font = DiffTheme.font
        tv.textContainerInset = DiffTheme.inset
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.lineFragmentPadding = 0
        tv.selectedTextAttributes = [.backgroundColor: DiffTheme.hex(0x264f78)]
        tv.insertionPointColor = DiffTheme.text
        tv.usesFindBar = true
        scroll.documentView = tv
        return (scroll, tv)
    }

    static var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = DiffTheme.lineHeight
        p.maximumLineHeight = DiffTheme.lineHeight
        return p
    }

    func y(ofLine line: Int) -> CGFloat { textContainerInset.height + CGFloat(line) * DiffTheme.lineHeight }

    func line(at point: NSPoint) -> Int { Int(floor((point.y - textContainerInset.height) / DiffTheme.lineHeight)) }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let width = max(bounds.width, enclosingScrollView?.contentSize.width ?? 0)
        for band in bands {
            let r = NSRect(x: 0, y: y(ofLine: band.lines.lowerBound), width: width,
                           height: CGFloat(band.lines.count) * DiffTheme.lineHeight)
            guard r.intersects(rect) else { continue }
            band.color.setFill()
            r.fill()
        }
        for m in markers {
            let r = NSRect(x: 0, y: y(ofLine: m.line) - 1, width: width, height: 2)
            guard r.intersects(rect) else { continue }
            m.color.withAlphaComponent(0.8).setFill()
            r.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let id = foldLines[line(at: p)] {
            onFoldClick?(id)
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for (line, _) in foldLines {
            addCursorRect(NSRect(x: 0, y: y(ofLine: line), width: bounds.width, height: DiffTheme.lineHeight), cursor: .pointingHand)
        }
    }
}
