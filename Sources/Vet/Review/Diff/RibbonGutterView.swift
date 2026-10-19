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
    static let ringZone: CGFloat = 16

    /// Where a change's bridge runs flat for its ring: the side with more lines.
    func ringOnRight(_ s: DiffLayout.Segment) -> Bool { s.right.count >= s.left.count }

    /// The band (one line tall) the ring sits in: the taller side's first line.
    func ringBand(_ s: DiffLayout.Segment) -> (CGFloat, CGFloat) {
        let top = ringOnRight(s) ? y(s.right.lowerBound, left: false) : y(s.left.lowerBound, left: true)
        return (top, top + DiffTheme.lineHeight)
    }
    /// Side by side, as WebStorm lays it out: old numbers, the bridge, new numbers, then the
    /// staging checkbox; each change's color runs unbroken through all of them.
    static var checkWidth: CGFloat { [.inline, .row, .native, .mono, .check, .circle, .progress].contains(Design.marker) ? 0 : 24 }

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
            if mode == .split, [.native, .mono, .check, .circle, .progress].contains(b.style) {
                // In the bridge's flat stretch on the taller side, centered on that side's first line.
                let (top, _) = ringBand(s)
                let cy = top + DiffTheme.lineHeight / 2
                let cx = Self.numbersWidth + Self.ribbonWidth / 2
                b.frame = NSRect(x: cx - 8, y: cy - 8, width: 16, height: 16)
                b.isHidden = cy < -20 || cy > bounds.height + 20
                continue
            }
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
                if Self.ringInBridge && mode == .split {
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
        // Numbers on a changed row sit on its color: brighter, so they stay readable.
        var changedLeft = IndexSet(), changedRight = IndexSet()
        if mode == .unified {
            for r in unifiedRanges.values { changedLeft.insert(integersIn: r); changedRight.insert(integersIn: r) }
        } else {
            for s in segments.values { changedLeft.insert(integersIn: s.left); changedRight.insert(integersIn: s.right) }
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
            let s = NSAttributedString(string: "\(n + 1)", attributes: current ? lit : changed ? bright : attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: x + Self.numbersWidth - 4 - size.width, y: y + (DiffTheme.lineHeight - size.height) / 2))
        }
        func numbers(_ list: [Int?], left: Bool, x: CGFloat) {
            let pinned = left ? leftPinned : rightPinned
            let band = pinned.isEmpty ? 0 : CGFloat(pinned.count) * DiffTheme.lineHeight + 2
            let first = max(0, Int(((left ? leftOffset : rightOffset) - DiffTheme.inset.height) / DiffTheme.lineHeight))
            let count = Int(bounds.height / DiffTheme.lineHeight) + 2
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: x, y: band, width: Self.numbersWidth, height: bounds.height - band).clip()
            let changed = left ? changedLeft : changedRight, current = left ? currentLeft : currentRight
            for i in first..<min(list.count, first + count) {
                if let n = list[i] { number(n, x: x, y: y(i, left: left), changed: changed.contains(i), current: current.contains(i)) }
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
            animateProgress()
            setAccessibilityValue(state == .staged ? 1 : state == .partial ? 2 : 0)
            native?.state = switch state { case .staged: .on; case .unstaged: .off; case .partial: .mixed }
        }
    }
    private var hovering = false { didSet { needsDisplay = true } }
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
        style = inList && (m == .bar || m == .row) ? .native : m
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
    override func mouseDown(with event: NSEvent) { onToggle(id) }
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
        let d = min(13, max(9, DiffTheme.lineHeight - 4))
        let r = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        let c = NSPoint(x: r.midX, y: r.midY)
        if shown >= 0.999 {
            DiffTheme.accent.setFill()
            NSBezierPath(ovalIn: r).fill()
            // A checkmark (this view isn't flipped: y grows upward).
            let check = NSBezierPath()
            check.move(to: NSPoint(x: c.x - 3.1, y: c.y - 0.1))
            check.line(to: NSPoint(x: c.x - 0.9, y: c.y - 2.3))
            check.line(to: NSPoint(x: c.x + 3.2, y: c.y + 2.4))
            check.lineWidth = 1.6; check.lineCapStyle = .round; check.lineJoinStyle = .round
            NSColor.white.setStroke(); check.stroke()
            return
        }
        let track = NSBezierPath(ovalIn: r.insetBy(dx: 0.8, dy: 0.8))
        track.lineWidth = 1.6
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

