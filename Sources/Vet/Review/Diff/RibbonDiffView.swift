import AppKit
import SwiftUI
import VetCore

/// SwiftUI host for the ribbon diff.
struct RibbonDiffView: NSViewRepresentable {
    let model: ReviewModel
    let version: Int
    let jumpSerial: Int

    func makeNSView(context: Context) -> RibbonDiffNSView {
        let v = RibbonDiffNSView()
        v.onDirtyChange = { [weak model] dirty in model?.diffDirty = dirty }
        v.onSave = { [weak model] text in model?.saveDiffEdits(text) }
        v.onToggle = { [weak model] id, staged, snapshot in model?.setHunk(id, staged: staged, snapshot: snapshot) }
        v.noteActions = .init(save: { [weak model] id, text in model?.saveNote(id, text: text) },
                              cancel: { [weak model] id in model?.cancelNote(id) },
                              edit: { [weak model] id in model?.editNote(id) },
                              delete: { [weak model] id in model?.deleteNote(id) })
        v.onAddNote = { [weak model] left, line, text in model?.addNote(left: left, line: line, lineText: text) }
        v.onAsk = { [weak model] left, lines, code in
            guard let model, let path = model.diff?.change.path else { return }
            model.askClaude(path: path, lines: lines, code: code, old: left)
        }
        v.onStageLines = { [weak model] lines, snapshot in model?.stageLines(lines, snapshot: snapshot) }
        v.onNavigate = { [weak model] kind, left, line, character in model?.navigate(kind, left: left, line: line, character: character) }
        v.onFoldClick = { [weak model] id in model?.expandFold(id) }
        return v
    }

    func updateNSView(_ view: RibbonDiffNSView, context: Context) {
        if view.revertSerial != model.revertSerial {
            view.revertSerial = model.revertSerial
            view.discardEdits()
            view.shownVersion = -1
        }
        if view.shownVersion != version {
            view.shownVersion = version
            view.notes = model.notesForOpenFile()
            view.editingNoteID = model.editingNoteID
            view.show(model.diff, folding: model.folding, expanded: model.expandedFolds)
        }
        if jumpSerial != view.lastJump {
            view.lastJump = jumpSerial
            view.jump(forward: model.jump.forward)
        }
    }
}

/// HEAD on the left, the working file on the right, joined by the ribbon gutter.
final class RibbonDiffNSView: NSView, NSTextViewDelegate {
    var onDirtyChange: ((Bool) -> Void)?
    /// Called with the full new file text when you save edits made in the right pane.
    var onSave: ((String) -> Void)?
    var revertSerial = 0
    struct NoteActions {
        let save: (String, String) -> Void
        let cancel: (String) -> Void
        let edit: (String) -> Void
        let delete: (String) -> Void
    }
    var notes: [ReviewNote] = []
    var editingNoteID: String?
    var noteActions: NoteActions?
    var onAddNote: ((Bool, Int, String) -> Void)?
    var onAsk: ((Bool, ClosedRange<Int>, String) -> Void)?
    var onStageLines: ((Range<Int>, String) -> Void)?
    var onNavigate: ((CodeTextView.Navigation, Bool, Int, Int) -> Void)?
    private var cards: [NoteCardView] = []
    /// Where each card sits in its text view's coordinates; repositioned over the panes on scroll.
    private var cardPlaces: [(card: NoteCardView, left: Bool, rect: NSRect)] = []
    private(set) var isDirty = false { didSet { if oldValue != isDirty { onDirtyChange?(isDirty) } } }
    private var rehighlight: DispatchWorkItem?
    private var shownStaging: SectionStaging?
    private var shownLanguage: CodeLanguage = .plain
    var onToggle: ((Int, Bool, String) -> Void)?
    var onFoldClick: ((Int) -> Void)?
    var lastJump = 0
    var shownVersion = -1

    private let (leftScroll, leftText) = CodeTextView.make()
    private let (rightScroll, rightText) = CodeTextView.make()
    private let gutter = RibbonGutterView()
    private let messageLabel = NSTextField(labelWithString: "")
    private var diffLayout: DiffLayout?
    private var mode: RibbonGutterView.Mode = .split
    private var shownPath: String?
    private var shownLines: (head: TextLines, work: TextLines)?

    private struct Anchor { let left: Bool; let line: Int; let text: Substring; let offset: CGFloat }
    private var syncing = false
    private var split: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "diffSplit")
        return v == 0 ? 0.5 : v
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        for v in [leftScroll, rightScroll, gutter, messageLabel] as [NSView] { addSubview(v) }
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 14)
        messageLabel.alignment = .center
        for scroll in [leftScroll, rightScroll] {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        for tv in [leftText, rightText] { tv.onFoldClick = { [weak self] id in self?.onFoldClick?(id) } }
        // The working file (right side) can be edited and saved; HEAD (left) can't.
        rightText.isEditable = true
        rightText.allowsUndo = true
        rightText.delegate = self
        rightText.onSave = { [weak self] in self?.save() }
        leftText.contextItems = { [weak self] line, character in self?.menuItems(left: true, displayLine: line, character: character) ?? [] }
        rightText.contextItems = { [weak self] line, character in self?.menuItems(left: false, displayLine: line, character: character) ?? [] }
        leftText.onNavigate = { [weak self] kind, line, character in self?.navigate(kind, left: true, displayLine: line, character: character) }
        rightText.onNavigate = { [weak self] kind, line, character in self?.navigate(kind, left: false, displayLine: line, character: character) }
        gutter.onToggle = { [weak self] id, staged, snapshot in self?.onToggle?(id, staged, snapshot) }
        gutter.onDrag = { [weak self] dx in self?.drag(dx) }
        gutter.onResetSplit = { [weak self] in self?.setSplit(0.5) }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Content

    func show(_ doc: DiffDocument?, folding: Bool, expanded: Set<Int>) {
        guard let doc else {
            showMessage("Select a file to review")
            shownPath = nil
            return
        }
        guard let staging = doc.staging else {
            showMessage(doc.message ?? "")
            shownPath = doc.change.path
            return
        }
        messageLabel.isHidden = true
        let samePath = shownPath == doc.change.path
        // Never replace text you're editing; the header offers Reload instead.
        if isDirty && samePath { return }
        isDirty = false
        shownStaging = staging
        shownLanguage = doc.language
        rightText.isEditable = doc.change.kind != .deleted
        let keepLeft = leftScroll.contentView.bounds.origin, keepRight = rightScroll.contentView.bounds.origin
        // Remember what you were reading (a line's text and number), not just a pixel offset,
        // so lines Claude inserts above it don't shift your place.
        let anchor = samePath ? readingAnchor() : nil
        shownPath = doc.change.path

        mode = switch doc.change.kind {
        case .added, .untracked: .rightOnly
        case .deleted: .leftOnly
        default: staging.head.count == 0 ? .rightOnly : .split
        }
        let layout = DiffLayout(headCount: staging.head.count, workCount: staging.work.count,
                                hunks: staging.hunks, folding: folding, expanded: expanded,
                                notes: notes.map { .init(id: $0.id, left: $0.left, line: $0.line,
                                                         rows: NoteCardView.rows(for: $0.text, editing: $0.id == editingNoteID)) })
        diffLayout = layout
        var states: [Int: StageState] = [:]
        for h in staging.hunks { states[h.id] = staging.state(of: h) }

        var leftWords: [Int: [Range<Int>]] = [:], rightWords: [Int: [Range<Int>]] = [:]
        for h in staging.hunks {
            leftWords.merge(h.headCols) { $1 }
            rightWords.merge(h.workCols) { $1 }
        }
        leftText.textStorage?.setAttributedString(Self.text(staging.head, layout.left, doc.language, words: leftWords, color: DiffTheme.removed))
        rightText.textStorage?.setAttributedString(Self.text(staging.work, layout.right, doc.language, words: rightWords, color: DiffTheme.added))

        var leftBands: [CodeTextView.Band] = [], rightBands: [CodeTextView.Band] = []
        var leftMarkers: [(Int, NSColor)] = [], rightMarkers: [(Int, NSColor)] = []
        var leftFolds: [Int: Int] = [:], rightFolds: [Int: Int] = [:]
        for s in layout.segments {
            switch s.kind {
            case .hunk(let id):
                guard let h = staging.hunks.first(where: { $0.id == id }) else { continue }
                let color = DiffTheme.color(head: h.head, work: h.work)
                let fill = DiffTheme.fill(head: h.head, work: h.work, staged: states[id] == .staged)
                if s.left.isEmpty { leftMarkers.append((s.left.lowerBound, color)) }
                else { leftBands.append(.init(lines: s.left, color: fill)) }
                if s.right.isEmpty { rightMarkers.append((s.right.lowerBound, color)) }
                else { rightBands.append(.init(lines: s.right, color: fill)) }
            case .fold(let id):
                leftBands.append(.init(lines: s.left, color: DiffTheme.foldBand))
                rightBands.append(.init(lines: s.right, color: DiffTheme.foldBand))
                leftFolds[s.left.lowerBound] = id
                rightFolds[s.right.lowerBound] = id
            case .same, .note: break
            }
        }
        leftText.bands = leftBands; rightText.bands = rightBands
        leftText.markers = leftMarkers.map { (line: $0.0, color: $0.1) }
        rightText.markers = rightMarkers.map { (line: $0.0, color: $0.1) }
        leftText.foldLines = leftFolds; rightText.foldLines = rightFolds
        placeCards(layout)
        leftText.window?.invalidateCursorRects(for: leftText)
        rightText.window?.invalidateCursorRects(for: rightText)

        gutter.mode = mode
        gutter.diffLayout = layout
        gutter.hunks = staging.hunks
        gutter.states = states
        gutter.snapshotID = staging.snapshotID
        gutter.leftNumbers = layout.left.map { if case .code(let l) = $0 { l } else { nil } }
        gutter.rightNumbers = layout.right.map { if case .code(let l) = $0 { l } else { nil } }
        gutter.reload()

        // Every line is 18 pt, so the exact document height is known now; setting it up front
        // means restoring the scroll position isn't clamped by a half-laid-out text view.
        for (scroll, tv, count) in [(leftScroll, leftText, layout.left.count), (rightScroll, rightText, layout.right.count)] {
            let height = DiffTheme.inset.height * 2 + CGFloat(count) * DiffTheme.lineHeight
            tv.minSize = NSSize(width: 0, height: height)
            tv.setFrameSize(NSSize(width: max(tv.frame.width, scroll.contentSize.width), height: max(height, scroll.contentSize.height)))
        }
        leftScroll.isHidden = mode == .rightOnly
        rightScroll.isHidden = mode == .leftOnly
        gutter.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        // Restore (same file) or pick (new file) the position without the panes' scroll
        // notifications fighting each other, then line the left pane up with the right.
        syncing = true
        if samePath {
            leftScroll.contentView.scroll(to: keepLeft)
            rightScroll.contentView.scroll(to: keepRight)
            if let anchor { restore(anchor, staging: staging, layout: layout) }
        } else {
            leftScroll.contentView.scroll(to: .zero)
            rightScroll.contentView.scroll(to: .zero)
            if let first = layout.segments.first(where: { if case .hunk = $0.kind { true } else { false } }) {
                scrollRight(toLine: max(0, first.right.lowerBound - 4))
            }
        }
        leftScroll.reflectScrolledClipView(leftScroll.contentView)
        rightScroll.reflectScrolledClipView(rightScroll.contentView)
        syncing = false
        if mode == .split { align(from: rightScroll) }
        shownLines = (staging.head, staging.work)
        syncGutter()
        displayIfNeeded()
        Timing.diffShown(doc.change.path)
    }

    // MARK: Notes and the right-click menu

    private func placeCards(_ layout: DiffLayout) {
        cards.forEach { $0.removeFromSuperview() }
        cards = []
        cardPlaces = []
        for seg in layout.segments {
            guard case .note(let id) = seg.kind, let note = notes.first(where: { $0.id == id }) else { continue }
            let tv = note.left ? leftText : rightText
            if (note.left && mode == .rightOnly) || (!note.left && mode == .leftOnly) { continue } // that side isn't shown
            let rows = note.left ? seg.left : seg.right
            let editing = id == editingNoteID
            let card = NoteCardView(title: "Note on line \(note.line + 1)", text: note.text, editing: editing, sent: note.sent)
            card.onSave = { [weak self] text in self?.noteActions?.save(id, text) }
            card.onCancel = { [weak self] in self?.noteActions?.cancel(id) }
            card.onEdit = { [weak self] in self?.noteActions?.edit(id) }
            card.onDelete = { [weak self] in self?.noteActions?.delete(id) }
            let width = max(260, ((note.left ? leftScroll : rightScroll).contentSize.width) - 28)
            // An overlay above both panes (TextKit 2's own views would cover a text view's subviews,
            // and the clip view routes clicks to its document); repositioned whenever a pane scrolls.
            addSubview(card)
            cards.append(card)
            cardPlaces.append((card, note.left, NSRect(x: 14, y: tv.y(ofLine: rows.lowerBound) + 3, width: min(width, 760),
                                                       height: CGFloat(rows.count) * DiffTheme.lineHeight - 6)))
            if editing { DispatchQueue.main.async { card.focus() } }
        }
    }

    private func positionCards() {
        for place in cardPlaces {
            let tv = place.left ? leftText : rightText, scroll = place.left ? leftScroll : rightScroll
            let frame = convert(place.rect, from: tv)
            place.card.frame = frame
            place.card.isHidden = scroll.isHidden || !frame.intersects(convert(scroll.contentView.bounds, from: scroll.contentView))
        }
    }

    private func fileLine(left: Bool, displayLine d: Int) -> Int? {
        guard let layout = diffLayout else { return nil }
        let display = left ? layout.left : layout.right
        guard d >= 0, d < display.count, case .code(let l) = display[d] else { return nil }
        return l
    }

    private func navigate(_ kind: CodeTextView.Navigation, left: Bool, displayLine: Int, character: Int) {
        guard let line = fileLine(left: left, displayLine: displayLine) else { return }
        onNavigate?(kind, left, line, character)
    }

    /// The diff's right-click menu, exactly as designed (spec §2.3).
    private func menuItems(left: Bool, displayLine: Int, character: Int) -> [NSMenuItem] {
        guard let staging = shownStaging, let line = fileLine(left: left, displayLine: displayLine) else { return [] }
        let tv = left ? leftText : rightText
        let lines = left ? staging.head : staging.work
        let selection = tv.displayLines(of: tv.selectedRange())
        let fileLines = selection.compactMap { fileLine(left: left, displayLine: $0) }
        let span = (fileLines.min() ?? line)...(fileLines.max() ?? line)
        let code = span.map { String(lines.lines[$0].text) }.joined(separator: "\n")
        let path = shownPath ?? ""
        let hunk = staging.hunks.first { (left ? $0.head : $0.work).contains(line) }
        func item(_ title: String, _ key: String = "", enabled: Bool = true, _ action: @escaping () -> Void) -> NSMenuItem {
            let i = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
            i.isEnabled = enabled
            if !enabled { i.action = nil }
            return i
        }
        var items: [NSMenuItem] = [
            item("Add note") { [weak self] in self?.onAddNote?(left, line, String(lines.lines[line].text)) },
            item("Ask Claude about this") { [weak self] in self?.onAsk?(left, span, code) },
            .separator(),
            item("Go to definition") { [weak self] in self?.onNavigate?(.definition, left, line, character) },
            item("Go to implementation") { [weak self] in self?.onNavigate?(.implementation, left, line, character) },
            item("Find references") { [weak self] in self?.onNavigate?(.references, left, line, character) },
            .separator(),
            item("Stage selected lines", enabled: !left && !isDirty) { [weak self] in
                self?.onStageLines?(span.lowerBound..<(span.upperBound + 1), staging.snapshotID)
            },
            item("Unstage this section", enabled: hunk.map { staging.state(of: $0) != .unstaged } ?? false) { [weak self] in
                if let hunk { self?.onToggle?(hunk.id, false, staging.snapshotID) }
            },
            .separator(),
        ]
        items.append(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        items.append(item("Copy path and line") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(path):\(span.lowerBound + 1)\(span.count > 1 ? "-\(span.upperBound + 1)" : "")", forType: .string)
        })
        items[3].toolTip = "⌘-click"
        return items
    }

    // MARK: Editing the working file

    func textDidChange(_ notification: Notification) {
        isDirty = true
        rehighlight?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let storage = self.rightText.textStorage else { return }
            MainActor.assumeIsolated { CodeText.rehighlight(storage, language: self.shownLanguage) }
        }
        rehighlight = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func discardEdits() { isDirty = false }

    /// Rebuilds the whole file from the edited right pane: fold rows become the lines they hide.
    func save() {
        guard isDirty, let staging = shownStaging, let layout = diffLayout else { return }
        let work = staging.work
        let ending = work.lines.first(where: { !$0.terminator.isEmpty })?.terminator ?? "\n"
        let finalNewline = work.lines.last.map { !$0.terminator.isEmpty } ?? true
        guard let storage = rightText.textStorage else { return }
        let ns = storage.string as NSString
        var out: [String] = []
        var location = 0
        while location <= ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: min(location, max(0, ns.length - 1)), length: 0))
            if location == ns.length {
                if ns.length == 0 || ns.character(at: ns.length - 1) == 10 { out.append("") }
                break
            }
            var content = ns.substring(with: lineRange)
            if content.hasSuffix("\n") { content.removeLast() }
            if let id = storage.attribute(.vetFold, at: lineRange.location, effectiveRange: nil) as? Int, let hidden = layout.foldWork[id] {
                out += hidden.map { String(work.lines[$0].text) }
            } else {
                out.append(content)
            }
            location = NSMaxRange(lineRange)
        }
        if out.last == "" && out.count > 1 { out.removeLast() }
        var text = out.joined(separator: ending)
        if finalNewline && !text.isEmpty { text += ending }
        onSave?(text)
    }

    /// The first file line visible at the top of the main pane, and how far it's scrolled past.
    private func readingAnchor() -> Anchor? {
        guard let layout = diffLayout, let lines = shownLines else { return nil }
        let useLeft = mode == .leftOnly
        let scroll = useLeft ? leftScroll : rightScroll
        let display = useLeft ? layout.left : layout.right
        let top = scroll.contentView.bounds.minY
        let first = max(0, Int((top - DiffTheme.inset.height) / DiffTheme.lineHeight))
        guard first < display.count else { return nil }
        for d in first..<display.count {
            if case .code(let line) = display[d] {
                let text = (useLeft ? lines.head : lines.work).lines[line].text
                let y = DiffTheme.inset.height + CGFloat(d) * DiffTheme.lineHeight
                return Anchor(left: useLeft, line: line, text: text, offset: top - y)
            }
        }
        return nil
    }

    /// Scrolls so the anchored line (found by its text near its old number) is back where it was.
    private func restore(_ a: Anchor, staging: SectionStaging, layout: DiffLayout) {
        let lines = a.left ? staging.head : staging.work
        let display = a.left ? layout.left : layout.right
        guard lines.count > 0 else { return }
        var target = min(a.line, lines.count - 1)
        if lines.lines[target].text != a.text {
            for delta in 1...min(2_000, lines.count) {
                if a.line + delta < lines.count, lines.lines[a.line + delta].text == a.text { target = a.line + delta; break }
                if a.line - delta >= 0, a.line - delta < lines.count, lines.lines[a.line - delta].text == a.text { target = a.line - delta; break }
            }
        }
        guard let d = display.firstIndex(where: { if case .code(let l) = $0 { l >= target } else { false } }) else { return }
        let scroll = a.left ? leftScroll : rightScroll
        let y = DiffTheme.inset.height + CGFloat(d) * DiffTheme.lineHeight + a.offset
        let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: min(max(0, y), maxY)))
    }

    private func showMessage(_ text: String) {
        messageLabel.stringValue = text
        messageLabel.isHidden = false
        leftScroll.isHidden = true
        rightScroll.isHidden = true
        gutter.isHidden = true
        needsLayout = true
    }

    /// Builds one pane's text: real lines with syntax colors and word highlights, plus fold rows.
    private static func text(_ lines: TextLines, _ display: [DiffLayout.DisplayLine], _ language: CodeLanguage,
                             words: [Int: [Range<Int>]], color: NSColor) -> NSAttributedString {
        CodeText.attributed(lines, display, language, words: words, color: color)
    }

    // MARK: Layout and divider

    override func layout() {
        super.layout()
        let h = bounds.height, w = bounds.width
        let gw = RibbonGutterView.width(for: mode)
        switch mode {
        case .split:
            let lw = floor((w - gw) * split)
            leftScroll.frame = NSRect(x: 0, y: 0, width: lw, height: h)
            gutter.frame = NSRect(x: lw, y: 0, width: gw, height: h)
            rightScroll.frame = NSRect(x: lw + gw, y: 0, width: w - lw - gw, height: h)
        case .rightOnly:
            gutter.frame = NSRect(x: 0, y: 0, width: gw, height: h)
            rightScroll.frame = NSRect(x: gw, y: 0, width: w - gw, height: h)
        case .leftOnly:
            leftScroll.frame = NSRect(x: 0, y: 0, width: w - gw, height: h)
            gutter.frame = NSRect(x: w - gw, y: 0, width: gw, height: h)
        }
        messageLabel.frame = NSRect(x: 0, y: h / 2 - 12, width: w, height: 24)
        positionCards()
        window?.invalidateCursorRects(for: gutter)
    }

    override var isFlipped: Bool { true }

    // Drawn rather than layer-backed: a layer-backed container makes every tall pane keep a
    // full-size bitmap in memory.
    override func draw(_ dirtyRect: NSRect) {
        DiffTheme.background.setFill()
        dirtyRect.fill()
    }

    private func drag(_ dx: CGFloat) {
        let usable = bounds.width - RibbonGutterView.width(for: mode)
        guard usable > 0 else { return }
        setSplit(split + dx / usable)
    }

    private func setSplit(_ value: CGFloat) {
        split = min(0.85, max(0.15, value))
        UserDefaults.standard.set(split, forKey: "diffSplit")
        needsLayout = true
    }

    // MARK: Linked scrolling (by section anchors, so unequal sections line up)

    @objc private func scrolled(_ note: Notification) {
        guard !syncing, mode == .split, let clip = note.object as? NSClipView else {
            syncGutter()
            return
        }
        align(from: clip === leftScroll.contentView ? leftScroll : rightScroll)
    }

    /// Scrolls the other pane so the same place in the file sits in the middle of both.
    private func align(from src: NSScrollView) {
        guard let layout = diffLayout else { return }
        let fromLeft = src === leftScroll
        let dst = fromLeft ? rightScroll : leftScroll
        // Like WebStorm: line up whatever sits a third of the way down the view.
        let anchor = src.contentView.bounds.minY + src.contentView.bounds.height / 3
        let mapped = layout.map(Double((anchor - DiffTheme.inset.height) / DiffTheme.lineHeight), fromLeft: fromLeft)
        let targetY = DiffTheme.inset.height + CGFloat(mapped) * DiffTheme.lineHeight - dst.contentView.bounds.height / 3
        syncing = true
        let maxY = max(0, (dst.documentView?.frame.height ?? 0) - dst.contentView.bounds.height)
        dst.contentView.scroll(to: NSPoint(x: src.contentView.bounds.origin.x, y: min(max(0, targetY), maxY)))
        dst.reflectScrolledClipView(dst.contentView)
        syncing = false
        syncGutter()
    }

    private func syncGutter() {
        gutter.leftOffset = leftScroll.contentView.bounds.origin.y
        gutter.rightOffset = rightScroll.contentView.bounds.origin.y
        positionCards()
    }

    private func scrollRight(toLine line: Int) {
        let scroll = mode == .leftOnly ? leftScroll : rightScroll
        let y = DiffTheme.inset.height + CGFloat(line) * DiffTheme.lineHeight
        let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(y, maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Scrolls to the previous or next section relative to the middle of the view.
    func jump(forward: Bool) {
        guard let layout = diffLayout else { return }
        let scroll = mode == .leftOnly ? leftScroll : rightScroll
        let current = Int((scroll.contentView.bounds.minY + scroll.contentView.bounds.height / 3 - DiffTheme.inset.height) / DiffTheme.lineHeight)
        let starts = layout.segments.compactMap { s -> Int? in
            guard case .hunk = s.kind else { return nil }
            return mode == .leftOnly ? s.left.lowerBound : s.right.lowerBound
        }
        let target = forward ? starts.first { $0 > current + 1 } : starts.last { $0 < current - 1 }
        if let target { scrollRight(toLine: max(0, target - Int(scroll.contentView.bounds.height / DiffTheme.lineHeight / 3))) }
    }
}
