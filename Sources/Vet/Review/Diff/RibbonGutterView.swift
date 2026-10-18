import AppKit
import VetCore

/// The middle of the diff: left line numbers, the ribbons joining each section's two sides,
/// a staging checkbox per section, and right line numbers. Dragging it resizes the panes.
final class RibbonGutterView: NSView {
    /// `unified`: one pane; both number columns (HEAD, working file) then the checkboxes.
    enum Mode { case split, rightOnly, leftOnly, unified }
    static let numbersWidth: CGFloat = 40
    static let ribbonWidth: CGFloat = 36
    /// Side by side, as WebStorm lays it out: old numbers, the bridge, new numbers, then the
    /// staging checkbox; each change's color runs unbroken through all of them.
    static let checkWidth: CGFloat = 24

    var mode: Mode = .split { didSet { needsDisplay = true } }
    var diffLayout: DiffLayout?
    var hunks: [Hunk] = []
    var states: [Int: StageState] = [:]
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
    private var boxes: [Int: NSButton] = [:]
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
            let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
            b.allowsMixedState = true
            b.controlSize = .small
            b.tag = h.id
            b.toolTip = "Stage this section (mark it reviewed)"
            addSubview(b)
            boxes[h.id] = b
        }
        updateStates()
        placeCheckboxes()
        needsDisplay = true
    }

    func updateStates() {
        for (id, b) in boxes {
            b.state = switch states[id] ?? .unstaged { case .staged: .on; case .unstaged: .off; case .partial: .mixed }
        }
        needsDisplay = true
    }

    /// A click flips the section between staged and not (a mixed box stages the rest), from the
    /// state on screen, and shows the result at once; the button's own off→mixed→on cycle would
    /// read a quick second click as "stage" again.
    @objc private func toggled(_ sender: NSButton) {
        let stage = states[sender.tag] != .staged
        states[sender.tag] = stage ? .staged : .unstaged
        sender.state = stage ? .on : .off
        onToggle?(sender.tag, stage, snapshotID)
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
                // At the change's first new line (or on the marker where lines were only removed).
                let top = s.right.isEmpty ? y(s.right.lowerBound, left: false) - DiffTheme.lineHeight / 2 : y(s.right.lowerBound, left: false)
                let x = Self.numbersWidth * 2 + Self.ribbonWidth + (Self.checkWidth - 16) / 2
                b.frame = NSRect(x: x, y: top + (DiffTheme.lineHeight - 16) / 2, width: 16, height: 16)
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
        if mode == .split {
            let (x0, x1) = ribbonX
            for h in hunks {
                guard let s = segment(for: h.id) else { continue }
                let l0 = y(s.left.lowerBound, left: true), l1 = max(y(s.left.upperBound, left: true), l0 + 1.5)
                let r0 = y(s.right.lowerBound, left: false), r1 = max(y(s.right.upperBound, left: false), r0 + 1.5)
                if max(l1, r1) < dirtyRect.minY || min(l0, r0) > dirtyRect.maxY { continue } // off screen
                let staged = states[h.id] == .staged
                // WebStorm's curve: control points at 30% and 70% across the ribbon.
                let path = NSBezierPath()
                let c1 = x0 + (x1 - x0) * 0.3, c2 = x0 + (x1 - x0) * 0.7
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
                DiffTheme.fill(change, hasWords: !(h.headCols.isEmpty && h.workCols.isEmpty), staged: staged).setFill()
                path.fill()

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
            s.draw(at: NSPoint(x: x + Self.numbersWidth - 6 - size.width, y: y + (DiffTheme.lineHeight - size.height) / 2 + 1.5))
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
