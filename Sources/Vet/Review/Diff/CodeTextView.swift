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

    /// `usagesOrDeclaration` (force click): the usages, or the declaration when it has none.
    enum Navigation { case definition, implementation, references, usagesOrDeclaration }
    /// ⌘S while this pane has focus.
    var onSave: (() -> Void)?
    /// ⌘-click: go to definition at (display line, UTF-16 column).
    var onNavigate: ((Navigation, Int, Int) -> Void)?
    /// The right-click menu's items for (display line, column), above Copy. Nil keeps a minimal menu.
    var contextItems: ((Int, Int) -> [NSMenuItem])?
    /// The pointer rested on a symbol at (display line, column): the owner asks the language
    /// server and answers with `HoverPresenter.shared.show`.
    var onHover: ((Int, Int) -> Void)?
    private var hoverWork: DispatchWorkItem?
    /// Inline hints and end-of-line lenses (see CodeDecorations.swift).
    var inlayHints: [InlayHintMark] = [] { didSet { if oldValue != inlayHints { applyHintGaps() } } }
    var lenses: [LineLensMark] = [] { didSet { if oldValue != lenses { needsDisplay = true } } }
    var onLensClick: ((LineLensMark) -> Void)?
    var lensRects: [(NSRect, LineLensMark)] = []
    /// Pinch accumulated toward the next text-size step.
    var pinch: CGFloat = 0
    private var lastPressureStage = 0
    private var forceClicked = false
    /// The fold row under the pointer (drawn lit, with a hand cursor).
    var hoveredFoldLine: Int? { didSet { if oldValue != hoveredFoldLine { needsDisplay = true } } }
    private var hoverTracking: NSTrackingArea?

    static func make() -> (NSScrollView, CodeTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        // Overlay scroll bars, as IntelliJ's editors have: a legacy bar's track would cut every
        // row's background short of the pane's edge.
        scroll.scrollerStyle = .overlay
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
        tv.selectedTextAttributes = [.backgroundColor: DiffTheme.selection]
        tv.insertionPointColor = DiffTheme.text
        tv.usesFindBar = true
        tv.textLayoutManager?.delegate = tv
        // A new theme: new surfaces at once (the owners rebuild the colored text).
        NotificationCenter.default.addObserver(forName: .vetThemeChanged, object: nil, queue: .main) { [weak tv, weak scroll] _ in
            MainActor.assumeIsolated {
                tv?.backgroundColor = DiffTheme.background
                tv?.insertionPointColor = DiffTheme.text
                tv?.selectedTextAttributes = [.backgroundColor: DiffTheme.selection]
                scroll?.backgroundColor = DiffTheme.background
                tv?.needsDisplay = true
            }
        }
        scroll.documentView = tv
        return (scroll, tv)
    }

    static var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = DiffTheme.lineHeight
        p.maximumLineHeight = DiffTheme.lineHeight
        // Code reads left to right even when a line starts with a Hebrew or Arabic string.
        p.baseWritingDirection = .leftToRight
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
            let r = NSRect(x: 0, y: y(ofLine: m.line) - 1.5, width: width, height: 3)
            guard r.intersects(rect) else { continue }
            m.color.withAlphaComponent(0.85).setFill()
            r.fill()
        }
        drawWordHighlights(in: rect)
        drawFoldRows(in: rect)
        if !inlayHints.isEmpty || !lenses.isEmpty { drawDecorations(in: rect) }
    }

    // A hint's gap is kerning on the character before it; typing there mustn't copy it.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { var a = super.typingAttributes; a[.kern] = nil; a[.vetHint] = nil; return a }
        set { var a = newValue; a[.kern] = nil; a[.vetHint] = nil; super.typingAttributes = a }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let id = foldLines[line(at: p)] {
            onFoldClick?(id)
            return
        }
        if let hit = lensRects.first(where: { $0.0.insetBy(dx: -2, dy: -2).contains(p) }), let onLensClick {
            NavigationAnchor.set(self, hit.0)
            onLensClick(hit.1)
            return
        }
        if event.modifierFlags.contains(.command), let onNavigate, let pos = position(at: p) {
            NavigationAnchor.set(self, symbolRect(line: pos.line, character: pos.character))
            onNavigate(.definition, pos.line, pos.character)
            return
        }
        super.mouseDown(with: event)
    }

    @objc func vetSave(_ sender: Any?) { onSave?() }

    /// Space in a read-only pane (approve and move on).
    var onSpace: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if !isEditable, let onSpace, event.charactersIgnoringModifiers == " ",
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            onSpace()
            return
        }
        super.keyDown(with: event)
    }

    /// Force click (a deep press on the trackpad): usages of the symbol, or its declaration when
    /// nothing uses it. (Replaces the system's Look Up in code.)
    override func quickLook(with event: NSEvent) {
        if forceClicked { forceClicked = false; return } // pressureChange already handled this press
        forceNavigate(at: event.locationInWindow)
    }

    override func pressureChange(with event: NSEvent) {
        if event.stage == 2, lastPressureStage < 2 {
            forceClicked = true
            forceNavigate(at: event.locationInWindow)
        }
        if event.stage == 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.forceClicked = false } }
        lastPressureStage = event.stage
    }

    private func forceNavigate(at windowPoint: NSPoint) {
        let p = convert(windowPoint, from: nil)
        guard let onNavigate, let pos = position(at: p), word(line: pos.line, character: pos.character) != nil else { return }
        NavigationAnchor.set(self, symbolRect(line: pos.line, character: pos.character))
        onNavigate(.usagesOrDeclaration, pos.line, pos.character)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        hoverTracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let at = convert(event.locationInWindow, from: nil)
        let row = line(at: at)
        hoveredFoldLine = foldLines[row] != nil ? row : nil
        if hoveredFoldLine != nil || lens(at: at) != nil { NSCursor.pointingHand.set() }
        hoverWork?.cancel()
        guard onHover != nil, NSEvent.pressedMouseButtons == 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hoverRested(at: p) } }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredFoldLine = nil
        hoverWork?.cancel()
        HoverPresenter.shared.cancelPending()
    }

    /// Asks for hover info when the pointer is really on a symbol (not past the line's end).
    private func hoverRested(at p: NSPoint) {
        guard let window, window.isKeyWindow, let pos = position(at: p) else { return }
        let rect = symbolRect(line: pos.line, character: pos.character)
        guard rect.insetBy(dx: -1, dy: -2).contains(p) else { return }
        hover(line: pos.line, character: pos.character)
    }

    /// Asks for hover info on the symbol at (display line, column).
    func hover(line: Int, character: Int) {
        guard word(line: line, character: character) != nil else { return }
        let rect = symbolRect(line: line, character: character)
        let key = "\(ObjectIdentifier(self).hashValue):\(line):\(Int(rect.minX))"
        guard !HoverPresenter.shared.isShowing(key) else { return }
        HoverPresenter.shared.prepare(view: self, rect: rect, key: key)
        onHover?(line, character)
    }


    /// A short, reviewer-only menu instead of the text system's long one.
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if let pos = position(at: p) {
            // Right-clicking outside the selection moves the caret there first, like other editors.
            let index = characterIndexForInsertion(at: p)
            if !NSLocationInRange(index, selectedRange()) || selectedRange().length == 0 { setSelectedRange(NSRange(location: index, length: 0)) }
            NavigationAnchor.set(self, symbolRect(line: pos.line, character: pos.character))
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

    /// The word at (display line, column), in this view's coordinates; where popovers point.
    func symbolRect(line: Int, character: Int) -> NSRect {
        guard let r = range(line: line, character: character), let window else { return .zero }
        let ns = string as NSString
        var lo = r.location, hi = r.location
        func isWord(_ c: unichar) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 }
        while lo > 0, isWord(ns.character(at: lo - 1)) { lo -= 1 }
        while hi < ns.length, isWord(ns.character(at: hi)) { hi += 1 }
        var actual = NSRange()
        let screen = firstRect(forCharacterRange: NSRange(location: lo, length: max(1, hi - lo)), actualRange: &actual)
        return convert(window.convertFromScreen(screen), from: nil)
    }

    /// The identifier at (display line, column), if any.
    func word(line: Int, character: Int) -> String? {
        guard let r = range(line: line, character: character) else { return nil }
        let ns = string as NSString
        var lo = r.location, hi = r.location
        func isWord(_ c: unichar) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 }
        while lo > 0, isWord(ns.character(at: lo - 1)) { lo -= 1 }
        while hi < ns.length, isWord(ns.character(at: hi)) { hi += 1 }
        return hi > lo ? ns.substring(with: NSRange(location: lo, length: hi - lo)) : nil
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
                || storage.attribute(.vetRemoved, at: i, effectiveRange: nil) != nil
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

// MARK: Text centered in its row

/// TextKit puts a fixed-height row's extra space above the text, so code sat low in its row
/// (and in every band and highlight drawn for it). Each line is drawn lifted by half of that.
extension CodeTextView: @preconcurrency NSTextLayoutManagerDelegate {
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        CenteredLineFragment(textElement: textElement, range: textElement.elementRange)
    }

    /// How far a line's glyphs are lifted to sit centered in the row.
    static var glyphLift: CGFloat {
        let f = DiffTheme.font
        let natural = f.ascender - f.descender + f.leading
        return max(0, (DiffTheme.lineHeight - natural) / 2)
    }
}

final class CenteredLineFragment: NSTextLayoutFragment {
    override func draw(at point: CGPoint, in context: CGContext) {
        let lift = MainActor.assumeIsolated { CodeTextView.glyphLift }
        super.draw(at: CGPoint(x: point.x, y: point.y - lift), in: context)
    }
}

