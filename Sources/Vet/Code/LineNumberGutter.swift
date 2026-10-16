import AppKit

/// Line numbers beside a single code pane; follows the pane's scrolling.
final class LineNumberGutter: NSView {
    /// Display line → file line (0-based), nil for rows without a number.
    var numbers: [Int?] = [] { didSet { needsDisplay = true } }
    var offset: CGFloat = 0 { didSet { needsDisplay = true } }
    /// File line to emphasize (0-based), e.g. after jumping to a definition.
    var highlighted: Int? { didSet { needsDisplay = true } }
    static let width: CGFloat = 52

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        DiffTheme.gutter.setFill()
        bounds.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: DiffTheme.numberFont, .foregroundColor: DiffTheme.lineNumber]
        let strong: [NSAttributedString.Key: Any] = [.font: DiffTheme.numberFont, .foregroundColor: DiffTheme.text]
        let first = max(0, Int((offset - DiffTheme.inset.height) / DiffTheme.lineHeight))
        let count = Int(bounds.height / DiffTheme.lineHeight) + 2
        for i in first..<min(numbers.count, first + count) {
            guard let n = numbers[i] else { continue }
            let s = NSAttributedString(string: "\(n + 1)", attributes: n == highlighted ? strong : attrs)
            let size = s.size()
            let y = DiffTheme.inset.height + CGFloat(i) * DiffTheme.lineHeight - offset
            s.draw(at: NSPoint(x: bounds.width - 10 - size.width, y: y + (DiffTheme.lineHeight - size.height) / 2))
        }
    }
}
