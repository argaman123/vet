import AppKit
import VetCore

/// The middle of the diff: left line numbers, the ribbons joining each section's two sides,
/// a staging checkbox per section, and right line numbers. Dragging it resizes the panes.
final class RibbonGutterView: NSView {
    /// `unified`: one pane; both number columns (HEAD, working file) then the checkboxes.
    enum Mode { case split, rightOnly, leftOnly, unified }
    static let numbersWidth: CGFloat = 40
    static var ribbonWidth: CGFloat { Design.bridge == .map ? 10 : 36 }
    /// Side by side, as WebStorm lays it out: old numbers, the bridge, new numbers, then the
    /// staging checkbox; each change's color runs unbroken through all of them.
    static var checkWidth: CGFloat { Design.marker == .inline || Design.marker == .row ? 4 : 24 }

    var mode: Mode = .split { didSet { needsDisplay = true } }
    var diffLayout: DiffLayout?
    var hunks: [Hunk] = []
    var states: [Int: StageState] = [:]
    /// The change ⌘↩ / Space would approve (outlined in the accent color).
    var currentID: Int? { didSet { if oldValue != currentID { needsDisplay = true } } }
    var leftNumbers: [Int?] = []  // display line → file line (nil for folds)
    var rightNumbers: [Int?] = []
    /// Display lines pinned at the top of each pane (sticky lines); their numbers cover the
    /// numbers of the lines scrolled under them.
    var leftPinned: [Int] = [] { didSet { if oldValue != leftPinned { needsDisplay = true } } }
    var rightPinned: [Int] = [] { didSet { if oldValue != rightPinned { needsDisplay = true } } }
    /// Unified mode: each section's rows in the one pane, and its colored change bars.
    var unifiedRanges: [Int: Range<Int>] = [:]
    var unifiedBars: [(rows: Range<Int>, color: NSColor)] = []
    var leftOffset: CGFloat = 0 { didSet { needsDisplay = true; placeCheckboxes() } }
    var rightOffset: CGFloat = 0 { didSet { needsDisplay = true; placeCheckboxes() } }
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

    static func width(for mode: Mode) -> CGFloat {
        switch mode {
        case .split: numbersWidth * 2 + ribbonWidth + checkWidth
        case .unified: numbersWidth * 2 + ribbonWidth
        case .rightOnly, .leftOnly: numbersWidth + ribbonWidth
        }
    }

    func reload() {
        for b in boxes.values { b.removeFromSuperview() }
        boxes = [:]
        segments = [:]
        for seg in diffLayout?.segments ?? [] { if case .hunk(let id) = seg.kind { segments[id] = seg } }
        for h in hunks {
            let b = StageToggle(id: h.id) { [weak self] id in self?.toggled(id) }
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
            if mode == .split {
                // At the change's first new line; for removed lines, beside where the ribbon starts.
                // Removed lines: centered on the line where they were removed (kept inside the view
                // at the very top of the file).
                let top = s.right.isEmpty ? max(y(0, left: false) - DiffTheme.inset.height + 1, y(s.right.lowerBound, left: false) - DiffTheme.lineHeight / 2)
                    : y(s.right.lowerBound, left: false)
                let x = Self.numbersWidth * 2 + Self.ribbonWidth + (Self.checkWidth - 16) / 2
                if Design.marker == .bar {
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
                path.move(to: NSPoint(x: 0, y: l0))
                path.line(to: NSPoint(x: x0, y: l0))
                path.curve(to: NSPoint(x: x1, y: r0), controlPoint1: NSPoint(x: c1, y: l0), controlPoint2: NSPoint(x: c2, y: r0))
                path.line(to: NSPoint(x: bounds.width, y: r0))
                path.line(to: NSPoint(x: bounds.width, y: r1))
                path.line(to: NSPoint(x: x1, y: r1))
                path.curve(to: NSPoint(x: x0, y: l1), controlPoint1: NSPoint(x: c2, y: r1), controlPoint2: NSPoint(x: c1, y: l1))
                path.line(to: NSPoint(x: 0, y: l1))
                path.close()
                let change = DiffTheme.change(head: h.head, work: h.work)
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
                DiffTheme.fill(change, hasWords: !(h.headCols.isEmpty && h.workCols.isEmpty), staged: staged).setFill()
                path.fill()
                if h.id == currentID {
                    DiffTheme.accent.setStroke()
                    path.lineWidth = 1.5
                    path.stroke()
                }

            }
        }
        // Folded rows: the wave continues through the number columns (each side at its own scroll).
        for s in diffLayout.segments {
            guard case .fold = s.kind else { continue }
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
        // Numbers on a changed row sit on its color: brighter, so they stay readable.
        var changedLeft = IndexSet(), changedRight = IndexSet()
        if mode == .unified {
            for r in unifiedRanges.values { changedLeft.insert(integersIn: r); changedRight.insert(integersIn: r) }
        } else {
            for s in segments.values { changedLeft.insert(integersIn: s.left); changedRight.insert(integersIn: s.right) }
        }
        let bright: [NSAttributedString.Key: Any] = [.font: DiffTheme.numberFont, .foregroundColor: DiffTheme.lineNumberCurrent]
        func number(_ n: Int, x: CGFloat, y: CGFloat, changed: Bool = false) {
            let s = NSAttributedString(string: "\(n + 1)", attributes: changed ? bright : attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: x + Self.numbersWidth - 6 - size.width, y: y + (DiffTheme.lineHeight - size.height) / 2))
        }
        func numbers(_ list: [Int?], left: Bool, x: CGFloat) {
            let pinned = left ? leftPinned : rightPinned
            let band = pinned.isEmpty ? 0 : CGFloat(pinned.count) * DiffTheme.lineHeight + 2
            let first = max(0, Int(((left ? leftOffset : rightOffset) - DiffTheme.inset.height) / DiffTheme.lineHeight))
            let count = Int(bounds.height / DiffTheme.lineHeight) + 2
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: x, y: band, width: Self.numbersWidth, height: bounds.height - band).clip()
            let changed = left ? changedLeft : changedRight
            for i in first..<min(list.count, first + count) {
                if let n = list[i] { number(n, x: x, y: y(i, left: left), changed: changed.contains(i)) }
            }
            NSGraphicsContext.restoreGraphicsState()
            guard band > 0 else { return }
            DiffTheme.background.setFill()
            NSRect(x: x, y: 0, width: Self.numbersWidth, height: band).fill()
            for (row, line) in pinned.enumerated() where line < list.count {
                if let n = list[line] { number(n, x: x, y: CGFloat(row) * DiffTheme.lineHeight) }
            }
            NSColor.separatorColor.setFill()
            NSRect(x: x, y: band - 1, width: Self.numbersWidth, height: 1).fill()
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
        _ = diffLayout
    }

    // Drag to resize the panes; double-click to reset.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onResetSplit?(); return }
        dragStart = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        onDrag?(event.locationInWindow.x - start)
        dragStart = event.locationInWindow.x
    }

    override func mouseUp(with event: NSEvent) { dragStart = nil }

    override func resetCursorRects() {
        if mode == .split { addCursorRect(bounds, cursor: .resizeLeftRight) }
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
            needsDisplay = true
            setAccessibilityValue(state == .staged ? 1 : state == .partial ? 2 : 0)
            native?.state = switch state { case .staged: .on; case .unstaged: .off; case .partial: .mixed }
        }
    }
    private var hovering = false { didSet { needsDisplay = true } }
    /// The system checkbox, in the "native" design.
    private var native: NSButton?

    /// How this toggle draws: the gutter follows the design; file rows use the system checkbox
    /// for the "bar" and "row" designs.
    let style: Design.Marker

    init(id: Int, inList: Bool = false, onToggle: @escaping (Int) -> Void) {
        self.id = id
        let m = Design.marker
        style = inList && (m == .bar || m == .row) ? .native : m
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        toolTip = "Stage this section (mark it reviewed)"
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("Stage this section (mark it reviewed)")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        if style == .native {
            let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(nativeClicked))
            b.allowsMixedState = true
            b.controlSize = .small
            b.frame = bounds
            b.autoresizingMask = [.width, .height]
            addSubview(b)
            native = b
        }
    }
    @objc private func nativeClicked() { onToggle(id) }
    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityPerformPress() -> Bool { onToggle(id); return true }
    override func mouseDown(with event: NSEvent) { onToggle(id) }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .native, .row: return
        case .dot, .inline: drawDot(); return
        case .bar: drawBar(); return
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
        let r = NSRect(x: bounds.midX - 3.5, y: bounds.minY + 1, width: 7, height: max(6, bounds.height - 2))
        let bar = NSBezierPath(roundedRect: r, xRadius: 3.5, yRadius: 3.5)
        switch state {
        case .staged:
            DiffTheme.added.setFill(); bar.fill()
            if r.height >= 14 {
                let c = NSPoint(x: r.midX, y: r.minY + 7)
                let check = NSBezierPath()
                check.move(to: NSPoint(x: c.x - 2.2, y: c.y)); check.line(to: NSPoint(x: c.x - 0.6, y: c.y + 1.8)); check.line(to: NSPoint(x: c.x + 2.4, y: c.y - 2))
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

    /// Mail's unread dot: a dot means "still to review"; half a dot, partly; none, reviewed (a
    /// faint ring shows under the pointer, to mark it again).
    private func drawDot() {
        let dot = NSBezierPath(ovalIn: NSRect(x: bounds.midX - 4.5, y: bounds.midY - 4.5, width: 9, height: 9))
        switch state {
        case .unstaged:
            DiffTheme.accent.setFill(); dot.fill()
        case .partial:
            DiffTheme.accent.setStroke(); dot.lineWidth = 1.5; dot.stroke()
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: bounds.midX - 5, y: bounds.minY, width: 5, height: bounds.height).clip()
            DiffTheme.accent.setFill(); dot.fill()
            NSGraphicsContext.restoreGraphicsState()
        case .staged:
            if hovering { DiffTheme.foldLabel.setStroke(); dot.lineWidth = 1.2; dot.stroke() }
        }
    }
}

