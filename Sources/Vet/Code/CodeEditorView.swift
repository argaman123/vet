import AppKit
import VetCore

/// A single code pane with line numbers: the Files tab's viewer (and editor).
final class CodeEditorView: NSView, NSTextViewDelegate {
    private let (scroll, textView) = CodeTextView.make()
    private let gutter = LineNumberGutter()
    private let sticky = StickyLinesView()
    private var language: CodeLanguage = .plain
    private var lines = TextLines(lines: [])
    private var rehighlight: DispatchWorkItem?
    private var autosave: DispatchWorkItem?
    private(set) var isDirty = false { didSet { if oldValue != isDirty { onDirtyChange?(isDirty) } } }
    var onDirtyChange: ((Bool) -> Void)?
    var onSave: ((String) -> Void)?
    /// The model versions this view last showed (it outlives its SwiftUI host).
    var shownVersion = -1
    var shownJump = -1
    /// ⌘-click or the right-click menu asked to navigate from this position.
    var onNavigate: ((CodeTextView.Navigation, Int, Int) -> Void)?
    /// The pointer rested on a symbol at (line, column).
    /// Typing paused (or a file was loaded): time to ask for the reading aids again.
    var onTextSettled: (() -> Void)?
    private var settle: DispatchWorkItem?
    var pane: CodeTextView { textView }
    /// A read-only viewer (the usages preview).
    var readOnly = false { didSet { textView.isEditable = !readOnly } }
    var lineGutter: LineNumberGutter { gutter }
    var onHover: ((Int, Int) -> Void)? {
        get { textView.onHover }
        set { textView.onHover = newValue }
    }
    var contextItems: ((Int, Int) -> [NSMenuItem])? {
        get { textView.contextItems }
        set { textView.contextItems = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(scroll)
        addSubview(gutter)
        addSubview(sticky)
        sticky.isHidden = true
        sticky.onClick = { [weak self] line in self?.scrollTo(line: line) }
        textView.isEditable = true
        textView.allowsUndo = true
        textView.delegate = self
        textView.onSave = { [weak self] in self?.save() }
        textView.onNavigate = { [weak self] kind, line, character in self?.onNavigate?(kind, line, character) }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(fontChanged), name: .vetCodeFontChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .vetThemeChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        gutter.frame = NSRect(x: 0, y: 0, width: LineNumberGutter.width, height: bounds.height)
        scroll.frame = NSRect(x: LineNumberGutter.width, y: 0, width: bounds.width - LineNumberGutter.width, height: bounds.height)
        updateSticky()
    }

    /// The glass header floats over the code: the text scrolls under it, and rests clear of it.
    func setOverlay(top: CGFloat) {
        guard scroll.contentInsets.top != top else { return }
        let atTop = scroll.contentView.bounds.minY <= -scroll.contentInsets.top + 0.5
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        if atTop { scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: -top)) }
        scroll.reflectScrolledClipView(scroll.contentView)
        gutter.offset = scroll.contentView.bounds.minY
        updateSticky()
    }

    private func clampY(_ y: CGFloat) -> CGFloat {
        let i = scroll.contentInsets
        let maxY = max(-i.top, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height + i.bottom)
        return min(max(-i.top, y), maxY)
    }

    /// Pins the enclosing declarations of the first visible line (below the floating header).
    private func updateSticky() {
        guard let storage = textView.textStorage else { return }
        let clip = scroll.contentView.bounds
        let top = scroll.contentInsets.top
        let first = Int((clip.minY + top - DiffTheme.inset.height) / DiffTheme.lineHeight)
        sticky.show(StickyLinesView.rows(in: storage, first: max(0, first)))
        sticky.scrollX = clip.minX
        let scrollerWidth = scroll.verticalScroller.map { $0.isHidden ? 0 : $0.frame.width } ?? 0
        sticky.gutterWidth = LineNumberGutter.width
        sticky.lead = top > 0 ? StickyLinesView.glassGap : 0 // up to the header's glass
        sticky.frame = NSRect(x: 0, y: top - sticky.lead, width: bounds.width - scrollerWidth, height: sticky.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Views don't clip to their bounds by default (macOS 14+): filling the dirty rect alone
        // painted over the file header above the editor.
        DiffTheme.background.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    /// Shows a file. Unsaved edits are only replaced when `force` is set.
    func load(_ text: TextLines, language: CodeLanguage, force: Bool = false) {
        guard force || !isDirty else { return }
        let keep = scroll.contentView.bounds.origin
        lines = text
        self.language = language
        let display = (0..<text.count).map { DiffLayout.DisplayLine.code($0) }
        textView.textStorage?.setAttributedString(CodeText.attributed(text, display, language))
        textView.undoManager?.removeAllActions(withTarget: textView.textStorage as Any)
        gutter.numbers = (0..<max(1, text.count)).map { $0 }
        sizeDocument(lineCount: max(1, text.count))
        scroll.contentView.scroll(to: keep)
        scroll.reflectScrolledClipView(scroll.contentView)
        gutter.offset = scroll.contentView.bounds.minY
        isDirty = false
    }

    func scrollTo(line: Int, character: Int = 0) {
        let y = DiffTheme.inset.height + CGFloat(line) * DiffTheme.lineHeight - scroll.contentView.bounds.height / 3
        scroll.contentView.scroll(to: NSPoint(x: 0, y: clampY(y)))
        scroll.reflectScrolledClipView(scroll.contentView)
        gutter.highlighted = line
        if let range = textView.range(line: line, character: character) {
            textView.setSelectedRange(range)
            textView.showFindIndicator(for: range)
        }
        window?.makeFirstResponder(textView)
    }

    /// Shows a line a third of the way down with a full-row band, and marks `columns` on it, without
    /// taking focus or moving the selection (for previews).
    func reveal(line: Int, columns: Range<Int>?) {
        let y = DiffTheme.inset.height + CGFloat(line) * DiffTheme.lineHeight - scroll.contentView.bounds.height / 3
        scroll.contentView.scroll(to: NSPoint(x: 0, y: clampY(y)))
        scroll.reflectScrolledClipView(scroll.contentView)
        gutter.offset = scroll.contentView.bounds.minY
        gutter.highlighted = line
        textView.bands = [.init(lines: line..<(line + 1), color: DiffTheme.foldBand)]
        if let storage = textView.textStorage {
            storage.beginEditing()
            storage.removeAttribute(.vetWordHighlight, range: NSRange(location: 0, length: storage.length))
            if let columns, let start = textView.range(line: line, character: columns.lowerBound),
               NSMaxRange(start) + columns.count <= storage.length {
                storage.addAttribute(.vetWordHighlight, value: DiffTheme.searchMatch, range: NSRange(location: start.location, length: columns.count))
            }
            storage.endEditing()
        }
        updateSticky()
        textView.needsDisplay = true
    }

    var currentText: String { textView.string }

    /// Whether anything is selected, and which lines the selection (or caret) is on.
    var selectionLines: (lines: ClosedRange<Int>, selected: Bool) {
        let r = textView.selectedRange()
        return (textView.displayLines(of: r), r.length > 0)
    }

    /// The lines on screen.
    var visibleLines: ClosedRange<Int> {
        let clip = scroll.contentView.bounds
        let a = max(0, Int((clip.minY - DiffTheme.inset.height) / DiffTheme.lineHeight))
        return a...max(a, Int((clip.maxY - DiffTheme.inset.height) / DiffTheme.lineHeight))
    }

    /// The lines the selection covers (or `fallback` when nothing is selected).
    func selectedLines(fallback: Int) -> ClosedRange<Int> {
        let r = textView.selectedRange()
        return r.length == 0 ? fallback...fallback : textView.displayLines(of: r)
    }

    /// The text of whole lines.
    func text(lines: ClosedRange<Int>) -> String {
        let all = textView.string.components(separatedBy: "\n")
        return all[max(0, lines.lowerBound)...min(all.count - 1, lines.upperBound)].joined(separator: "\n")
    }

    func save() {
        guard isDirty else { return }
        onSave?(fileText())
    }

    func markSaved() { isDirty = false }

    /// The editor's text as file bytes: unchanged lines keep their own endings, the final newline
    /// stays as it was.
    func fileText() -> String {
        let rows = textView.string.components(separatedBy: "\n").map { EditedText.Row.text($0) }
        return String(decoding: EditedText.rebuild(rows: rows, original: lines), as: UTF8.self)
    }

    private func sizeDocument(lineCount: Int) {
        let height = DiffTheme.inset.height * 2 + CGFloat(lineCount) * DiffTheme.lineHeight
        textView.minSize = NSSize(width: 0, height: height)
        textView.setFrameSize(NSSize(width: max(textView.frame.width, scroll.contentSize.width), height: max(height, scroll.contentSize.height)))
    }

    /// New theme: recolor the code (keeping edits), then the reading aids color names again.
    @objc private func themeChanged() {
        if let storage = textView.textStorage { CodeText.rehighlight(storage, language: language) }
        gutter.needsDisplay = true
        sticky.needsDisplay = true
        needsDisplay = true
        onTextSettled?()
    }

    @objc private func fontChanged() {
        textView.applyCodeFont()
        sizeDocument(lineCount: max(1, gutter.numbers.count))
        gutter.needsDisplay = true
        updateSticky()
        sticky.needsDisplay = true
    }

    @objc private func scrolled() {
        gutter.offset = scroll.contentView.bounds.minY
        updateSticky()
    }

    func textDidChange(_ notification: Notification) {
        isDirty = true
        // Autosave a moment after typing stops.
        autosave?.cancel()
        let save = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
        autosave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: save)
        let count = textView.string.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
        if count != gutter.numbers.count { gutter.numbers = (0..<count).map { $0 }; sizeDocument(lineCount: count) }
        rehighlight?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let storage = self.textView.textStorage else { return }
            MainActor.assumeIsolated { CodeText.rehighlight(storage, language: self.language) }
        }
        rehighlight = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        settle?.cancel()
        let settled = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.onTextSettled?() } }
        settle = settled
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: settled)
    }
}

// MARK: Test aids (driven by SnapshotHook in test runs)

extension CodeEditorView {
    /// Stand-in hints, a lens and jump icons on the first lines, to check how they draw.
    func debugDecorate() {
        textView.inlayHints = [InlayHintMark(line: 1, character: 9, label: "name:", padLeft: false, padRight: true),
                               InlayHintMark(line: 2, character: 12, label: ": string", padLeft: false, padRight: false)]
        textView.lenses = [LineLensMark(line: 3, character: 0, parts: [.init(text: "3 usages", kind: .references)])]
        gutter.marks = [3: .implemented, 5: .overrides]
    }

    /// Writes the frames of characters on a line to VET_SNAPSHOT_DIR/frames.txt.
    func debugFrames(line: Int) {
        guard let dir = ProcessInfo.processInfo.environment["VET_SNAPSHOT_DIR"], let r = textView.range(line: line, character: 0) else { return }
        var out = "origin \(textView.textContainerOrigin)\n"
        for i in 0..<14 { out += "\(i) \(textView.segmentFrame(NSRange(location: r.location + i, length: 1)).map { "\($0)" } ?? "nil")\n" }
        try? out.write(toFile: dir + "/frames.txt", atomically: true, encoding: .utf8)
    }

    /// Rests the pointer on (line, column) without moving the mouse.
    func debugHover(line: Int, character: Int) { textView.hover(line: line, character: character) }
}
