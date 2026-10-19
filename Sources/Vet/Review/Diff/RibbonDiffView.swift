import AppKit
import SwiftUI
import VetCore

/// SwiftUI host for the ribbon diff.
struct RibbonDiffView: NSViewRepresentable {
    let model: ReviewModel
    let version: Int
    let jumpSerial: Int
    var approveSerial = 0

    func makeNSView(context: Context) -> RibbonDiffNSView {
        let v = model.diffView // kept by the model across tab switches
        v.onDirtyChange = { [weak model] dirty in model?.diffDirty = dirty }
        v.onSave = { [weak model] text, path in model?.saveDiffEdits(text, path: path) }
        v.onSaveRefused = { [weak model] in model?.show("A folded region was changed, so nothing was saved. Discard and try again.") }
        model.diffEditedText = { [weak v] in v?.editedFileText() }
        model.diffEditBase = { [weak v] in v?.editBase }
        model.diffSave = { [weak v] in v?.save() }
        v.onToggle = { [weak model] id, staged, snapshot in model?.setHunk(id, staged: staged, snapshot: snapshot) }
        v.noteActions = .init(save: { [weak model] id, text in model?.saveNote(id, text: text) },
                              cancel: { [weak model] id in model?.cancelNote(id) },
                              edit: { [weak model] id in model?.editNote(id) },
                              delete: { [weak model] id in model?.deleteNote(id) })
        v.onStageLines = { [weak model] lines, snapshot in model?.stageLines(lines, snapshot: snapshot) }
        v.onNavigate = { [weak model] kind, left, line, character in model?.navigate(kind, left: left, line: line, character: character) }
        v.onHover = { [weak model] line, character in model?.hover(line: line, character: character) }
        v.onFoldClick = { [weak model] id in model?.expandFold(id) }
        v.onFileDone = { [weak model] in model?.nextUnreviewed() }
        v.onApproveKey = { [weak model] in model?.approveAndNext() }
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
            view.unified = model.unified
            view.pendingHunks = model.pendingHunks
            view.notes = []
            view.editingNoteID = model.editingNoteID
            view.show(model.diff, folding: model.folding, expanded: model.expandedFolds)
            model.readingAids?(view)
        }
        if jumpSerial != view.lastJump {
            view.lastJump = jumpSerial
            view.jump(forward: model.jump.forward)
        }
        if approveSerial != view.lastApprove {
            view.lastApprove = approveSerial
            view.approveAndNext()
        }
    }
}

/// HEAD on the left, the working file on the right, joined by the ribbon gutter.
final class RibbonDiffNSView: NSView, NSTextViewDelegate {
    var onDirtyChange: ((Bool) -> Void)?
    /// Called with the full new file text (and its path) when you save edits made in the right pane.
    var onSave: ((String, String) -> Void)?
    var onSaveRefused: (() -> Void)?
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
    /// Hover on a working-file line (HEAD lines aren't what the language server has open).
    var onHover: ((Int, Int) -> Void)?
    private var cards: [NoteCardView] = []
    /// Where each card sits in its text view's coordinates; repositioned over the panes on scroll.
    private var cardPlaces: [(card: NoteCardView, left: Bool, rect: NSRect)] = []
    private(set) var isDirty = false { didSet { if oldValue != isDirty { onDirtyChange?(isDirty) } } }
    private var rehighlight: DispatchWorkItem?
    private var autosave: DispatchWorkItem?
    private var shownStaging: SectionStaging?
    /// The working-file bytes the right pane was built from (or last saved).
    var editBase: Data? { savedBase ?? shownStaging?.work.joined() }
    /// What the last save wrote, until the diff is redrawn from the saved file.
    private var savedBase: Data?
    private var shownLanguage: CodeLanguage = .plain
    var onToggle: ((Int, Bool, String) -> Void)?
    var onFoldClick: ((Int) -> Void)?
    var lastJump = 0
    var lastApprove = 0
    /// Every change in the file is reviewed: move on to the next file.
    var onFileDone: (() -> Void)?
    /// Space in a read-only pane.
    var onApproveKey: (() -> Void)?
    var shownVersion = -1

    private let (leftScroll, leftText) = CodeTextView.make()
    private let (rightScroll, rightText) = CodeTextView.make()
    private let gutter = RibbonGutterView()
    private let leftSticky = StickyLinesView(), rightSticky = StickyLinesView()
    private let messageLabel = NSTextField(labelWithString: "")
    private var diffLayout: DiffLayout?
    private var mode: RibbonGutterView.Mode = .split
    private var shownPath: String?
    private var shownLines: (head: TextLines, work: TextLines)?
    /// Show changed files in one pane (HEAD lines above the new ones) instead of side by side.
    var unified = false
    /// Sections clicked whose git command hasn't finished (shown as clicked).
    var pendingHunks: [Int: StageState] = [:]
    /// Unified mode: which side and display line each row of the one pane shows.
    private var unifiedRows: [(left: Bool, display: Int)]?
    /// Unified mode: right-side display line → its row in the one pane.
    private var unifiedOfRight: [Int: Int] = [:]
    private var unifiedHunks: [Int: Range<Int>] = [:]
    /// What's selected (or, with nothing selected, the line with the caret) in the pane that has
    /// focus: which side, the file lines, their text.
    func selectionInfo() -> (head: Bool, lines: ClosedRange<Int>, text: String, selected: Bool)? {
        guard let staging = shownStaging else { return nil }
        let tv = window?.firstResponder === leftText ? leftText : rightText
        let r = tv.selectedRange()
        let rows = tv.displayLines(of: r)
        let resolved = rows.compactMap { resolve(left: tv === leftText, displayLine: $0) }
        guard let first = resolved.first else { return nil }
        let side = resolved.filter { $0.left == first.left }.map(\.line)
        let lines = (side.min() ?? first.line)...(side.max() ?? first.line)
        let src = first.left ? staging.head : staging.work
        let text = lines.compactMap { $0 < src.count ? String(src.lines[$0].text) : nil }.joined(separator: "\n")
        return (first.left, lines, text, r.length > 0)
    }

    /// Test aid: types `text` at the end of the right pane's line containing `needle`, as typing would.
    func debugType(_ text: String, after needle: String) {
        let ns = rightText.string as NSString
        let r = ns.range(of: needle)
        guard r.location != NSNotFound else { return }
        window?.makeFirstResponder(rightText)
        rightText.setSelectedRange(NSRange(location: NSMaxRange(r), length: 0))
        rightText.insertText(text, replacementRange: rightText.selectedRange())
    }

    /// File lines visible in the new (right) pane.
    func visibleWorkLines() -> ClosedRange<Int>? {
        let clip = rightScroll.contentView.bounds
        let a = Int((clip.minY - DiffTheme.inset.height) / DiffTheme.lineHeight), b = Int((clip.maxY - DiffTheme.inset.height) / DiffTheme.lineHeight)
        let lines = (max(0, a)...max(0, b)).compactMap { resolve(left: false, displayLine: $0) }.filter { !$0.left }.map(\.line)
        guard let lo = lines.min(), let hi = lines.max() else { return nil }
        return lo...hi
    }

    /// The working-file pane, for reading aids (semantic colors, hints, lenses).
    var workPane: CodeTextView { rightText }
    /// The working-file text the pane was built from.
    var shownWorkText: String? { shownStaging?.work.joinedString() }
    /// A working-file line's row in its pane (nil when folded away).
    func workRow(ofFileLine line: Int) -> Int? { workRows[line] }
    private var workRows: [Int: Int] = [:]
    /// The HEAD side: its pane (the one pane in unified mode), text, and rows.
    var headPane: CodeTextView { unifiedRows == nil ? leftText : rightText }
    var shownHeadText: String? { mode == .rightOnly ? nil : shownStaging?.head.joinedString() }
    func headRow(ofFileLine line: Int) -> Int? { headRows[line] }
    private var headRows: [Int: Int] = [:]

    private struct Anchor { let left: Bool; let line: Int; let text: Substring; let offset: CGFloat }
    private var syncing = false
    private var split: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "diffSplit")
        return v == 0 ? 0.5 : v
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        for v in [leftScroll, rightScroll, gutter, messageLabel, leftSticky, rightSticky] as [NSView] { addSubview(v) }
        for (sticky, left) in [(leftSticky, true), (rightSticky, false)] {
            sticky.isHidden = true
            sticky.onClick = { [weak self] line in self?.scrollPane(left: left, toLine: line) }
        }
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 14)
        messageLabel.alignment = .center
        for scroll in [leftScroll, rightScroll] {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        for tv in [leftText, rightText] { tv.onFoldClick = { [weak self] id in self?.onFoldClick?(id) } }
        leftText.onSpace = { [weak self] in self?.onApproveKey?() }
        NotificationCenter.default.addObserver(self, selector: #selector(fontChanged), name: .vetCodeFontChanged, object: nil)
        // The working file (right side) can be edited and saved; HEAD (left) can't.
        rightText.isEditable = true
        rightText.allowsUndo = true
        rightText.delegate = self
        rightText.onSave = { [weak self] in self?.save() }
        leftText.contextItems = { [weak self] line, character in self?.menuItems(left: true, displayLine: line, character: character) ?? [] }
        rightText.contextItems = { [weak self] line, character in self?.menuItems(left: false, displayLine: line, character: character) ?? [] }
        leftText.onNavigate = { [weak self] kind, line, character in self?.navigate(kind, left: true, displayLine: line, character: character) }
        rightText.onNavigate = { [weak self] kind, line, character in self?.navigate(kind, left: false, displayLine: line, character: character) }
        rightText.onLensClick = { [weak self] lens in
            guard let self, let (side, fileLine) = self.resolve(left: false, displayLine: lens.line), !side else { return }
            self.onNavigate?(.references, false, fileLine, lens.character)
        }
        rightText.onHover = { [weak self] line, character in
            guard let self, let (side, fileLine) = self.resolve(left: false, displayLine: line), !side else { return }
            self.onHover?(fileLine, character)
        }
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
        savedBase = nil
        shownStaging = staging
        shownLanguage = doc.language
        rightText.isEditable = doc.change.kind != .deleted
        let keepLeft = leftScroll.contentView.bounds.origin, keepRight = rightScroll.contentView.bounds.origin
        // Keep the caret where it was (an autosave refreshes the pane while you're in it).
        let keepSelection = shownPath == doc.change.path ? rightText.selectedRange() : nil
        defer {
            if let keepSelection, NSMaxRange(keepSelection) <= (rightText.textStorage?.length ?? 0) { rightText.setSelectedRange(keepSelection) }
        }
        // Remember what you were reading (a line's text and number), not just a pixel offset,
        // so lines Claude inserts above it don't shift your place.
        let anchor = samePath ? readingAnchor() : nil
        shownPath = doc.change.path

        mode = switch doc.change.kind {
        case .added, .untracked: .rightOnly
        case .deleted: .leftOnly
        default: staging.head.count == 0 ? .rightOnly : unified ? .unified : .split
        }
        var states: [Int: StageState] = [:]
        for h in staging.hunks { states[h.id] = pendingHunks[h.id] ?? staging.state(of: h) }
        // Reviewed sections fold away (click one to see it again).
        let reviewed = UserDefaults.standard.object(forKey: "foldReviewed") as? Bool ?? true
            ? Set(staging.hunks.filter { states[$0.id] == .staged }.map(\.id)) : []
        let layout = DiffLayout(headCount: staging.head.count, workCount: staging.work.count,
                                hunks: staging.hunks, folding: folding, expanded: expanded,
                                notes: notes.map { .init(id: $0.id, left: $0.left, line: $0.line,
                                                         rows: NoteCardView.rows(for: $0.text, editing: $0.id == editingNoteID,
                                                                                 width: cardWidth(left: $0.left && mode != .unified))) }
                                    + Self.changeHeaderAnchors(staging, reviewed: reviewed),
                                reviewed: reviewed)
        diffLayout = layout

        var leftWords: [Int: [Range<Int>]] = [:], rightWords: [Int: [Range<Int>]] = [:]
        for h in staging.hunks {
            leftWords.merge(h.headCols) { $1 }
            rightWords.merge(h.workCols) { $1 }
        }
        leftWords = Self.readableWords(leftWords, staging.head)
        rightWords = Self.readableWords(rightWords, staging.work)
        // Changed words: the section's full color (IntelliJ's inner fragments); red and green in
        // the unified layout, where both sides share one column; faded once reviewed.
        var leftWordColor: [Int: NSColor] = [:], rightWordColor: [Int: NSColor] = [:]
        for h in staging.hunks {
            let staged = states[h.id] == .staged
            let l = DiffTheme.word(mode == .unified ? DiffTheme.unifiedRemovedWord : DiffTheme.modifiedWord, staged: staged)
            let r = DiffTheme.word(mode == .unified ? DiffTheme.unifiedAddedWord : DiffTheme.modifiedWord, staged: staged)
            for line in h.head { leftWordColor[line] = l }
            for line in h.work { rightWordColor[line] = r }
        }
        let leftAttr = Self.text(staging.head, layout.left, doc.language, words: leftWords, wordColor: leftWordColor, foldStarts: layout.foldHead.mapValues(\.lowerBound))
        let rightAttr = Self.text(staging.work, layout.right, doc.language, words: rightWords, wordColor: rightWordColor, foldStarts: layout.foldWork.mapValues(\.lowerBound))
        leftText.textStorage?.setAttributedString(leftAttr)
        defer { rightText.undoManager?.removeAllActions(withTarget: rightText.textStorage as Any) }
        if mode == .unified {
            buildUnified(layout, staging: staging, states: states, left: leftAttr, right: rightAttr)
        } else {
            unifiedRows = nil
            unifiedOfRight = [:]
            unifiedHunks = [:]
            rightText.textStorage?.setAttributedString(rightAttr)
        }

        var leftBands: [CodeTextView.Band] = [], rightBands: [CodeTextView.Band] = []
        var leftMarkers: [(Int, NSColor)] = [], rightMarkers: [(Int, NSColor)] = []
        var leftFolds: [Int: Int] = [:], rightFolds: [Int: Int] = [:]
        for s in layout.segments {
            switch s.kind {
            case .hunk(let id):
                guard let h = staging.hunks.first(where: { $0.id == id }) else { continue }
                let change = DiffTheme.change(head: h.head, work: h.work)
                let color = DiffTheme.marker(change)
                let fill = DiffTheme.fill(change, hasWords: !(h.headCols.isEmpty && h.workCols.isEmpty), staged: states[id] == .staged)
                // The side without lines gets a thin line in the ribbon's own color.
                _ = color
                if s.left.isEmpty { leftMarkers.append((s.left.lowerBound, fill)) }
                else { leftBands.append(.init(lines: s.left, color: fill)) }
                if s.right.isEmpty { rightMarkers.append((s.right.lowerBound, fill)) }
                else { rightBands.append(.init(lines: s.right, color: fill)) }
            case .fold(let id):
                leftFolds[s.left.lowerBound] = id
                rightFolds[s.right.lowerBound] = id
            case .same, .note: break
            }
        }
        leftText.bands = leftBands; rightText.bands = rightBands
        leftText.markers = leftMarkers.map { (line: $0.0, color: $0.1) }
        rightText.markers = rightMarkers.map { (line: $0.0, color: $0.1) }
        leftText.foldLines = leftFolds; rightText.foldLines = rightFolds
        if mode == .unified { applyUnifiedDecorations(layout, staging: staging, states: states) }
        placeCards(layout)
        placeSectionControls(layout, staging: staging, states: states)
        placeChangeHeaders(layout, staging: staging, states: states)
        leftText.window?.invalidateCursorRects(for: leftText)
        rightText.window?.invalidateCursorRects(for: rightText)

        gutter.mode = mode
        gutter.diffLayout = layout
        gutter.hunks = staging.hunks
        gutter.states = states
        gutter.snapshotID = staging.snapshotID
        gutter.leftNumbers = layout.left.map { if case .code(let l) = $0 { l } else { nil } }
        gutter.rightNumbers = layout.right.map { if case .code(let l) = $0 { l } else { nil } }
        if let rows = unifiedRows {
            // Both columns run down the one pane; context lines show both numbers.
            var old: [Int?] = [], new: [Int?] = []
            for seg in layout.segments {
                switch seg.kind {
                case .hunk:
                    for d in seg.left { old.append(gutter.leftNumbers[d]); new.append(nil) }
                    for d in seg.right { old.append(nil); new.append(gutter.rightNumbers[d]) }
                case .same:
                    for (k, d) in seg.right.enumerated() { old.append(gutter.leftNumbers[seg.left.lowerBound + k]); new.append(gutter.rightNumbers[d]) }
                case .fold, .note:
                    for _ in seg.right { old.append(nil); new.append(nil) }
                }
            }
            assert(old.count == rows.count)
            gutter.leftNumbers = old
            gutter.rightNumbers = new
        }
        gutter.unifiedRanges = unifiedHunks
        gutter.reload()
        workRows = [:]
        for (d, line) in layout.right.enumerated() {
            if case .code(let l) = line { workRows[l] = unifiedRows == nil ? d : unifiedOfRight[d] }
        }
        headRows = [:]
        if let rows = unifiedRows {
            for (u, row) in rows.enumerated() where row.left {
                if case .code(let l) = layout.left[row.display] { headRows[l] = u }
            }
        } else {
            for (d, line) in layout.left.enumerated() { if case .code(let l) = line { headRows[l] = d } }
        }
        rightText.inlayHints = []
        rightText.lenses = []

        // Every line is 18 pt, so the exact document height is known now; setting it up front
        // means restoring the scroll position isn't clamped by a half-laid-out text view.
        for (scroll, tv, count) in [(leftScroll, leftText, layout.left.count), (rightScroll, rightText, unifiedRows?.count ?? layout.right.count)] {
            let height = DiffTheme.inset.height * 2 + CGFloat(count) * DiffTheme.lineHeight
            tv.minSize = NSSize(width: 0, height: height)
            tv.setFrameSize(NSSize(width: max(tv.frame.width, scroll.contentSize.width), height: max(height, scroll.contentSize.height)))
        }
        leftScroll.isHidden = mode == .rightOnly || mode == .unified
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
                var line = first.right.lowerBound
                if case .hunk(let id) = first.kind, let r = unifiedHunks[id] { line = r.lowerBound }
                scrollRight(toLine: max(0, line - 4), animated: false)
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
            // In the unified pane every card sits in the one pane, under the note's line.
            let onLeft = note.left && unifiedRows == nil
            let tv = onLeft ? leftText : rightText
            if unifiedRows == nil, (note.left && mode == .rightOnly) || (!note.left && mode == .leftOnly) { continue } // that side isn't shown
            var rows = note.left ? seg.left : seg.right
            if unifiedRows != nil, let start = unifiedOfRight[seg.right.lowerBound] { rows = start..<(start + seg.right.count) }
            let editing = id == editingNoteID
            let card = NoteCardView(title: "Note on line \(note.line + 1)", text: note.text, editing: editing, sent: note.sent)
            card.onSave = { [weak self] text in self?.noteActions?.save(id, text) }
            card.onCancel = { [weak self] in self?.noteActions?.cancel(id) }
            card.onEdit = { [weak self] in self?.noteActions?.edit(id) }
            card.onDelete = { [weak self] in self?.noteActions?.delete(id) }
            let width = cardWidth(left: onLeft)
            // An overlay above both panes (TextKit 2's own views would cover a text view's subviews,
            // and the clip view routes clicks to its document); repositioned whenever a pane scrolls.
            addSubview(card)
            cards.append(card)
            cardPlaces.append((card, onLeft, NSRect(x: 14, y: tv.y(ofLine: rows.lowerBound) + 3, width: width,
                                                       height: CGFloat(rows.count) * DiffTheme.lineHeight - 6)))
            if editing { DispatchQueue.main.async { card.focus() } }
        }
    }

    /// A note card's width in its pane (the pane's width, up to 760 pt).
    private func cardWidth(left: Bool) -> CGFloat {
        let pane = (left ? leftScroll : rightScroll).contentSize.width
        let fallback = mode == .split ? (bounds.width - RibbonGutterView.width(for: .split)) / 2 : bounds.width - RibbonGutterView.width(for: mode)
        return min(760, max(260, (pane > 50 ? pane : fallback) - 28))
    }

    // MARK: Design variants: a header row above each change ("row" marker)

    /// One blank row above each change (under the line before it), where its header goes.
    private static func changeHeaderAnchors(_ staging: SectionStaging, reviewed: Set<Int>) -> [DiffLayout.NoteAnchor] {
        guard Design.marker == .row else { return [] }
        return staging.hunks.compactMap { h in
            h.work.lowerBound > 0 ? .init(id: "change-\(h.id)", left: false, line: h.work.lowerBound - 1, rows: 1) : nil
        }
    }

    private var headers: [(view: ChangeHeaderView, row: Int)] = []

    private func placeChangeHeaders(_ layout: DiffLayout, staging: SectionStaging, states: [Int: StageState]) {
        headers.forEach { $0.view.removeFromSuperview() }
        headers = []
        guard Design.marker == .row else { return }
        let total = staging.hunks.count
        for seg in layout.segments {
            guard case .note(let nid) = seg.kind, nid.hasPrefix("change-"), let id = Int(nid.dropFirst(7)),
                  let index = staging.hunks.firstIndex(where: { $0.id == id }) else { continue }
            let h = staging.hunks[index]
            let row = unifiedRows == nil ? seg.right.lowerBound : (unifiedOfRight[seg.right.lowerBound] ?? seg.right.lowerBound)
            let v = ChangeHeaderView(index: index + 1, of: total, added: h.work.count, removed: h.head.count,
                                     state: states[id] ?? .unstaged, tint: DiffTheme.marker(DiffTheme.change(head: h.head, work: h.work))) { [weak self] on in
                self?.onToggle?(id, on, staging.snapshotID)
            }
            addSubview(v)
            headers.append((v, row))
        }
        positionCards()
    }

    // MARK: Design variants: inline review buttons, the change map

    private var pills: [(button: NSButton, row: Int)] = []
    private let changeMap = ChangeMapView()

    /// "Mark Reviewed" buttons on each change (the inline design), and the change map strip.
    private func placeSectionControls(_ layout: DiffLayout, staging: SectionStaging, states: [Int: StageState]) {
        pills.forEach { $0.button.removeFromSuperview() }
        pills = []
        let total = max(1, unifiedRows?.count ?? layout.right.count)
        var marks: [ChangeMapView.Mark] = []
        for seg in layout.segments {
            guard case .hunk(let id) = seg.kind, let h = staging.hunks.first(where: { $0.id == id }) else { continue }
            let rows = unifiedHunks[id] ?? seg.right
            let staged = states[id] == .staged
            marks.append(.init(rows: rows, color: DiffTheme.marker(DiffTheme.change(head: h.head, work: h.work)), staged: staged))
            guard Design.marker == .inline, mode != .leftOnly else { continue }
            let b = ClosureButton(title: staged ? "Reviewed" : "Mark Reviewed") { [weak self] in
                self?.onToggle?(id, !staged, staging.snapshotID)
            }
            b.bezelStyle = .glass
            b.controlSize = .small
            b.image = NSImage(systemSymbolName: staged ? "checkmark.circle.fill" : "checkmark.circle", accessibilityDescription: nil)
            b.imagePosition = .imageLeading
            b.contentTintColor = staged ? DiffTheme.added : nil
            b.sizeToFit()
            addSubview(b)
            pills.append((b, rows.lowerBound))
        }
        changeMap.marks = marks
        changeMap.total = total
        changeMap.isHidden = Design.bridge != .map
        changeMap.onJump = { [weak self] row in self?.scrollRight(toLine: max(0, row - 4)) }
        if changeMap.superview == nil { addSubview(changeMap) }
        positionCards()
    }

    private func positionCards() {
        for h in headers {
            let r = convert(NSRect(x: 0, y: rightText.y(ofLine: h.row), width: 1, height: DiffTheme.lineHeight), from: rightText)
            h.view.frame = NSRect(x: rightScroll.frame.minX, y: r.minY, width: rightScroll.frame.width, height: DiffTheme.lineHeight)
            h.view.isHidden = r.maxY < rightScroll.frame.minY || r.minY > rightScroll.frame.maxY
        }
        // Inline review buttons: top-right of each change, in the new (right) pane.
        let scroll = rightScroll
        let clip = convert(scroll.contentView.bounds, from: scroll.contentView)
        for p in pills {
            let rowRect = convert(NSRect(x: 0, y: rightText.y(ofLine: p.row), width: 1, height: DiffTheme.lineHeight), from: rightText)
            let size = p.button.frame.size
            p.button.frame = NSRect(x: scroll.frame.maxX - size.width - 22, y: rowRect.minY - 1, width: size.width, height: size.height)
            p.button.isHidden = !clip.insetBy(dx: 0, dy: -4).contains(NSPoint(x: clip.midX, y: rowRect.midY))
        }
        if !changeMap.isHidden {
            changeMap.frame = NSRect(x: rightScroll.frame.maxX - 16, y: rightScroll.frame.minY, width: 16, height: rightScroll.frame.height)
            let doc = max(1, rightText.frame.height)
            changeMap.viewport = (rightScroll.contentView.bounds.minY / doc)...(rightScroll.contentView.bounds.maxY / doc)
        }
        for place in cardPlaces {
            let tv = place.left ? leftText : rightText, scroll = place.left ? leftScroll : rightScroll
            let frame = convert(place.rect, from: tv)
            place.card.frame = frame
            place.card.isHidden = scroll.isHidden || !frame.intersects(convert(scroll.contentView.bounds, from: scroll.contentView))
        }
    }

    /// The file line a pane's display line shows, and which side it's from (in the unified
    /// pane a row can be a HEAD line).
    private func resolve(left: Bool, displayLine d: Int) -> (left: Bool, line: Int)? {
        guard let layout = diffLayout else { return nil }
        var side = left, index = d
        if let rows = unifiedRows, !left {
            guard d >= 0, d < rows.count else { return nil }
            (side, index) = rows[d]
        }
        let display = side ? layout.left : layout.right
        guard index >= 0, index < display.count, case .code(let l) = display[index] else { return nil }
        return (side, l)
    }

    /// What a pane shows, row by row (unified HEAD rows read as non-code rows).
    private func paneDisplay(left: Bool, _ layout: DiffLayout) -> [DiffLayout.DisplayLine] {
        guard let rows = unifiedRows, !left else { return left ? layout.left : layout.right }
        return rows.map { $0.left ? .note(id: "", row: 0) : layout.right[$0.display] }
    }

    private func navigate(_ kind: CodeTextView.Navigation, left: Bool, displayLine: Int, character: Int) {
        guard let (side, line) = resolve(left: left, displayLine: displayLine) else { return }
        onNavigate?(kind, side, line, character)
    }

    // MARK: Unified layout

    /// One pane: unchanged and new lines from the working file, each section's HEAD lines
    /// above its new ones (read-only).
    private func buildUnified(_ layout: DiffLayout, staging: SectionStaging, states: [Int: StageState],
                              left: NSAttributedString, right: NSAttributedString) {
        func lineRanges(_ s: NSAttributedString) -> [NSRange] {
            let ns = s.string as NSString
            var out: [NSRange] = [], loc = 0
            while loc <= ns.length {
                let r = ns.range(of: "\n", options: .literal, range: NSRange(location: loc, length: ns.length - loc))
                let end = r.location == NSNotFound ? ns.length : r.location
                out.append(NSRange(location: loc, length: end - loc))
                if r.location == NSNotFound { break }
                loc = end + 1
            }
            return out
        }
        let leftLines = lineRanges(left), rightLines = lineRanges(right)
        var rows: [(left: Bool, display: Int)] = []
        var ofRight: [Int: Int] = [:], hunks: [Int: Range<Int>] = [:]
        for seg in layout.segments {
            let start = rows.count
            if case .hunk(let id) = seg.kind {
                rows += seg.left.map { (true, $0) }
                for d in seg.right { ofRight[d] = rows.count; rows.append((false, d)) }
                hunks[id] = start..<rows.count
            } else {
                for d in seg.right { ofRight[d] = rows.count; rows.append((false, d)) }
            }
        }
        let out = NSMutableAttributedString()
        out.beginEditing()
        for (i, row) in rows.enumerated() {
            let source = row.left ? left : right
            let ranges = row.left ? leftLines : rightLines
            guard row.display < ranges.count else { continue }
            let at = out.length
            let line = source.attributedSubstring(from: ranges[row.display])
            out.append(line)
            if i < rows.count - 1 {
                let attrs = line.length > 0 ? line.attributes(at: line.length - 1, effectiveRange: nil) : CodeText.baseAttributes
                out.append(NSAttributedString(string: "\n", attributes: attrs.filter { $0.key != .backgroundColor }))
            }
            if row.left { out.addAttribute(.vetRemoved, value: true, range: NSRange(location: at, length: out.length - at)) }
        }
        out.endEditing()
        rightText.textStorage?.setAttributedString(out)
        unifiedRows = rows
        unifiedOfRight = ofRight
        unifiedHunks = hunks
    }

    /// The one pane's section colors (HEAD lines red, new lines green), fold rows and the
    /// gutter's change bars.
    private func applyUnifiedDecorations(_ layout: DiffLayout, staging: SectionStaging, states: [Int: StageState]) {
        guard let rows = unifiedRows else { return }
        var bands: [CodeTextView.Band] = [], bars: [(rows: Range<Int>, color: NSColor)] = []
        var folds: [Int: Int] = [:]
        for seg in layout.segments {
            switch seg.kind {
            case .hunk(let id):
                guard let r = unifiedHunks[id] else { continue }
                let staged = states[id] == .staged
                let hasWords = staging.hunks.first { $0.id == id }.map { !($0.headCols.isEmpty && $0.workCols.isEmpty) } ?? false
                let removed = r.lowerBound..<(r.lowerBound + seg.left.count), added = removed.upperBound..<r.upperBound
                if !removed.isEmpty {
                    bands.append(.init(lines: removed, color: DiffTheme.fill(DiffTheme.unifiedRemoved, hasWords: hasWords, staged: staged)))
                    bars.append((removed, DiffTheme.removed))
                }
                if !added.isEmpty {
                    bands.append(.init(lines: added, color: DiffTheme.fill(DiffTheme.unifiedAdded, hasWords: hasWords, staged: staged)))
                    bars.append((added, DiffTheme.added))
                }
            case .fold(let id):
                guard let u = unifiedOfRight[seg.right.lowerBound] else { continue }
                folds[u] = id
            case .same, .note: break
            }
        }
        _ = rows
        rightText.bands = bands
        rightText.markers = []
        rightText.foldLines = folds
        gutter.unifiedBars = bars
        rightText.window?.invalidateCursorRects(for: rightText)
    }

    /// The diff's right-click menu, exactly as designed (spec §2.3).
    private func menuItems(left: Bool, displayLine: Int, character: Int) -> [NSMenuItem] {
        guard let staging = shownStaging, let (side, line) = resolve(left: left, displayLine: displayLine) else { return [] }
        let tv = left ? leftText : rightText
        let lines = side ? staging.head : staging.work
        let selection = tv.displayLines(of: tv.selectedRange())
        let fileLines = selection.compactMap { resolve(left: left, displayLine: $0) }.filter { $0.left == side }.map(\.line)
        let left = side
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
            item("Go to definition") { [weak self] in self?.onNavigate?(.definition, left, line, character) },
            item("Go to implementation") { [weak self] in self?.onNavigate?(.implementation, left, line, character) },
            item("Find references") { [weak self] in self?.onNavigate?(.references, left, line, character) },
            .separator(),
            item("Mark Selected Lines Reviewed", enabled: !left && !isDirty) { [weak self] in
                self?.onStageLines?(span.lowerBound..<(span.upperBound + 1), staging.snapshotID)
            },
            item("Mark Change Not Reviewed", enabled: hunk.map { staging.state(of: $0) != .unstaged } ?? false) { [weak self] in
                if let hunk { self?.onToggle?(hunk.id, false, staging.snapshotID) }
            },
            .separator(),
        ]
        items.insert(contentsOf: [
            item("Reference in Claude") { ClaudeReference.send(path: path, lines: span, code: code) },
            .separator(),
        ], at: 0)
        items.append(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        items.append(item("Copy path and line") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(path):\(span.lowerBound + 1)\(span.count > 1 ? "-\(span.upperBound + 1)" : "")", forType: .string)
        })
        items[2].toolTip = "⌘-click"
        return items
    }

    // MARK: Editing the working file

    func textDidChange(_ notification: Notification) {
        isDirty = true
        // Autosave a moment after typing stops.
        autosave?.cancel()
        let save = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save(quietly: true) } }
        autosave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: save)
        rightText.lenses = [] // their rows shift as you type; they come back with the next refresh
        rehighlight?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let storage = self.rightText.textStorage else { return }
            MainActor.assumeIsolated { CodeText.rehighlight(storage, language: self.shownLanguage) }
        }
        rehighlight = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func discardEdits() { isDirty = false }

    /// The right pane's text was just written to disk.
    func markSaved(_ bytes: Data) {
        savedBase = bytes
        isDirty = false
    }

    /// The whole file rebuilt from the edited right pane: fold rows become exactly the lines they
    /// hide, note rows are left out, unchanged lines keep their own endings. Nil (and a message)
    /// if a fold row was damaged, so nothing is written.
    func editedFileText() -> String? {
        guard let staging = shownStaging, let layout = diffLayout, let storage = rightText.textStorage else { return nil }
        let ns = storage.string as NSString
        var rows: [EditedText.Row] = []
        var location = 0
        for line in storage.string.components(separatedBy: "\n") {
            let length = (line as NSString).length
            let range = NSRange(location: location, length: min(length + 1, ns.length - location))
            var fold: Int?, note = false, foldElsewhere = false, foldLabel: String?
            if range.length > 0 {
                storage.enumerateAttribute(.vetFold, in: range) { value, r, _ in
                    guard let id = value as? Int else { return }
                    if r.location == location { fold = id } else { foldElsewhere = true }
                }
                if fold != nil { foldLabel = storage.attribute(.vetFoldLabel, at: location, effectiveRange: nil) as? String }
                storage.enumerateAttribute(.vetNote, in: range) { value, _, _ in if value != nil { note = true } }
                storage.enumerateAttribute(.vetRemoved, in: range) { value, _, _ in if value != nil { note = true } }
            }
            if foldElsewhere { return nil }
            if let fold {
                // The row must be exactly as built (its label after the chevron's space).
                guard let hidden = layout.foldWork[fold], let foldLabel, line == "      " + foldLabel else { return nil }
                rows.append(.original(hidden))
            } else if note {
                rows.append(.skip)
            } else {
                rows.append(.text(line))
            }
            location += length + 1
        }
        return String(decoding: EditedText.rebuild(rows: rows, original: staging.work), as: UTF8.self)
    }

    func save(quietly: Bool = false) {
        guard isDirty else { return }
        guard let text = editedFileText() else {
            if quietly { return } // an autosave just waits; ⌘S explains
            NSSound.beep()
            onSaveRefused?()
            return
        }
        onSave?(text, shownPath ?? "")
    }

    /// The first file line visible at the top of the main pane, and how far it's scrolled past.
    private func readingAnchor() -> Anchor? {
        guard let layout = diffLayout, let lines = shownLines else { return nil }
        let useLeft = mode == .leftOnly
        let scroll = useLeft ? leftScroll : rightScroll
        let display = paneDisplay(left: useLeft, layout)
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
        let display = paneDisplay(left: a.left, layout)
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

    /// Changed-word marks worth showing, as IntelliJ shows inner changes: none on a line that
    /// changed almost entirely (the line's color says it), and marks a space or a symbol apart
    /// joined into one.
    private static func readableWords(_ words: [Int: [Range<Int>]], _ lines: TextLines) -> [Int: [Range<Int>]] {
        var out: [Int: [Range<Int>]] = [:]
        for (line, ranges) in words where line < lines.count {
            let text = Array(lines.lines[line].text.utf16)
            let content = text.filter { $0 != 32 && $0 != 9 }.count
            var merged: [Range<Int>] = []
            for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = merged.last, r.lowerBound - last.upperBound <= 2 {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
                } else {
                    merged.append(r)
                }
            }
            let covered = merged.reduce(0) { sum, r in
                sum + text[min(r.lowerBound, text.count)..<min(r.upperBound, text.count)].filter { $0 != 32 && $0 != 9 }.count
            }
            if content > 0, Double(covered) / Double(content) >= 0.5 { continue }
            out[line] = merged
        }
        return out
    }

    /// Builds one pane's text: real lines with syntax colors and word highlights, plus fold rows.
    private static func text(_ lines: TextLines, _ display: [DiffLayout.DisplayLine], _ language: CodeLanguage,
                             words: [Int: [Range<Int>]], wordColor: [Int: NSColor], foldStarts: [Int: Int] = [:]) -> NSAttributedString {
        CodeText.attributed(lines, display, language, words: words, wordColor: wordColor, foldStarts: foldStarts)
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
        case .rightOnly, .unified:
            gutter.frame = NSRect(x: 0, y: 0, width: gw, height: h)
            rightScroll.frame = NSRect(x: gw, y: 0, width: w - gw, height: h)
        case .leftOnly:
            leftScroll.frame = NSRect(x: 0, y: 0, width: w - gw, height: h)
            gutter.frame = NSRect(x: w - gw, y: 0, width: gw, height: h)
        }
        messageLabel.frame = NSRect(x: 0, y: h / 2 - 12, width: w, height: 24)
        positionCards()
        updateSticky()
        window?.invalidateCursorRects(for: gutter)
    }

    override var isFlipped: Bool { true }

    // Drawn rather than layer-backed: a layer-backed container makes every tall pane keep a
    // full-size bitmap in memory.
    override func draw(_ dirtyRect: NSRect) {
        DiffTheme.background.setFill()
        dirtyRect.intersection(bounds).fill()
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

    /// The code text size changed: new font and row height in both panes, keeping any edits.
    @objc private func fontChanged() {
        guard let layout = diffLayout else { return }
        leftText.applyCodeFont()
        rightText.applyCodeFont()
        for (scroll, tv, count) in [(leftScroll, leftText, layout.left.count), (rightScroll, rightText, unifiedRows?.count ?? layout.right.count)] {
            let height = DiffTheme.inset.height * 2 + CGFloat(count) * DiffTheme.lineHeight
            tv.minSize = NSSize(width: 0, height: height)
            tv.setFrameSize(NSSize(width: max(tv.frame.width, scroll.contentSize.width), height: max(height, scroll.contentSize.height)))
        }
        placeCards(layout)
        gutter.reload()
        needsLayout = true
        syncGutter()
        leftSticky.needsDisplay = true
        rightSticky.needsDisplay = true
    }

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
        gutter.currentID = currentChangeID()
        gutter.leftOffset = mode == .unified ? rightScroll.contentView.bounds.origin.y : leftScroll.contentView.bounds.origin.y
        gutter.rightOffset = rightScroll.contentView.bounds.origin.y
        positionCards()
        updateSticky()
    }

    /// Each pane pins the enclosing declarations of its first visible line.
    private func updateSticky() {
        defer { if mode == .unified { gutter.leftPinned = rightSticky.rows.map(\.line) } }
        for (sticky, scroll, tv, visible) in [(leftSticky, leftScroll, leftText, mode == .split || mode == .leftOnly), (rightSticky, rightScroll, rightText, mode != .leftOnly)] {
            defer { if sticky === leftSticky { gutter.leftPinned = sticky.rows.map(\.line) } else { gutter.rightPinned = sticky.rows.map(\.line) } }
            guard visible, let storage = tv.textStorage, storage.length > 0 else { sticky.show([]); continue }
            let clip = scroll.contentView.bounds
            let first = Int((clip.minY - DiffTheme.inset.height) / DiffTheme.lineHeight)
            sticky.show(StickyLinesView.rows(in: storage, first: max(0, first)))
            sticky.scrollX = clip.minX
            let scrollerWidth = scroll.verticalScroller.map { $0.isHidden ? 0 : $0.frame.width } ?? 0
            sticky.frame = NSRect(x: scroll.frame.minX, y: scroll.frame.minY, width: scroll.frame.width - scrollerWidth, height: sticky.height)
        }
    }

    private func scrollPane(left: Bool, toLine line: Int) {
        let scroll = left ? leftScroll : rightScroll
        let y = DiffTheme.inset.height + CGFloat(line) * DiffTheme.lineHeight - scroll.contentView.bounds.height / 3
        let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: min(max(0, y), maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func scrollRight(toLine line: Int, animated: Bool = true) {
        let scroll = mode == .leftOnly ? leftScroll : rightScroll
        let y = DiffTheme.inset.height + CGFloat(line) * DiffTheme.lineHeight
        let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        let target = NSPoint(x: 0, y: min(max(0, y), maxY))
        // Jumps glide (the other pane follows), unless motion is reduced or the view is still loading.
        if animated, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                scroll.contentView.animator().setBoundsOrigin(target)
            } completionHandler: { [weak scroll] in
                MainActor.assumeIsolated { if let scroll { scroll.reflectScrolledClipView(scroll.contentView) } }
            }
        } else {
            scroll.contentView.scroll(to: target)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// The unreviewed change you're on: the topmost one still on screen, else the next below,
    /// else the last above.
    func currentChangeID() -> Int? {
        guard let layout = diffLayout, let staging = shownStaging else { return nil }
        let scroll = mode == .leftOnly ? leftScroll : rightScroll
        let anchor = Int((scroll.contentView.bounds.minY - DiffTheme.inset.height) / DiffTheme.lineHeight)
        var spans: [(id: Int, rows: Range<Int>)] = []
        for s in layout.segments {
            guard case .hunk(let id) = s.kind, let h = staging.hunks.first(where: { $0.id == id }),
                  (pendingHunks[id] ?? staging.state(of: h)) != .staged else { continue }
            let rows = unifiedHunks[id] ?? (mode == .leftOnly ? s.left : s.right)
            spans.append((id, rows.isEmpty ? rows.lowerBound..<(rows.lowerBound + 1) : rows))
        }
        if let onScreen = spans.first(where: { $0.rows.upperBound > anchor }) { return onScreen.id }
        return spans.last?.id
    }

    /// Approves the change you're on and scrolls to the next unreviewed one; with none left in
    /// this file, moves on to the next file.
    func approveAndNext() {
        guard let staging = shownStaging, let layout = diffLayout else { return }
        guard let id = currentChangeID() else { onFileDone?(); return }
        let remaining = staging.hunks.filter { $0.id != id && (pendingHunks[$0.id] ?? staging.state(of: $0)) != .staged }
        onToggle?(id, true, staging.snapshotID)
        // The next unreviewed change below this one, else the first one above.
        func row(_ s: DiffLayout.Segment) -> Int { if case .hunk(let n) = s.kind, let r = unifiedHunks[n] { r.lowerBound } else { s.right.lowerBound } }
        let pending = layout.segments.filter { s in if case .hunk(let n) = s.kind { remaining.contains { $0.id == n } } else { false } }
        let here = layout.segments.first { if case .hunk(let n) = $0.kind { n == id } else { false } }.map(row) ?? 0
        guard let next = pending.first(where: { row($0) > here }) ?? pending.first else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.onFileDone?() }
            return
        }
        var line = next.right.lowerBound
        if case .hunk(let n) = next.kind, let r = unifiedHunks[n] { line = r.lowerBound }
        let scroll = mode == .leftOnly ? leftScroll : rightScroll
        scrollRight(toLine: max(0, line - Int(scroll.contentView.bounds.height / DiffTheme.lineHeight / 3)))
    }

    /// Scrolls to the previous or next section relative to the middle of the view.
    func jump(forward: Bool) {
        guard let layout = diffLayout else { return }
        let scroll = mode == .leftOnly ? leftScroll : rightScroll
        let current = Int((scroll.contentView.bounds.minY + scroll.contentView.bounds.height / 3 - DiffTheme.inset.height) / DiffTheme.lineHeight)
        let starts = layout.segments.compactMap { s -> Int? in
            guard case .hunk(let id) = s.kind else { return nil }
            if let r = unifiedHunks[id] { return r.lowerBound }
            return mode == .leftOnly ? s.left.lowerBound : s.right.lowerBound
        }
        let target = forward ? starts.first { $0 > current + 1 } : starts.last { $0 < current - 1 }
        if let target { scrollRight(toLine: max(0, target - Int(scroll.contentView.bounds.height / DiffTheme.lineHeight / 3))) }
    }
}

/// A button that runs a closure.
final class ClosureButton: NSButton {
    private var run: () -> Void = {}
    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        run = action
        target = self
        self.action = #selector(fire)
    }
    @objc private func fire() { run() }
}

/// The change map: the whole file as a thin strip at the edge, each change a colored mark
/// (hollow once reviewed), the visible part outlined. Click to jump; it doubles as progress.
final class ChangeMapView: NSView {
    struct Mark { let rows: Range<Int>; let color: NSColor; let staged: Bool }
    var marks: [Mark] = [] { didSet { needsDisplay = true } }
    var total = 1 { didSet { needsDisplay = true } }
    var viewport: ClosedRange<CGFloat> = 0...0 { didSet { needsDisplay = true } }
    var onJump: ((Int) -> Void)?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        DiffTheme.header.setFill()
        bounds.fill()
        DiffTheme.foldPillBorder.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        let h = bounds.height
        let view = NSRect(x: 1, y: viewport.lowerBound * h, width: bounds.width - 2, height: max(6, (viewport.upperBound - viewport.lowerBound) * h))
        DiffTheme.foldPillHover.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: view, xRadius: 3, yRadius: 3).fill()
        for m in marks {
            let y = CGFloat(m.rows.lowerBound) / CGFloat(total) * h
            let r = NSRect(x: 4, y: y, width: bounds.width - 7, height: max(5, CGFloat(max(1, m.rows.count)) / CGFloat(total) * h))
            let p = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            if m.staged { m.color.withAlphaComponent(0.8).setStroke(); p.lineWidth = 1; p.stroke() } else { m.color.setFill(); p.fill() }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        onJump?(Int(y / max(1, bounds.height) * CGFloat(total)))
    }
}

/// The "row" design: a slim header above each change, with the system checkbox and what changed.
final class ChangeHeaderView: NSView {
    private let check: NSButton
    private let onToggle: (Bool) -> Void
    private let state: StageState
    private let tint: NSColor
    override var isFlipped: Bool { true }

    init(index: Int, of total: Int, added: Int, removed: Int, state: StageState, tint: NSColor, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        self.state = state
        self.tint = tint
        check = NSButton(checkboxWithTitle: "Reviewed", target: nil, action: nil)
        super.init(frame: .zero)
        check.allowsMixedState = true
        check.controlSize = .small
        check.font = .systemFont(ofSize: 11)
        check.state = switch state { case .staged: .on; case .unstaged: .off; case .partial: .mixed }
        check.target = self
        check.action = #selector(clicked)
        addSubview(check)
        let info = NSTextField(labelWithString: "Change \(index) of \(total)   +\(added)  −\(removed)")
        info.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        info.textColor = DiffTheme.foldLabel
        info.tag = 1
        addSubview(info)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() { onToggle(state != .staged) }

    override func layout() {
        super.layout()
        check.sizeToFit()
        check.frame.origin = NSPoint(x: 10, y: (bounds.height - check.frame.height) / 2)
        if let info = viewWithTag(1) as? NSTextField {
            info.sizeToFit()
            info.frame.origin = NSPoint(x: check.frame.maxX + 14, y: (bounds.height - info.frame.height) / 2)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        DiffTheme.header.setFill(); bounds.fill()
        tint.withAlphaComponent(state == .staged ? 0.35 : 0.9).setFill()
        NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        DiffTheme.foldPillBorder.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

