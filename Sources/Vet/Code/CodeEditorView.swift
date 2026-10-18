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
    private(set) var isDirty = false { didSet { if oldValue != isDirty { onDirtyChange?(isDirty) } } }
    var onDirtyChange: ((Bool) -> Void)?
    var onSave: ((String) -> Void)?
    /// The model versions this view last showed (it outlives its SwiftUI host).
    var shownVersion = -1
    var shownJump = -1
    /// ⌘-click or the right-click menu asked to navigate from this position.
    var onNavigate: ((CodeTextView.Navigation, Int, Int) -> Void)?
    /// The pointer rested on a symbol at (line, column).
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
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        gutter.frame = NSRect(x: 0, y: 0, width: LineNumberGutter.width, height: bounds.height)
        scroll.frame = NSRect(x: LineNumberGutter.width, y: 0, width: bounds.width - LineNumberGutter.width, height: bounds.height)
        updateSticky()
    }

    /// Pins the enclosing declarations of the first visible line.
    private func updateSticky() {
        guard let storage = textView.textStorage else { return }
        let clip = scroll.contentView.bounds
        let first = Int((clip.minY - DiffTheme.inset.height) / DiffTheme.lineHeight)
        sticky.show(StickyLinesView.rows(in: storage, first: max(0, first)))
        sticky.scrollX = clip.minX
        let scrollerWidth = scroll.verticalScroller.map { $0.isHidden ? 0 : $0.frame.width } ?? 0
        sticky.gutterWidth = LineNumberGutter.width
        sticky.frame = NSRect(x: 0, y: 0, width: bounds.width - scrollerWidth, height: sticky.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        DiffTheme.background.setFill()
        dirtyRect.fill()
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
        let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
        gutter.highlighted = line
        if let range = textView.range(line: line, character: character) {
            textView.setSelectedRange(range)
            textView.showFindIndicator(for: range)
        }
        window?.makeFirstResponder(textView)
    }

    var currentText: String { textView.string }

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

    @objc private func scrolled() {
        gutter.offset = scroll.contentView.bounds.minY
        updateSticky()
    }

    func textDidChange(_ notification: Notification) {
        isDirty = true
        let count = textView.string.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
        if count != gutter.numbers.count { gutter.numbers = (0..<count).map { $0 }; sizeDocument(lineCount: count) }
        rehighlight?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let storage = self.textView.textStorage else { return }
            MainActor.assumeIsolated { CodeText.rehighlight(storage, language: self.language) }
        }
        rehighlight = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
