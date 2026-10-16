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

    enum Navigation { case definition, implementation, references }
    /// ⌘S while this pane has focus.
    var onSave: (() -> Void)?
    /// ⌘-click: go to definition at (display line, UTF-16 column).
    var onNavigate: ((Navigation, Int, Int) -> Void)?
    /// The right-click menu's items for (display line, column), above Copy. Nil keeps a minimal menu.
    var contextItems: ((Int, Int) -> [NSMenuItem])?

    static func make() -> (NSScrollView, CodeTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        // No automatic title-bar inset: line math (gutter, ribbons, note cards) assumes the
        // document starts at the top of the clip view.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
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
        if event.modifierFlags.contains(.command), let onNavigate, let pos = position(at: p) {
            onNavigate(.definition, pos.line, pos.character)
            return
        }
        super.mouseDown(with: event)
    }

    @objc func vetSave(_ sender: Any?) { onSave?() }


    /// A short, reviewer-only menu instead of the text system's long one.
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if let pos = position(at: p) {
            // Right-clicking outside the selection moves the caret there first, like other editors.
            let index = characterIndexForInsertion(at: p)
            if !NSLocationInRange(index, selectedRange()) || selectedRange().length == 0 { setSelectedRange(NSRange(location: index, length: 0)) }
            for item in contextItems?(pos.line, pos.character) ?? [] { menu.addItem(item) }
        }
        // Owners that give a full menu place Copy themselves; otherwise it's just Copy.
        if !menu.items.contains(where: { $0.action == #selector(NSText.copy(_:)) }) {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        }
        return menu
    }

    /// Display line and UTF-16 column of a point, nil past the end or on a fold row.
    func position(at point: NSPoint) -> (line: Int, character: Int)? {
        let index = characterIndexForInsertion(at: point)
        let ns = string as NSString
        guard index <= ns.length else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: min(index, max(0, ns.length - 1)), length: 0)).location
        var line = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: lineStart), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        if lineStart == ns.length, index == ns.length, ns.length > 0, ns.character(at: ns.length - 1) == 10 { line += 1 }
        guard foldLines[line] == nil else { return nil }
        return (line, index - lineStart)
    }

    /// Display lines covered by a character range (the selection).
    func displayLines(of range: NSRange) -> ClosedRange<Int> {
        let ns = string as NSString
        // The display line holding `index`: the newlines before it (the panes' rows are split on
        // "\n" only). Line enumeration can't do this: it reports a partly covered last line too.
        func lineOf(_ index: Int) -> Int {
            var n = 0, from = 0
            let end = min(index, ns.length)
            while from < end {
                let r = ns.range(of: "\n", options: .literal, range: NSRange(location: from, length: end - from))
                if r.location == NSNotFound { break }
                n += 1
                from = NSMaxRange(r)
            }
            return n
        }
        let a = lineOf(range.location)
        let end = range.length > 0 ? NSMaxRange(range) - 1 : range.location
        return a...max(a, lineOf(end))
    }

    /// The text range for (display line, column).
    func range(line: Int, character: Int) -> NSRange? {
        let ns = string as NSString
        var current = 0, location = 0
        while current < line {
            let r = ns.range(of: "\n", range: NSRange(location: location, length: ns.length - location))
            guard r.location != NSNotFound else { return nil }
            location = r.location + 1
            current += 1
        }
        let lineEnd = ns.lineRange(for: NSRange(location: location, length: 0))
        return NSRange(location: min(location + character, NSMaxRange(lineEnd)), length: 0)
    }

    /// Fold rows stand for hidden lines and note rows hold a card; neither can be edited, and
    /// neither can be merged into a neighbouring line (Backspace at a fold row's start, Delete at
    /// the end of the line above it).
    /// Each pane undoes only its own typing: panes outlive tab switches, and the window's shared
    /// undo stack would let ⌘Z in one tab change text in another you can't see.
    private let paneUndoManager = UndoManager()
    override var undoManager: UndoManager? { paneUndoManager }
    // NSWindow's own undo:/redo: would use the window's stack, so the pane answers them first.
    @objc func undo(_ sender: Any?) { paneUndoManager.undo() }
    @objc func redo(_ sender: Any?) { paneUndoManager.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case Selector(("undo:")):
            (item as? NSMenuItem)?.title = paneUndoManager.undoMenuItemTitle
            return isEditable && paneUndoManager.canUndo
        case Selector(("redo:")):
            (item as? NSMenuItem)?.title = paneUndoManager.redoMenuItemTitle
            return isEditable && paneUndoManager.canRedo
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        guard let storage = textStorage else { return super.shouldChangeText(in: range, replacementString: replacementString) }
        func protected(_ i: Int) -> Bool {
            guard i >= 0, i < storage.length else { return false }
            return storage.attribute(.vetFold, at: i, effectiveRange: nil) != nil || storage.attribute(.vetNote, at: i, effectiveRange: nil) != nil
        }
        var refuse = false
        if range.length == 0 {
            // Typing into a fold or note row, or onto its end (the last row has no newline after it).
            let at = range.location
            refuse = protected(at) || (protected(at - 1) && (string as NSString).character(at: at - 1) != 10)
        } else {
            for i in range.location..<NSMaxRange(range) where protected(i) { refuse = true; break }
            // Deleting a newline would pull the next line up: refuse if that line is protected.
            let removed = (string as NSString).substring(with: range)
            if !refuse && removed.contains("\n") && protected(NSMaxRange(range)) { refuse = true }
        }
        if refuse { NSSound.beep(); return false }
        return super.shouldChangeText(in: range, replacementString: replacementString)
    }


    override func resetCursorRects() {
        super.resetCursorRects()
        for (line, _) in foldLines {
            addCursorRect(NSRect(x: 0, y: y(ofLine: line), width: bounds.width, height: DiffTheme.lineHeight), cursor: .pointingHand)
        }
    }
}
