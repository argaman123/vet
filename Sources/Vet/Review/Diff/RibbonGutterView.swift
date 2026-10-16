import AppKit
import VetCore

/// The middle of the diff: left line numbers, the ribbons joining each section's two sides,
/// a staging checkbox per section, and right line numbers. Dragging it resizes the panes.
final class RibbonGutterView: NSView {
    enum Mode { case split, rightOnly, leftOnly }
    static let numbersWidth: CGFloat = 40
    static let ribbonWidth: CGFloat = 44

    var mode: Mode = .split { didSet { needsDisplay = true } }
    var diffLayout: DiffLayout?
    var hunks: [Hunk] = []
    var states: [Int: StageState] = [:]
    var leftNumbers: [Int?] = []  // display line → file line (nil for folds)
    var rightNumbers: [Int?] = []
    var leftOffset: CGFloat = 0 { didSet { needsDisplay = true; placeCheckboxes() } }
    var rightOffset: CGFloat = 0 { didSet { needsDisplay = true; placeCheckboxes() } }
    var onToggle: ((Int, Bool, String) -> Void)?
    /// The snapshot these checkboxes were drawn from; sent with every click.
    var snapshotID = ""
    var onDrag: ((CGFloat) -> Void)?
    var onResetSplit: (() -> Void)?
    private var boxes: [Int: NSButton] = [:]
    private var dragStart: CGFloat?

    override var isFlipped: Bool { true }

    static func width(for mode: Mode) -> CGFloat {
        mode == .split ? numbersWidth * 2 + ribbonWidth : numbersWidth + ribbonWidth
    }

    func reload() {
        for b in boxes.values { b.removeFromSuperview() }
        boxes = [:]
        for h in hunks {
            let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
            b.allowsMixedState = true
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

    @objc private func toggled(_ sender: NSButton) {
        onToggle?(sender.tag, sender.state != .off, snapshotID)
    }

    private func y(_ line: Int, left: Bool) -> CGFloat {
        DiffTheme.inset.height + CGFloat(line) * DiffTheme.lineHeight - (left ? leftOffset : rightOffset)
    }

    private func segment(for id: Int) -> DiffLayout.Segment? {
        diffLayout?.segments.first { $0.kind == .hunk(id: id) }
    }

    private var ribbonX: (CGFloat, CGFloat) {
        switch mode {
        case .split: (Self.numbersWidth, Self.numbersWidth + Self.ribbonWidth)
        case .rightOnly: (0, Self.ribbonWidth)
        case .leftOnly: (Self.numbersWidth, Self.numbersWidth + Self.ribbonWidth)
        }
    }

    private func placeCheckboxes() {
        let (x0, x1) = ribbonX
        for (id, b) in boxes {
            guard let s = segment(for: id) else { b.isHidden = true; continue }
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
                let color = DiffTheme.color(head: h.head, work: h.work)
                let staged = states[h.id] == .staged
                let l0 = y(s.left.lowerBound, left: true), l1 = y(s.left.upperBound, left: true)
                let r0 = y(s.right.lowerBound, left: false), r1 = y(s.right.upperBound, left: false)
                let path = NSBezierPath()
                let mid = (x0 + x1) / 2
                path.move(to: NSPoint(x: 0, y: l0))
                path.line(to: NSPoint(x: x0, y: l0))
                path.curve(to: NSPoint(x: x1, y: r0), controlPoint1: NSPoint(x: mid, y: l0), controlPoint2: NSPoint(x: mid, y: r0))
                path.line(to: NSPoint(x: bounds.width, y: r0))
                path.line(to: NSPoint(x: bounds.width, y: max(r1, r0 + 1.5)))
                path.line(to: NSPoint(x: x1, y: max(r1, r0 + 1.5)))
                path.curve(to: NSPoint(x: x0, y: max(l1, l0 + 1.5)), controlPoint1: NSPoint(x: mid, y: max(r1, r0 + 1.5)), controlPoint2: NSPoint(x: mid, y: max(l1, l0 + 1.5)))
                path.line(to: NSPoint(x: 0, y: max(l1, l0 + 1.5)))
                path.close()
                color.withAlphaComponent(staged ? 0.08 : 0.2).setFill()
                path.fill()
                color.withAlphaComponent(staged ? 0.3 : 0.65).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
        // Line numbers.
        let attrs: [NSAttributedString.Key: Any] = [.font: DiffTheme.numberFont, .foregroundColor: DiffTheme.lineNumber]
        func numbers(_ list: [Int?], left: Bool, x: CGFloat) {
            let first = max(0, Int(((left ? leftOffset : rightOffset) - DiffTheme.inset.height) / DiffTheme.lineHeight))
            let count = Int(bounds.height / DiffTheme.lineHeight) + 2
            for i in first..<min(list.count, first + count) {
                guard let n = list[i] else { continue }
                let s = NSAttributedString(string: "\(n + 1)", attributes: attrs)
                let size = s.size()
                s.draw(at: NSPoint(x: x + Self.numbersWidth - 6 - size.width, y: y(i, left: left) + (DiffTheme.lineHeight - size.height) / 2))
            }
        }
        switch mode {
        case .split:
            numbers(leftNumbers, left: true, x: 0)
            numbers(rightNumbers, left: false, x: Self.numbersWidth + Self.ribbonWidth)
        case .rightOnly: numbers(rightNumbers, left: false, x: Self.ribbonWidth)
        case .leftOnly: numbers(leftNumbers, left: true, x: 0)
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
