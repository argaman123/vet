import ImageIO
import AppKit
import VetCore

/// The middle of the diff: left line numbers, the ribbons joining each section's two sides,
/// a staging checkbox per section, and right line numbers. Dragging it resizes the panes.
final class RibbonGutterView: NSView {
    /// `unified`: one pane; both number columns (HEAD, working file) then the checkboxes.
    enum Mode { case split, rightOnly, leftOnly, unified }
    static let numbersWidth: CGFloat = 34
    static var ribbonWidth: CGFloat { Design.bridge == .map ? 10 : ringInBridge ? 44 : 30 }
    /// The review ring sits in the bridge (in a flat stretch on the taller side, so it always fits).
    static var ringInBridge: Bool { [.native, .mono, .check, .circle, .progress].contains(Design.marker) }
    static let ringZone: CGFloat = 20

    /// Where a change's bridge runs flat for its ring: the side with more lines.
    func ringOnRight(_ s: DiffLayout.Segment) -> Bool { s.right.count >= s.left.count }

    /// The band (one line tall) the ring sits in: centered between the two sides' first lines
    /// (each side's middle when it has one line or none), so both curves are mirror images.
    func ringBand(_ s: DiffLayout.Segment) -> (CGFloat, CGFloat) {
        func anchor(_ r: Range<Int>, left: Bool) -> CGFloat {
            r.isEmpty ? y(r.lowerBound, left: left) : y(r.lowerBound, left: left) + DiffTheme.lineHeight / 2
        }
        let cy = (anchor(s.left, left: true) + anchor(s.right, left: false)) / 2
        return (cy - DiffTheme.lineHeight / 2, cy + DiffTheme.lineHeight / 2)
    }
    /// Where the ring sits on a change's bridge: the neck's middle (ribbon), or halfway between the
    /// middles of the two blocks, which is always inside a smooth or straight band.
    func ringCenterY(_ s: DiffLayout.Segment) -> CGFloat {
        if Design.bridge == .ribbon { let (a, b) = ringBand(s); return (a + b) / 2 }
        func middle(_ r: Range<Int>, left: Bool) -> CGFloat { r.isEmpty ? y(r.lowerBound, left: left) : (y(r.lowerBound, left: left) + y(r.upperBound, left: left)) / 2 }
        return (middle(s.left, left: true) + middle(s.right, left: false)) / 2
    }
    /// Side by side, as WebStorm lays it out: old numbers, the bridge, new numbers, then the
    /// staging checkbox; each change's color runs unbroken through all of them.
    static var checkWidth: CGFloat { [.inline, .row, .native, .mono, .check, .circle, .progress].contains(Design.marker) ? 0 : 24 }

    var mode: Mode = .split { didSet { needsDisplay = true } }
    var diffLayout: DiffLayout?
    var hunks: [Hunk] = []
    var states: [Int: StageState] = [:]
    /// The change ⌘↩ / Space would approve (outlined in the accent color).
    var currentID: Int? { didSet { if oldValue != currentID { needsDisplay = true; markCurrentSeen() } } }
    /// The change you are on is seen from that moment: its mark turns from amber to blue.
    private func markCurrentSeen() {
        guard let id = currentID, let h = hunks.first(where: { $0.id == id }) else { return }
        Self.markSeen(change: changeKey(h))
        boxes[id]?.fresh = false
    }
    var leftNumbers: [Int?] = []  // display line → file line (nil for folds)
    var rightNumbers: [Int?] = []
    /// Display lines pinned at the top of each pane (sticky lines); their numbers cover the
    /// numbers of the lines scrolled under them.
    var leftPinned: [Int] = [] { didSet { if oldValue != leftPinned { needsDisplay = true; placeCheckboxes() } } }
    var rightPinned: [Int] = [] { didSet { if oldValue != rightPinned { needsDisplay = true; placeCheckboxes() } } }
    /// Unified mode: each section's rows in the one pane, and its colored change bars.
    var unifiedRanges: [Int: Range<Int>] = [:]
    var unifiedBars: [(rows: Range<Int>, color: NSColor)] = []
    var leftOffset: CGFloat = 0 { didSet { needsDisplay = true; placeCheckboxes() } }
    var rightOffset: CGFloat = 0 { didSet { needsDisplay = true; placeCheckboxes(); if !rightMarks.isEmpty { window?.invalidateCursorRects(for: self) } } }
    var onToggle: ((Int, Bool, String) -> Void)?
    /// The snapshot these checkboxes were drawn from; sent with every click.
    var snapshotID = ""
    var onDrag: ((CGFloat) -> Void)?
    var onResetSplit: (() -> Void)?
    private var boxes: [Int: StageToggle] = [:]
    /// Section id → its display segment, so drawing doesn't scan every segment per section.
    private var segments: [Int: DiffLayout.Segment] = [:]
    private var dragStart: CGFloat?

    override var isFlipped: Bool { true }

    /// The column after the working file's numbers for jump icons (implemented, overrides), as in
    /// JetBrains IDEs.
    static let marksWidth: CGFloat = 16

    static func width(for mode: Mode) -> CGFloat {
        switch mode {
        case .split: numbersWidth * 2 + ribbonWidth + checkWidth + marksWidth
        case .unified: numbersWidth * 2 + ribbonWidth + marksWidth
        case .rightOnly: numbersWidth + ribbonWidth + marksWidth
        case .leftOnly: numbersWidth + ribbonWidth
        }
    }

    /// Drawn every frame while scrolling: built once per theme, not per draw.
    private static var markImages: [String: NSImage] = [:]
    private static var numberCache: [Int: (text: NSAttributedString, size: NSSize)] = [:]
    private static var cacheTheme = ""
    private static func checkCaches() {
        let key = "\(DiffTheme.palette.id)|\(DiffTheme.fontSize)"
        if key != cacheTheme { cacheTheme = key; markImages = [:]; numberCache = [:] }
    }
    static func markImage(_ mark: LineNumberGutter.JumpMark) -> NSImage? {
        if let i = markImages[mark.symbol] { return i }
        let up = mark == .overrides
        let i: NSImage?
        switch Design.jumpIcon {
        case .arrows:
            let config = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium).applying(.init(paletteColors: [DiffTheme.accent]))
            i = NSImage(systemSymbolName: mark.symbol, accessibilityDescription: mark.help)?.withSymbolConfiguration(config)
        case .badge:
            // A soft tinted disc with the letter JetBrains uses: I (implemented below), O (overrides above).
            i = NSImage(size: NSSize(width: 13, height: 13), flipped: false) { r in
                let tint = up ? DiffTheme.accent : DiffTheme.hex(0x5FBF8A)
                tint.withAlphaComponent(0.22).setFill()
                NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: tint]
                let t = (up ? "O" : "I") as NSString, ts = t.size(withAttributes: attrs)
                t.draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2 + 0.3), withAttributes: attrs)
                return true
            }
        case .triangle, .chevron:
            let name = Design.jumpIcon == .triangle ? (up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill") : (up ? "chevron.up" : "chevron.down")
            let config = NSImage.SymbolConfiguration(pointSize: Design.jumpIcon == .triangle ? 7 : 9, weight: .semibold)
                .applying(.init(paletteColors: [DiffTheme.accent.withAlphaComponent(0.8)]))
            i = NSImage(systemSymbolName: name, accessibilityDescription: mark.help)?.withSymbolConfiguration(config)
        }
        markImages[mark.symbol] = i
        return i
    }
    /// A line number as text, laid out once (style 0 plain, 1 on a change, 2 the current change).
    static func numberText(_ n: Int, style: Int, attrs: [NSAttributedString.Key: Any]) -> (text: NSAttributedString, size: NSSize) {
        let key = n * 4 + style
        if let hit = numberCache[key] { return hit }
        let s = NSAttributedString(string: "\(n + 1)", attributes: attrs)
        let entry = (s, s.size())
        if numberCache.count > 20_000 { numberCache = [:] }
        numberCache[key] = entry
        return entry
    }

    /// Jump icons by working-file display row; a click on one asks for its targets.
    var rightMarks: [Int: LineNumberGutter.JumpMark] = [:] { didSet { if oldValue != rightMarks { needsDisplay = true; window?.invalidateCursorRects(for: self) } } }
    var onMarkClick: ((Int, NSRect) -> Void)?

    private func markRect(_ row: Int) -> NSRect {
        let s: CGFloat = 13
        return NSRect(x: bounds.width - Self.marksWidth + (Self.marksWidth - s) / 2 - 1, y: y(row, left: false) + (DiffTheme.lineHeight - s) / 2, width: s, height: s)
    }

    // MARK: Notes: a bubble beside the line (NotePopover.swift shows it)

    struct NoteMark: Equatable { let id: String; let fromClaude: Bool; var waiting = false }
    /// Claude's notes you have opened: from then on blue instead of amber. Kept per project (.vet/seen.json).
    private(set) static var seenNotes: Set<String> = []
    /// What needs you (a note you haven't sent, an answer you haven't read), and what is only waiting.
    /// Amber: new to you, not seen yet (a change you haven't looked at, a note you haven't opened).
    /// Once seen it turns the accent blue: it still needs you. What is settled or only waiting is dim grey.
    /// Claude's notes and summaries: an asterisk, a plain mark of "the AI's words" (not a product's logo).
    static let claudeSymbol = "asterisk"
    /// A note outside any change sits in the same column as the changes' marks.
    private func freeNoteRect(_ row: Int) -> NSRect {
        let r = noteRect(row)
        guard mode == .split else { return r }
        return NSRect(x: Self.numbersWidth * 2 + Self.ribbonWidth + 1, y: r.minY, width: Self.checkWidth - 2, height: r.height)
    }
    static let noteAmber = NSColor(srgbRed: 0.94, green: 0.66, blue: 0.29, alpha: 1)
    static let noteCalm = NSColor.white.withAlphaComponent(0.38)
    /// The changes you have already been on, by file and place (kept with the notes you've opened).
    private(set) static var seenChanges: Set<String> = []
    private static var seenFile: URL?
    private struct Seen: Codable { var changes: [String]; var notes: [String] }
    /// The project's record of what you've seen, read when the project opens.
    static func loadSeen(root: URL) {
        seenFile = ProjectFolder.url(root, "seen.json")
        let seen = seenFile.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Seen.self, from: $0) }
        seenChanges = Set(seen?.changes ?? []); seenNotes = Set(seen?.notes ?? [])
    }
    static func markSeen(note id: String) { if seenNotes.insert(id).inserted { saveSeen() } }
    private static func markSeen(change key: String) { if seenChanges.insert(key).inserted { saveSeen() } }
    /// Written at once (it changes only when you move to a change or open a note).
    private static func saveSeen() {
        guard let seenFile else { return }
        let seen = Seen(changes: Array(seenChanges), notes: Array(seenNotes))
        try? JSONEncoder().encode(seen).write(to: seenFile, options: .atomic)
    }
    /// The file on show: its changes count as seen once you move on to another.
    /// The file on show. A new one starts with no current change (ids are per file).
    var docKey = "" { didSet { if oldValue != docKey { currentID = nil } } }
    private func changeKey(_ h: Hunk) -> String { "\(docKey)#\(h.work.lowerBound):\(h.work.count):\(h.head.count)" }
    /// The rows of every change: a note there belongs to the change's one mark, not to an icon of its own.
    private var changeRows: IndexSet {
        var rows = IndexSet()
        for s in segments.values where !s.right.isEmpty { rows.insert(integersIn: s.right) }
        return rows
    }
    /// Notes on lines outside any change: these keep a mark of their own beside the line.
    private var freeNoteMarks: [Int: NoteMark] {
        guard mode == .split, Design.marker == .dot else { return noteMarks } // only there does a change have its one mark
        let taken = changeRows
        return noteMarks.filter { !taken.contains($0.key) }
    }
    /// The note a change's mark speaks for: yours that needs sending first, then Claude's, then one that is waiting.
    func note(inChange id: Int) -> NoteMark? {
        guard let s = segments[id], !s.right.isEmpty else { return nil }
        let here = noteMarks.filter { s.right.contains($0.key) }.sorted { $0.key < $1.key }.map(\.value)
        return here.first { !$0.fromClaude && !$0.waiting } ?? here.first { $0.fromClaude } ?? here.first
    }
    private var spinTimer: Timer?
    /// The waiting spinners turn while any are shown (still, with Reduce Motion).
    private func updateSpinTimer() {
        let spinning = noteMarks.values.contains { $0.waiting } && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if spinning, spinTimer == nil {
            spinTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window != nil else { self?.spinTimer?.invalidate(); self?.spinTimer = nil; return }
                    // Only the spinners redraw.
                    for (row, mark) in self.freeNoteMarks where mark.waiting { self.setNeedsDisplay(self.freeNoteRect(row)) }
                    self.boxes.values.forEach { if $0.note?.waiting == true { $0.needsDisplay = true } }
                }
            }
        } else if !spinning { spinTimer?.invalidate(); spinTimer = nil }
    }
    /// Notes by working-file display row. A note's bubble takes the icon column on its row.
    var noteMarks: [Int: NoteMark] = [:] { didSet { if oldValue != noteMarks { needsDisplay = true; window?.invalidateCursorRects(for: self); updateSpinTimer(); placeCheckboxes() } } }
    /// A note's bubble was clicked: (note id, the bubble's rect).
    var onNoteClick: ((String, NSRect) -> Void)?
    /// The faint bubble on a hovered row was clicked: (working-file line, the bubble's rect).
    var onAddNote: ((Int, NSRect) -> Void)?
    /// The row whose numbers the pointer is over: it shows a faint bubble to add a note.
    private var addRow: Int? { didSet { if oldValue != addRow { needsDisplay = true } } }
    private var noteTracking: NSTrackingArea?

    func noteRect(_ row: Int) -> NSRect { markRect(row) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let noteTracking { removeTrackingArea(noteTracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        noteTracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Only over the working file's numbers and the icon column, so passing by doesn't flicker.
        guard mode != .leftOnly, p.x >= bounds.width - Self.marksWidth - Self.numbersWidth,
              p.y > covered.top, p.y < bounds.height - covered.bottom else { addRow = nil; return }
        let row = Int(floor((p.y + rightOffset - DiffTheme.inset.height) / DiffTheme.lineHeight))
        addRow = row >= 0 && row < rightNumbers.count && rightNumbers[row] != nil && noteMarks[row] == nil ? row : nil
    }

    override func mouseExited(with event: NSEvent) { addRow = nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateSpinTimer() }

    private static func noteImage(_ name: String, alpha: CGFloat, color: NSColor? = nil) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium)
            .applying(.init(paletteColors: [(color ?? DiffTheme.text).withAlphaComponent(alpha)]))
        return NSImage(systemSymbolName: name, accessibilityDescription: "Note")?.withSymbolConfiguration(config)
    }

    private func drawNotes() {
        guard mode != .leftOnly else { return }
        func visible(_ r: NSRect) -> Bool { r.maxY > covered.top && r.minY < bounds.height - covered.bottom }
        for (row, mark) in freeNoteMarks {
            let r = freeNoteRect(row)
            guard visible(r) else { continue }
            let c = NSPoint(x: r.midX, y: r.midY)
            if mark.fromClaude {
                // An answer or a note from Claude: in the attention color until you open it, then grey.
                let seen = Self.seenNotes.contains(mark.id)
                guard let image = Self.noteImage(Self.claudeSymbol, alpha: 1, color: seen ? DiffTheme.accent : Self.noteAmber) else { continue }
                let size = image.size
                image.draw(in: NSRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height))
            } else if mark.waiting {
                // Sent: Claude is on it, nothing for you to do. A calm spinner.
                let track = NSBezierPath(ovalIn: NSRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9))
                track.lineWidth = 1.6
                NSColor.white.withAlphaComponent(0.14).setStroke(); track.stroke()
                let turn = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : CGFloat(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9) * 360
                let arc = NSBezierPath()
                arc.appendArc(withCenter: c, radius: 4.5, startAngle: 90 - turn, endAngle: 90 - turn - 100, clockwise: true)
                arc.lineWidth = 1.6; arc.lineCapStyle = .round
                NSColor.white.withAlphaComponent(0.6).setStroke(); arc.stroke()
            } else {
                // Written, not sent yet: an outline.
                Self.noteAmber.setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7).insetBy(dx: 0.75, dy: 0.75)); ring.lineWidth = 1.5; ring.stroke()
            }
        }
        if let addRow, visible(noteRect(addRow)), let image = Self.noteImage("plus.bubble", alpha: 0.35) {
            let r = noteRect(addRow), size = image.size
            image.draw(in: NSRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width, height: size.height))
        }
    }

    private func drawMarks() {
        guard mode != .leftOnly, !rightMarks.isEmpty else { return }
        for (row, mark) in rightMarks {
            let r = markRect(row)
            guard r.maxY > covered.top, r.minY < bounds.height - covered.bottom, let image = Self.markImage(mark) else { continue }
            let size = image.size
            image.draw(in: NSRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width, height: size.height))
        }
    }

    func reload() {
        for b in boxes.values { b.removeFromSuperview() }
        boxes = [:]
        segments = [:]
        for seg in diffLayout?.segments ?? [] { if case .hunk(let id) = seg.kind { segments[id] = seg } }
        for h in hunks {
            let b = StageToggle(id: h.id) { [weak self] id in self?.toggled(id) }
            b.onNote = { [weak self, weak b] noteID in if let self, let b { self.onNoteClick?(noteID, b.frame) } }
            let key = changeKey(h)
            b.fresh = !Self.seenChanges.contains(key)
            b.tint = DiffTheme.marker(DiffTheme.change(head: h.head, work: h.work))
            b.isHidden = Design.marker == .inline || Design.marker == .row
            addSubview(b)
            boxes[h.id] = b
        }
        updateStates()
        placeCheckboxes()
        needsDisplay = true
    }

    func updateStates() {
        for (id, b) in boxes { b.state = states[id] ?? .unstaged }
        needsDisplay = true
    }

    /// A click flips the section between staged and not (a mixed box stages the rest), from the
    /// state on screen, and shows the result at once; the button's own off→mixed→on cycle would
    /// read a quick second click as "stage" again.
    /// Shows a section's new state at once (the diff reloads with it a moment later).
    func show(_ id: Int, _ state: StageState) {
        states[id] = state
        boxes[id]?.state = state
        needsDisplay = true
    }

    private func toggled(_ id: Int) {
        let stage = states[id] != .staged
        states[id] = stage ? .staged : .unstaged
        boxes[id]?.state = states[id]!
        onToggle?(id, stage, snapshotID)
    }


    private func y(_ line: Int, left: Bool) -> CGFloat {
        DiffTheme.inset.height + CGFloat(line) * DiffTheme.lineHeight - (left ? leftOffset : rightOffset)
    }

    private func segment(for id: Int) -> DiffLayout.Segment? { segments[id] }

    private var ribbonX: (CGFloat, CGFloat) {
        switch mode {
        case .split: (Self.numbersWidth, Self.numbersWidth + Self.ribbonWidth)
        case .rightOnly: (0, Self.ribbonWidth)
        case .leftOnly: (Self.numbersWidth, Self.numbersWidth + Self.ribbonWidth)
        case .unified: (Self.numbersWidth * 2, Self.numbersWidth * 2 + Self.ribbonWidth)
        }
    }

    private func placeCheckboxes() {
        defer { if mode == .split { window?.invalidateCursorRects(for: self) } }
        let (x0, x1) = ribbonX
        if Design.marker == .inline || Design.marker == .row { boxes.values.forEach { $0.isHidden = true }; return }
        for (id, b) in boxes {
            if mode == .unified {
                guard let r = unifiedRanges[id] else { b.isHidden = true; continue }
                let cy = (y(r.lowerBound, left: false) + y(r.upperBound, left: false)) / 2
                b.frame = NSRect(x: (x0 + x1) / 2 - 9, y: cy - 9, width: 18, height: 18)
                b.isHidden = cy < -20 || cy > bounds.height + 20
                continue
            }
            guard let s = segment(for: id) else { b.isHidden = true; continue }
            if mode == .split, [.native, .mono, .check, .circle, .progress].contains(b.style) {
                // In the bridge's flat stretch on the taller side, centered on that side's first line.
                let cy = ringCenterY(s)
                let cx = Self.numbersWidth + Self.ribbonWidth / 2
                b.frame = NSRect(x: cx - 8, y: cy - 8, width: 16, height: 16)
                // Under the sticky rows' band (or the header's glass) the ring hides, as its code does.
                let under = pinnedBand.map { cy - 8 < $0.upperBound + 4 } ?? (cy < covered.top)
                b.isHidden = cy < -20 || cy > bounds.height + 20 || under
                continue
            }
            if mode == .split {
                // At the change's first new line; for removed lines, beside where the ribbon starts.
                // Removed lines: centered on the line where they were removed (kept inside the view
                // at the very top of the file).
                let top = s.right.isEmpty ? max(y(0, left: false) - DiffTheme.inset.height + 1, y(s.right.lowerBound, left: false) - DiffTheme.lineHeight / 2)
                    : y(s.right.lowerBound, left: false)
                let x = Self.numbersWidth * 2 + Self.ribbonWidth + (Self.checkWidth - 16) / 2
                if Design.marker == .dot {
                    // The dot's cell: room for the round button it grows into under the pointer.
                    let w = Self.checkWidth - 2
                    // One mark for the change and its note. Accepted: the note no longer matters.
                    b.note = b.state == .staged ? nil : note(inChange: id)
                    // (Claude's note opens into a two-part pill: room for it to the right.)
                    b.frame = NSRect(x: Self.numbersWidth * 2 + Self.ribbonWidth + 1, y: top + (DiffTheme.lineHeight - w) / 2, width: b.note?.fromClaude == true ? w + 18 : w, height: w)
                } else if Design.marker == .bar {
                    let bottom = s.right.isEmpty ? top + DiffTheme.lineHeight : y(s.right.upperBound, left: false)
                    b.frame = NSRect(x: x, y: top, width: 16, height: bottom - top)
                } else {
                    b.frame = NSRect(x: x, y: top + (DiffTheme.lineHeight - 16) / 2, width: 16, height: 16)
                }
                b.isHidden = top < -20 || top > bounds.height + 20
                continue
            }
            let ly = (y(s.left.lowerBound, left: true) + y(s.left.upperBound, left: true)) / 2
            let ry = (y(s.right.lowerBound, left: false) + y(s.right.upperBound, left: false)) / 2
            let cy = mode == .leftOnly ? ly : mode == .rightOnly ? ry : (ly + ry) / 2
            let size = NSSize(width: 18, height: 18)
            b.frame = NSRect(x: (x0 + x1) / 2 - size.width / 2, y: cy - size.height / 2, width: size.width, height: size.height)
            b.isHidden = cy < -20 || cy > bounds.height + 20
        }
    }

    override func layout() {
        super.layout()
        placeCheckboxes()
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.checkCaches()
        DiffTheme.gutter.setFill()
        bounds.fill()
        guard let diffLayout else { return }
        // Ribbons.
        if mode == .split && Design.bridge != .map {
            let (x0, x1) = ribbonX
            for h in hunks {
                guard let s = segment(for: h.id) else { continue }
                // A side with no lines ends in a short notch around its marker, not a hairline.
                var l0 = y(s.left.lowerBound, left: true), l1 = y(s.left.upperBound, left: true)
                if s.left.isEmpty { l0 -= 1; l1 = l0 + 2 }
                var r0 = y(s.right.lowerBound, left: false), r1 = y(s.right.upperBound, left: false)
                if s.right.isEmpty { r0 -= 1; r1 = r0 + 2 }
                if max(l1, r1) < dirtyRect.minY || min(l0, r0) > dirtyRect.maxY { continue } // off screen
                let staged = states[h.id] == .staged
                // WebStorm's curve: control points at 30% and 70% across the ribbon.
                let path = NSBezierPath()
                let c1 = x0 + (x1 - x0) * 0.45, c2 = x0 + (x1 - x0) * 0.55
                if Design.bridge == .straight {
                    // Straight edges between the two blocks.
                    path.move(to: NSPoint(x: 0, y: l0))
                    path.line(to: NSPoint(x: x0, y: l0))
                    path.line(to: NSPoint(x: x1, y: r0))
                    path.line(to: NSPoint(x: bounds.width, y: r0))
                    path.line(to: NSPoint(x: bounds.width, y: r1))
                    path.line(to: NSPoint(x: x1, y: r1))
                    path.line(to: NSPoint(x: x0, y: l1))
                    path.line(to: NSPoint(x: 0, y: l1))
                } else if Design.bridge == .flow || Design.bridge == .thread {
                    // One smooth band: each edge an S whose handles reach halfway across.
                    let m = (x0 + x1) / 2
                    path.move(to: NSPoint(x: 0, y: l0))
                    path.line(to: NSPoint(x: x0, y: l0))
                    path.curve(to: NSPoint(x: x1, y: r0), controlPoint1: NSPoint(x: m, y: l0), controlPoint2: NSPoint(x: m, y: r0))
                    path.line(to: NSPoint(x: bounds.width, y: r0))
                    path.line(to: NSPoint(x: bounds.width, y: r1))
                    path.line(to: NSPoint(x: x1, y: r1))
                    path.curve(to: NSPoint(x: x0, y: l1), controlPoint1: NSPoint(x: m, y: r1), controlPoint2: NSPoint(x: m, y: l1))
                    path.line(to: NSPoint(x: 0, y: l1))
                } else if Self.ringInBridge && mode == .split {
                    // The ring sits in the middle of the bridge, in a flat band one line tall at the
                    // taller side's first line; each side curves into that band.
                    let (m0, m1) = ringBand(s)
                    let mid = Self.numbersWidth + Self.ribbonWidth / 2, a = mid - Self.ringZone / 2, b = mid + Self.ringZone / 2
                    let k = (a - x0) * 0.5
                    path.move(to: NSPoint(x: 0, y: l0))
                    path.line(to: NSPoint(x: x0, y: l0))
                    path.curve(to: NSPoint(x: a, y: m0), controlPoint1: NSPoint(x: x0 + k, y: l0), controlPoint2: NSPoint(x: a - k, y: m0))
                    path.line(to: NSPoint(x: b, y: m0))
                    path.curve(to: NSPoint(x: x1, y: r0), controlPoint1: NSPoint(x: b + k, y: m0), controlPoint2: NSPoint(x: x1 - k, y: r0))
                    path.line(to: NSPoint(x: bounds.width, y: r0))
                    path.line(to: NSPoint(x: bounds.width, y: r1))
                    path.line(to: NSPoint(x: x1, y: r1))
                    path.curve(to: NSPoint(x: b, y: m1), controlPoint1: NSPoint(x: x1 - k, y: r1), controlPoint2: NSPoint(x: b + k, y: m1))
                    path.line(to: NSPoint(x: a, y: m1))
                    path.curve(to: NSPoint(x: x0, y: l1), controlPoint1: NSPoint(x: a - k, y: m1), controlPoint2: NSPoint(x: x0 + k, y: l1))
                    path.line(to: NSPoint(x: 0, y: l1))
                } else {
                    path.move(to: NSPoint(x: 0, y: l0))
                    path.line(to: NSPoint(x: x0, y: l0))
                    path.curve(to: NSPoint(x: x1, y: r0), controlPoint1: NSPoint(x: c1, y: l0), controlPoint2: NSPoint(x: c2, y: r0))
                    path.line(to: NSPoint(x: bounds.width, y: r0))
                    path.line(to: NSPoint(x: bounds.width, y: r1))
                    path.line(to: NSPoint(x: x1, y: r1))
                    path.curve(to: NSPoint(x: x0, y: l1), controlPoint1: NSPoint(x: c2, y: r1), controlPoint2: NSPoint(x: c1, y: l1))
                    path.line(to: NSPoint(x: 0, y: l1))
                }
                path.close()
                let change = DiffTheme.change(head: h.head, work: h.work)
                if Design.bridge == .thread {
                    // The blocks keep their color in the number columns; between them only a thin
                    // curve joins their middles, broken where the ring sits on it.
                    DiffTheme.fill(change, hasWords: false, staged: staged).setFill()
                    NSRect(x: 0, y: l0, width: x0, height: l1 - l0).fill()
                    NSRect(x: x1, y: r0, width: bounds.width - x1, height: r1 - r0).fill()
                    let lc = (l0 + l1) / 2, rc = (r0 + r1) / 2, m = (x0 + x1) / 2
                    let thread = NSBezierPath()
                    thread.move(to: NSPoint(x: x0, y: lc))
                    thread.curve(to: NSPoint(x: x1, y: rc), controlPoint1: NSPoint(x: m, y: lc), controlPoint2: NSPoint(x: m, y: rc))
                    thread.lineWidth = 1.5
                    thread.lineCapStyle = .round
                    NSGraphicsContext.saveGraphicsState()
                    if Self.ringInBridge {
                        let hole = NSBezierPath(rect: bounds)
                        hole.append(NSBezierPath(ovalIn: NSRect(x: m - 10, y: (lc + rc) / 2 - 10, width: 20, height: 20)))
                        hole.windingRule = .evenOdd
                        hole.addClip()
                    }
                    DiffTheme.marker(change).withAlphaComponent(staged ? 0.35 : 0.75).setStroke()
                    thread.stroke()
                    NSGraphicsContext.restoreGraphicsState()
                    continue
                }
                if Design.bridge == .lines {
                    // Just the two edges, in the change's color: light, and the code stays the focus.
                    let edges = NSBezierPath()
                    edges.move(to: NSPoint(x: x0, y: l0))
                    edges.curve(to: NSPoint(x: x1, y: r0), controlPoint1: NSPoint(x: c1, y: l0), controlPoint2: NSPoint(x: c2, y: r0))
                    edges.move(to: NSPoint(x: x0, y: l1))
                    edges.curve(to: NSPoint(x: x1, y: r1), controlPoint1: NSPoint(x: c1, y: l1), controlPoint2: NSPoint(x: c2, y: r1))
                    edges.lineWidth = 1.5
                    DiffTheme.marker(change).withAlphaComponent(staged ? 0.35 : 0.9).setStroke()
                    edges.stroke()
                    DiffTheme.fill(change, hasWords: false, staged: staged).setFill()
                    NSRect(x: 0, y: l0, width: x0, height: l1 - l0).fill()
                    NSRect(x: x1, y: r0, width: bounds.width - x1, height: r1 - r0).fill()
                    continue
                }
                let fill = DiffTheme.fill(change, hasWords: !(h.headCols.isEmpty && h.workCols.isEmpty), staged: staged)
                fill.setFill()
                path.fill()
            }
        }
        // Folded rows: the wave continues through the number columns (each side at its own scroll).
        for s in diffLayout.segments {
            guard case .fold(let fid) = s.kind else { continue }
            if fid < 0, mode == .split { // a reviewed change: the same quiet green band as in the panes
                DiffTheme.reviewedBand.setFill()
                NSRect(x: 0, y: y(s.left.lowerBound, left: true), width: Self.numbersWidth, height: DiffTheme.lineHeight).fill()
                let x1 = Self.numbersWidth + Self.ribbonWidth
                NSRect(x: x1, y: y(s.right.lowerBound, left: false), width: bounds.width - x1, height: DiffTheme.lineHeight).fill()
                let l0 = y(s.left.lowerBound, left: true), r0 = y(s.right.lowerBound, left: false), h = DiffTheme.lineHeight
                let p = NSBezierPath()
                p.move(to: NSPoint(x: Self.numbersWidth, y: l0))
                p.curve(to: NSPoint(x: x1, y: r0), controlPoint1: NSPoint(x: Self.numbersWidth + Self.ribbonWidth / 2, y: l0), controlPoint2: NSPoint(x: Self.numbersWidth + Self.ribbonWidth / 2, y: r0))
                p.line(to: NSPoint(x: x1, y: r0 + h))
                p.curve(to: NSPoint(x: Self.numbersWidth, y: l0 + h), controlPoint1: NSPoint(x: Self.numbersWidth + Self.ribbonWidth / 2, y: r0 + h), controlPoint2: NSPoint(x: Self.numbersWidth + Self.ribbonWidth / 2, y: l0 + h))
                p.close(); p.fill()
                continue
            }
            switch mode {
            case .split:
                CodeTextView.drawWave(in: NSRect(x: 0, y: y(s.left.lowerBound, left: true), width: Self.numbersWidth, height: DiffTheme.lineHeight))
                let x1 = Self.numbersWidth + Self.ribbonWidth
                CodeTextView.drawWave(in: NSRect(x: x1, y: y(s.right.lowerBound, left: false), width: bounds.width - x1, height: DiffTheme.lineHeight))
            case .rightOnly:
                CodeTextView.drawWave(in: NSRect(x: 0, y: y(s.right.lowerBound, left: false), width: bounds.width, height: DiffTheme.lineHeight))
            case .leftOnly:
                CodeTextView.drawWave(in: NSRect(x: 0, y: y(s.left.lowerBound, left: true), width: bounds.width, height: DiffTheme.lineHeight))
            case .unified:
                break
            }
        }
        // Line numbers.
        let attrs: [NSAttributedString.Key: Any] = [.font: DiffTheme.numberFont, .foregroundColor: DiffTheme.lineNumber]
        // Numbers on a changed row sit on its color: brighter, so they stay readable. A reviewed
        // change has only a faint wash, so its numbers stay plain.
        var changedLeft = IndexSet(), changedRight = IndexSet()
        if mode == .unified {
            for (id, r) in unifiedRanges where states[id] != .staged { changedLeft.insert(integersIn: r); changedRight.insert(integersIn: r) }
        } else {
            for (id, s) in segments where states[id] != .staged { changedLeft.insert(integersIn: s.left); changedRight.insert(integersIn: s.right) }
        }
        let bright: [NSAttributedString.Key: Any] = [.font: DiffTheme.numberFont, .foregroundColor: DiffTheme.lineNumberCurrent]
        // The change ⌘↩ approves next: its line numbers in the accent color.
        let lit: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: DiffTheme.numberFont.pointSize, weight: .semibold),
                                                  .foregroundColor: DiffTheme.accent]
        var currentLeft = IndexSet(), currentRight = IndexSet()
        if let currentID {
            if mode == .unified, let r = unifiedRanges[currentID] { currentLeft.insert(integersIn: r); currentRight.insert(integersIn: r) }
            else if let s = segments[currentID] { currentLeft.insert(integersIn: s.left); currentRight.insert(integersIn: s.right) }
        }
        func number(_ n: Int, x: CGFloat, y: CGFloat, changed: Bool = false, current: Bool = false) {
            let (s, size) = Self.numberText(n, style: current ? 2 : changed ? 1 : 0, attrs: current ? lit : changed ? bright : attrs)
            s.draw(at: NSPoint(x: x + Self.numbersWidth - 4 - size.width, y: y + (DiffTheme.lineHeight - size.height) / 2))
        }
        func numbers(_ list: [Int?], left: Bool, x: CGFloat) {
            let pinned = left ? leftPinned : rightPinned
            let band = pinned.isEmpty ? 0 : CGFloat(pinned.count) * DiffTheme.lineHeight + 2
            let first = max(0, Int(((left ? leftOffset : rightOffset) - DiffTheme.inset.height) / DiffTheme.lineHeight))
            let count = Int(bounds.height / DiffTheme.lineHeight) + 2
            // The pinned rows sit just below the floating header, like the panes' sticky lines.
            let top = covered.top
            NSGraphicsContext.saveGraphicsState()
            let open = NSBezierPath(rect: NSRect(x: x, y: 0, width: Self.numbersWidth, height: top))
            open.append(NSBezierPath(rect: NSRect(x: x, y: top + band, width: Self.numbersWidth, height: max(0, bounds.height - top - band))))
            open.addClip()
            let changed = left ? changedLeft : changedRight, current = left ? currentLeft : currentRight
            // (A side can end above the view, when the other side is longer: nothing to number then.)
            for i in first..<max(first, min(list.count, first + count)) {
                if let n = list[i] { number(n, x: x, y: y(i, left: left), changed: changed.contains(i), current: current.contains(i)) }
            }
            NSGraphicsContext.restoreGraphicsState()
            guard band > 0 else { return }
            // Like the panes' sticky rows: solid up to the glass, fading out below.
            let lead = top > 0 ? StickyLinesView.glassGap : 0, solid = band - 2
            let bg = DiffTheme.background.withAlphaComponent(1)
            bg.setFill()
            NSRect(x: x, y: top - lead, width: Self.numbersWidth, height: lead + solid).fill()
            NSGradient(starting: bg, ending: bg.withAlphaComponent(0))?.draw(in: NSRect(x: x, y: top + solid, width: Self.numbersWidth, height: StickyLinesView.tail), angle: 90)
            for (row, line) in pinned.enumerated() where line < list.count {
                if let n = list[line] { number(n, x: x, y: top + CGFloat(row) * DiffTheme.lineHeight) }
            }
        }
        switch mode {
        case .split:
            numbers(leftNumbers, left: true, x: 0)
            numbers(rightNumbers, left: false, x: Self.numbersWidth + Self.ribbonWidth)
        case .rightOnly: numbers(rightNumbers, left: false, x: Self.ribbonWidth)
        case .leftOnly: numbers(leftNumbers, left: true, x: 0)
        case .unified:
            let x = Self.numbersWidth * 2 + 3
            for bar in unifiedBars {
                bar.color.setFill()
                NSRect(x: x, y: y(bar.rows.lowerBound, left: false), width: 3, height: CGFloat(bar.rows.count) * DiffTheme.lineHeight).fill()
            }
            numbers(leftNumbers, left: true, x: 0)
            numbers(rightNumbers, left: false, x: Self.numbersWidth)
        }
        drawMarks()
        drawNotes()
        // The sticky rows' band runs across the bridge too, so no ribbon or ring shows through it.
        if mode == .split, let solid = pinnedBand {
            let bg = DiffTheme.background.withAlphaComponent(1)
            // The bridge, and the jump-icon column after the new side's numbers.
            for (x0, w) in [(Self.numbersWidth, Self.ribbonWidth), (bounds.width - Self.marksWidth, Self.marksWidth)] {
                bg.setFill()
                NSRect(x: x0, y: solid.lowerBound, width: w, height: solid.upperBound - solid.lowerBound).fill()
                NSGradient(starting: bg, ending: bg.withAlphaComponent(0))?.draw(in: NSRect(x: x0, y: solid.upperBound, width: w, height: StickyLinesView.tail), angle: 90)
            }
        }
        _ = diffLayout
    }

    /// The solid stretch of the sticky rows' band (from the glass down to the last pinned row),
    /// the taller of the two sides; nil when nothing is pinned.
    private var pinnedBand: Range<CGFloat>? {
        let rows = max(leftPinned.count, rightPinned.count)
        guard rows > 0 else { return nil }
        let top = covered.top, lead = top > 0 ? StickyLinesView.glassGap : 0
        return (top - lead)..<(top + CGFloat(rows) * DiffTheme.lineHeight)
    }

    // Drag to resize the panes; double-click to reset.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let (row, note) = freeNoteMarks.first(where: { freeNoteRect($0.key).insetBy(dx: -3, dy: -3).contains(p) }) {
            onNoteClick?(note.id, freeNoteRect(row))
            return
        }
        if let row = addRow, noteRect(row).insetBy(dx: -4, dy: -3).contains(p), let line = rightNumbers[row] {
            onAddNote?(line, noteRect(row))
            return
        }
        if let (row, _) = rightMarks.first(where: { markRect($0.key).insetBy(dx: -3, dy: -3).contains(p) }) {
            onMarkClick?(row, markRect(row))
            return
        }
        if event.clickCount == 2 { onResetSplit?(); return }
        dragStart = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        onDrag?(event.locationInWindow.x - start)
        dragStart = event.locationInWindow.x
    }

    override func mouseUp(with event: NSEvent) { dragStart = nil }

    /// The bands the glass header and actions cover: no resize cursor under them.
    var covered: (top: CGFloat, bottom: CGFloat) = (0, 0) { didSet { window?.invalidateCursorRects(for: self); needsDisplay = true } }

    override func resetCursorRects() {
        for row in Set(rightMarks.keys).union(noteMarks.keys) {
            let r = markRect(row)
            if r.maxY > covered.top, r.minY < bounds.height - covered.bottom { addCursorRect(r.insetBy(dx: -3, dy: -3), cursor: .pointingHand) }
        }
        // Dragging resizes the panes from the bridge only: the numbers and the icon column keep
        // their own cursors (the arrow, the hand on icons and rings).
        guard mode == .split else { return }
        // …and around each ring, which is a button.
        let rings = boxes.values.filter { !$0.isHidden }.map { $0.frame.insetBy(dx: -2, dy: -2) }.sorted { $0.minY < $1.minY }
        var y = covered.top
        let end = bounds.height - covered.bottom
        for r in rings where r.maxY > y && r.minY < end {
            if r.minY > y { addCursorRect(NSRect(x: Self.numbersWidth, y: y, width: Self.ribbonWidth, height: r.minY - y), cursor: .resizeLeftRight) }
            y = max(y, r.maxY)
        }
        if end > y { addCursorRect(NSRect(x: Self.numbersWidth, y: y, width: Self.ribbonWidth, height: end - y), cursor: .resizeLeftRight) }
    }
}

/// A section's review toggle: a ring (not reviewed), a ring with a dash (partly), a filled green
/// dot with a check (reviewed). Drawn in the theme's colors; acts as a checkbox for Accessibility.
final class StageToggle: NSView {
    let id: Int
    let onToggle: (Int) -> Void
    var state: StageState = .unstaged {
        didSet {
            guard oldValue != state else { return }
            animateProgress()
            if style == .dot { animateMarks() }
            setAccessibilityValue(state == .staged ? 1 : state == .partial ? 2 : 0)
            native?.state = switch state { case .staged: .on; case .unstaged: .off; case .partial: .mixed }
        }
    }
    private var hovering = false { didSet { needsDisplay = true; if style == .dot, oldValue != hovering { animateMarks() } } }
    /// How much is reviewed (files and folders); sections use their state.
    var fraction: Double? { didSet { if oldValue != fraction { animateProgress() } } }
    private var shown: Double = -1
    private var progressTimer: Timer?
    /// The system checkbox, in the "native" design.
    private var native: NSButton?

    /// How this toggle draws: the gutter follows the design; file rows use the system checkbox
    /// for the "bar" and "row" designs.
    let style: Design.Marker

    init(id: Int, inList: Bool = false, onToggle: @escaping (Int) -> Void) {
        self.id = id
        let m = Design.marker
        style = inList ? .progress : m
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        toolTip = "Mark this change reviewed"
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("Mark this change reviewed")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        if style == .native || style == .mono {
            let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(nativeClicked))
            b.allowsMixedState = true
            b.controlSize = .small
            b.frame = bounds
            b.autoresizingMask = [.width, .height]
            if style == .mono { b.contentTintColor = .secondaryLabelColor; b.bezelColor = .secondaryLabelColor }
            addSubview(b)
            native = b
        }
    }
    @objc private func nativeClicked() { onToggle(id) }
    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityPerformPress() -> Bool { onToggle(id); return true }
    /// The note this change's mark speaks for (nil: none, or the change is accepted).
    var note: RibbonGutterView.NoteMark? { didSet { if oldValue != note { needsDisplay = true } } }
    /// Not seen before: amber until you have been shown it once.
    var fresh = false { didSet { if oldValue != fresh { needsDisplay = true; if style == .dot { animateMarks() } } } }
    var onNote: ((String) -> Void)?
    /// Where the mark sits in its cell (the cell is wider when it can open into the two-part pill).
    private var markX: CGFloat { bounds.height / 2 }
    override func mouseDown(with event: NSEvent) {
        guard style == .dot, let note, state != .staged, !note.waiting else { onToggle(id); return }
        // Your note opens first: a change is accepted only once its note is sent or removed.
        // Claude's: the check half accepts, the sparkle half opens the note.
        if note.fromClaude, convert(event.locationInWindow, from: nil).x < markX + 10 { onToggle(id) } else { onNote?(note.id) }
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .progress: drawProgress(); return
        case .native, .row, .mono: return
        case .dot, .inline: drawDot(); return
        case .bar: drawBar(); return
        case .check: drawQuietCheck(); return
        case .circle: drawCircle(); return
        case .ring: break
        }
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        switch state {
        case .staged:
            DiffTheme.added.setFill()
            circle.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: 4.8, y: 8.2)); check.line(to: NSPoint(x: 7.0, y: 5.8)); check.line(to: NSPoint(x: 11.4, y: 10.6))
            check.lineWidth = 1.8; check.lineCapStyle = .round; check.lineJoinStyle = .round
            NSColor.white.setStroke(); check.stroke()
        case .partial, .unstaged:
            DiffTheme.background.withAlphaComponent(0.85).setFill()
            circle.fill()
            circle.lineWidth = 1.5
            (hovering ? DiffTheme.text : DiffTheme.foldLabel).setStroke()
            circle.stroke()
            if state == .partial {
                let dash = NSBezierPath()
                dash.move(to: NSPoint(x: 5, y: 8)); dash.line(to: NSPoint(x: 11, y: 8))
                dash.lineWidth = 1.8; dash.lineCapStyle = .round
                DiffTheme.added.setStroke(); dash.stroke()
            }
        }
    }

    /// The change's color as the marker (the "bar" design).
    var tint: NSColor = .systemBlue

    /// A bar the height of the change: its color while to review, green with a check once reviewed.
    private func drawBar() {
        let w: CGFloat = 7
        let r = NSRect(x: bounds.midX - w / 2, y: bounds.minY + 1, width: w, height: max(6, bounds.height - 2))
        let bar = NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2)
        switch state {
        case .staged:
            DiffTheme.added.setFill(); bar.fill()
            if r.height >= 14 {
                // A check at the bar's top (this view isn't flipped: y grows upward).
                let c = NSPoint(x: r.midX, y: r.maxY - 7)
                let check = NSBezierPath()
                check.move(to: NSPoint(x: c.x - 2.2, y: c.y)); check.line(to: NSPoint(x: c.x - 0.6, y: c.y - 1.8)); check.line(to: NSPoint(x: c.x + 2.4, y: c.y + 2))
                check.lineWidth = 1.4; check.lineCapStyle = .round; check.lineJoinStyle = .round
                NSColor.black.withAlphaComponent(0.75).setStroke(); check.stroke()
            }
        case .partial:
            tint.withAlphaComponent(hovering ? 1 : 0.85).setFill(); bar.fill()
            NSGraphicsContext.saveGraphicsState(); NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2).clip()
            DiffTheme.added.setFill(); bar.fill(); NSGraphicsContext.restoreGraphicsState()
        case .unstaged:
            tint.withAlphaComponent(hovering ? 1 : 0.8).setFill(); bar.fill()
        }
    }

    private var target: Double {
        if let fraction { return state == .staged ? 1 : min(fraction, state == .unstaged ? 0 : 0.99) }
        return state == .staged ? 1 : state == .partial ? 0.5 : 0
    }

    /// Eases the ring to its new amount (a quarter second), unless motion is reduced.
    private func animateProgress() {
        needsDisplay = true
        guard shown >= 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, window != nil else { shown = target; return }
        progressTimer?.invalidate()
        let from = shown, to = target, start = Date()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = min(1, Date().timeIntervalSince(start) / 0.25)
                let e = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
                self.shown = from + (to - from) * e
                self.needsDisplay = true
                if p >= 1 { self.progressTimer?.invalidate() }
            }
        }
    }

    /// The review ring: a quiet track that fills as you review, and becomes a solid check when done.
    private func drawProgress() {
        if shown < 0 { shown = target }
        if progressTimer?.isValid != true { shown = target }
        // Fits inside one line's height of the bridge, whatever the text size.
        // Well inside the bridge: the bridge is one line tall where the ring sits, the ring a little over half of it.
        let d: CGFloat = min(10, max(8, DiffTheme.lineHeight - 8)), k = d / 13
        let r = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        let c = NSPoint(x: r.midX, y: r.midY)
        if shown >= 0.999 {
            DiffTheme.accent.setFill()
            NSBezierPath(ovalIn: r).fill()
            // A checkmark (this view isn't flipped: y grows upward).
            let check = NSBezierPath()
            check.move(to: NSPoint(x: c.x - 3.1 * k, y: c.y - 0.1 * k))
            check.line(to: NSPoint(x: c.x - 0.9 * k, y: c.y - 2.3 * k))
            check.line(to: NSPoint(x: c.x + 3.2 * k, y: c.y + 2.4 * k))
            check.lineWidth = 1.4; check.lineCapStyle = .round; check.lineJoinStyle = .round
            NSColor.white.setStroke(); check.stroke()
            return
        }
        let track = NSBezierPath(ovalIn: r.insetBy(dx: 0.8, dy: 0.8))
        track.lineWidth = 1.4
        (hovering ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setStroke()
        track.stroke()
        if shown > 0.001 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: d / 2 - 0.8, startAngle: 90, endAngle: 90 - 360 * shown, clockwise: true)
            arc.lineWidth = 1.9; arc.lineCapStyle = .round
            DiffTheme.accent.setStroke()
            arc.stroke()
        }
    }

    /// Nothing until it matters: a faint outline under the pointer, a dash when partly reviewed,
    /// a checkmark in the accent color once reviewed.
    private func drawQuietCheck() {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 3, yRadius: 3)
        switch state {
        case .staged:
            if let img = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Reviewed")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .bold).applying(.init(paletteColors: [DiffTheme.accent]))) {
                let s = img.size
                img.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height))
            }
        case .partial:
            let dash = NSBezierPath(); dash.move(to: NSPoint(x: 5, y: bounds.midY)); dash.line(to: NSPoint(x: bounds.width - 5, y: bounds.midY))
            dash.lineWidth = 1.6; dash.lineCapStyle = .round; NSColor.secondaryLabelColor.setStroke(); dash.stroke()
        case .unstaged:
            if hovering { NSColor.tertiaryLabelColor.setStroke(); box.lineWidth = 1; box.stroke() }
            else { NSColor.quaternaryLabelColor.setStroke(); box.lineWidth = 1; box.stroke() }
        }
    }

    /// A thin grey ring; once reviewed it fills with the accent color and a white check.
    private func drawCircle() {
        let r = NSRect(x: bounds.midX - 6.5, y: bounds.midY - 6.5, width: 13, height: 13)
        let circle = NSBezierPath(ovalIn: r)
        switch state {
        case .staged:
            DiffTheme.accent.setFill(); circle.fill()
            let c = NSPoint(x: r.midX, y: r.midY)
            let check = NSBezierPath()
            check.move(to: NSPoint(x: c.x - 3, y: c.y - 0.2)); check.line(to: NSPoint(x: c.x - 0.8, y: c.y - 2.4)); check.line(to: NSPoint(x: c.x + 3.2, y: c.y + 2.3))
            check.lineWidth = 1.5; check.lineCapStyle = .round; check.lineJoinStyle = .round
            NSColor.white.setStroke(); check.stroke()
        case .partial:
            NSColor.tertiaryLabelColor.setStroke(); circle.lineWidth = 1.2; circle.stroke()
            NSGraphicsContext.saveGraphicsState(); NSRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height).clip()
            DiffTheme.accent.withAlphaComponent(0.8).setFill(); circle.fill(); NSGraphicsContext.restoreGraphicsState()
        case .unstaged:
            (hovering ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setStroke(); circle.lineWidth = 1.2; circle.stroke()
        }
    }

    /// Mail's unread dot: a dot means "still to review"; half a dot, partly; none, reviewed (a
    /// faint ring shows under the pointer, to mark it again).
    /// The mark's three animated amounts, each following its target smoothly and from wherever it is
    /// (so a quick in-and-out of the pointer, or a click mid-way, never jumps):
    /// grown, the dot opened into its button (the pointer); on, accepted; freshAmount, amber (new to you).
    private var grown: CGFloat = 0
    private var on: CGFloat = -1
    private var freshAmount: CGFloat = -1
    private var markTimer: Timer?
    private var markClock = Date()
    private func animateMarks() {
        if on < 0 { on = state == .staged ? 1 : 0; freshAmount = fresh ? 1 : 0 }
        needsDisplay = true
        guard markTimer == nil else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, window != nil else { settleMarks(); return }
        markClock = Date()
        markTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepMarks() }
        }
    }
    private func settleMarks() {
        grown = hovering ? 1 : 0; on = state == .staged ? 1 : 0; freshAmount = fresh ? 1 : 0
        needsDisplay = true
    }
    private func stepMarks() {
        let now = Date(), dt = CGFloat(now.timeIntervalSince(markClock)); markClock = now
        // Critically damped approach: quick at first, settling without overshoot.
        func follow(_ v: inout CGFloat, _ target: CGFloat, _ tau: CGFloat) -> Bool {
            v += (target - v) * (1 - exp(-dt / tau))
            if abs(target - v) < 0.002 { v = target; return true }
            return false
        }
        let a = follow(&grown, hovering ? 1 : 0, hovering ? 0.045 : 0.035)
        let b = follow(&on, state == .staged ? 1 : 0, 0.06)
        let c = follow(&freshAmount, fresh ? 1 : 0, 0.12)
        needsDisplay = true
        if a && b && c { markTimer?.invalidate(); markTimer = nil }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            // Taken out (a reload, the file closed): no timer outlives the view.
            markTimer?.invalidate(); markTimer = nil
            progressTimer?.invalidate(); progressTimer = nil
            return
        }
        if style == .dot { on = -1; animateMarks(); settleMarks() }
    }

    /// Tests: the mark's motion, frame by frame, as an animated GIF and a strip (VET_SNAPSHOT_DIR/markfilm.*).
    /// Each sequence: the pointer arrives, a click, the pointer leaves.
    static func film(to dir: String) {
        let scale: CGFloat = 4, size = NSSize(width: 26, height: 22)
        var frames: [CGImage] = []
        func frame(_ t: StageToggle, band: NSColor) {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            band.setFill(); NSRect(origin: .zero, size: size).fill()
            t.draw(t.bounds)
            NSGraphicsContext.restoreGraphicsState()
            if let cg = rep.cgImage { frames.append(cg) }
        }
        let bandNew = NSColor(srgbRed: 0.24, green: 0.29, blue: 0.37, alpha: 1), bandDone = NSColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1)
        for start in ["fresh", "seen", "accepted"] {
            let t = StageToggle(id: 0) { _ in }
            t.frame = NSRect(origin: .zero, size: size)
            t.fresh = start == "fresh"; t.state = start == "accepted" ? .staged : .unstaged
            t.on = start == "accepted" ? 1 : 0; t.freshAmount = t.fresh ? 1 : 0; t.grown = 0
            func run(_ steps: Int, _ body: (CGFloat) -> Void) {
                for i in 0...steps { let p = CGFloat(i) / CGFloat(steps); body(1 - pow(1 - p, 3)); frame(t, band: (t.on > 0.5 ? bandDone : bandNew)) }
            }
            run(6) { _ in }                                  // at rest
            run(9) { t.grown = $0 }                          // the pointer arrives
            run(4) { _ in }
            let from = t.on
            t.state = from > 0.5 ? .unstaged : .staged
            t.grown = 1; t.on = from // (off screen the state change settles at once; the film shows the motion)
            if start == "fresh" { t.freshAmount = 0 }
            run(10) { t.on = from + ((from > 0.5 ? 0 : 1) - from) * $0 } // the click
            run(6) { _ in }
            run(9) { t.grown = 1 - $0 }                      // the pointer leaves
            run(10) { _ in }
        }
        let url = URL(fileURLWithPath: dir + "/markfilm.gif") as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, "com.compuserve.gif" as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for f in frames { CGImageDestinationAddImage(dest, f, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 30]] as CFDictionary) }
        CGImageDestinationFinalize(dest)
    }

    /// A small dot beside a change that still needs you, like an unread mark; a faint hollow dot
    /// once accepted. Under the pointer it opens into a small button in the app's own style (the
    /// flat fill and green check of Approve and Next): a click accepts the change, or takes it back.
    private func drawDot() {
        let grown = HoverDebug.shared.forced ? 1 : self.grown // tests: every button shown open
        let accent = DiffTheme.accent, amber = RibbonGutterView.noteAmber
        let c = NSPoint(x: markX, y: bounds.midY)
        let small: CGFloat = 7, big: CGFloat = 12
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * grown }
        func check(at p: NSPoint, _ color: NSColor) {
            let k = NSBezierPath()
            k.move(to: NSPoint(x: p.x - 2.5, y: p.y - 0.1)); k.line(to: NSPoint(x: p.x - 0.8, y: p.y - 1.9)); k.line(to: NSPoint(x: p.x + 2.6, y: p.y + 2))
            k.lineWidth = 1.3; k.lineCapStyle = .round; k.lineJoinStyle = .round
            color.setStroke(); k.stroke()
        }
        func sparkle(at p: NSPoint, _ color: NSColor, size: CGFloat = 10.5) {
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium).applying(.init(paletteColors: [color]))
            guard let image = NSImage(systemSymbolName: RibbonGutterView.claudeSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
            image.draw(in: NSRect(x: p.x - image.size.width / 2, y: p.y - image.size.height / 2, width: image.size.width, height: image.size.height))
        }
        let fade = max(0, (grown - 0.4) / 0.6)

        let grey = NSColor.white
        let on = max(0, self.on), freshAmount = max(0, self.freshAmount)
        if note == nil || state == .staged {
            // One dot that morphs between its states:
            //   new, at rest: a dot in its color (amber the first time, then blue);
            //   new, under the pointer: an empty button in its color, a box waiting to be ticked;
            //   accepted, at rest: a dim grey dot;
            //   accepted, under the pointer: a see-through button with its check, ticked.
            // A click moves `on`, and the drawing slides from one to the other.
            let tone = accent.blended(withFraction: freshAmount, of: amber) ?? accent
            func mix(_ a: NSColor, _ b: NSColor) -> NSColor { a.blended(withFraction: on, of: b) ?? b }
            let d = lerp(small, big), r = NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            let restFill = mix(tone, grey.withAlphaComponent(0.22).usingColorSpace(.sRGB) ?? grey)
            let restAlpha = 1 + (0.22 - 1) * on
            let hoverAlpha = 0.12 * on
            restFill.withAlphaComponent(restAlpha + (hoverAlpha - restAlpha) * grown).setFill()
            NSBezierPath(ovalIn: r).fill()
            if grown > 0 {
                mix(tone, grey).withAlphaComponent(grown * (1 + (0.4 - 1) * on)).setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.65, dy: 0.65)); ring.lineWidth = 1.3; ring.stroke()
            }
            if fade > 0, on > 0 { check(at: c, grey.withAlphaComponent(fade * on)) }
            return
        }
        guard let note else { return }
        if !note.fromClaude, note.waiting {
            // Sent: Claude is on it. A dim spinner; nothing changes under the pointer.
            let track = NSBezierPath(ovalIn: NSRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9))
            track.lineWidth = 1.6
            grey.withAlphaComponent(0.14).setStroke(); track.stroke()
            let turn = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : CGFloat(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9) * 360
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: 4.5, startAngle: 90 - turn, endAngle: 90 - turn - 100, clockwise: true)
            arc.lineWidth = 1.6; arc.lineCapStyle = .round
            grey.withAlphaComponent(0.6).setStroke(); arc.stroke()
            return
        }
        if !note.fromClaude {
            // Your note, not sent yet: an amber ring; under the pointer a button that opens it.
            let d = lerp(small, big), r = NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            if grown > 0 { amber.withAlphaComponent(0.18 * grown).setFill(); NSBezierPath(ovalIn: r).fill() }
            amber.setStroke()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.7, dy: 0.7)); ring.lineWidth = 1.4; ring.stroke()
            if fade > 0 {
                amber.withAlphaComponent(fade).setFill()
                for (i, w) in [CGFloat(5), 5, 3].enumerated() { NSRect(x: c.x - 2.5, y: c.y + 1.6 - CGFloat(i) * 2.1, width: w, height: 1).fill() }
            }
            return
        }
        // Claude's answer or note: a sparkle, amber until you open it, then blue. Under the pointer a
        // two-part pill (accept | open the note).
        let tone = RibbonGutterView.seenNotes.contains(note.id) ? accent : amber
        if grown < 0.05 { sparkle(at: c, tone); return }
        // Under the pointer: one pill, two even halves. The check accepts, the note's icon opens it.
        let h = lerp(small + 3, 14), w = lerp(small + 3, 34), left = c.x - lerp((small + 3) / 2, 7)
        let r = NSRect(x: left, y: c.y - h / 2, width: w, height: h)
        tone.withAlphaComponent(0.2 * grown).setFill()
        NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
        if fade > 0 {
            tone.withAlphaComponent(0.4 * fade).setFill()
            NSRect(x: left + 16.5, y: c.y - 3.5, width: 1, height: 7).fill()
            check(at: NSPoint(x: left + 8.5, y: c.y), (tone.blended(withFraction: 0.35, of: .white) ?? tone).withAlphaComponent(fade))
        }
        sparkle(at: NSPoint(x: lerp(c.x, left + 25.5), y: c.y), tone, size: lerp(10.5, 8.5))
    }
}

