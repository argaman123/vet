import AppKit

/// Line numbers beside a single code pane; follows the pane's scrolling.
final class LineNumberGutter: NSView {
    /// Display line → file line (0-based), nil for rows without a number.
    var numbers: [Int?] = [] { didSet { needsDisplay = true } }
    var offset: CGFloat = 0 { didSet { needsDisplay = true } }
    /// File line to emphasize (0-based), e.g. after jumping to a definition.
    var highlighted: Int? { didSet { needsDisplay = true } }
    /// Jump icons by display line: this overrides something (up) or is implemented/overridden (down).
    var marks: [Int: JumpMark] = [:] { didSet { if oldValue != marks { needsDisplay = true } } }
    var onMarkClick: ((Int, JumpMark, NSRect) -> Void)?
    static let width: CGFloat = 66
    /// Where line numbers end; the jump icons sit to their right, as in WebStorm.
    static let numbersRight: CGFloat = 42

    enum JumpMark: Equatable {
        case overrides, implemented
        var symbol: String { self == .overrides ? "arrow.up.circle" : "arrow.down.circle" }
        var help: String { self == .overrides ? "Go to the overridden declaration" : "Go to implementations" }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        DiffTheme.gutter.setFill()
        bounds.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: DiffTheme.numberFont, .foregroundColor: DiffTheme.lineNumber]
        let strong: [NSAttributedString.Key: Any] = [.font: DiffTheme.numberFont, .foregroundColor: DiffTheme.lineNumberCurrent]
        let first = max(0, Int((offset - DiffTheme.inset.height) / DiffTheme.lineHeight))
        let count = Int(bounds.height / DiffTheme.lineHeight) + 2
        for i in first..<min(numbers.count, first + count) {
            guard let n = numbers[i] else { continue }
            let s = NSAttributedString(string: "\(n + 1)", attributes: n == highlighted ? strong : attrs)
            let size = s.size()
            let y = DiffTheme.inset.height + CGFloat(i) * DiffTheme.lineHeight - offset
            s.draw(at: NSPoint(x: Self.numbersRight - size.width, y: y + (DiffTheme.lineHeight - size.height) / 2))
        }
        let config = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium).applying(.init(paletteColors: [DiffTheme.accent]))
        for (line, mark) in marks where line >= first && line < first + count {
            guard let image = NSImage(systemSymbolName: mark.symbol, accessibilityDescription: mark.help)?.withSymbolConfiguration(config) else { continue }
            image.draw(in: iconRect(line, image.size))
        }
    }

    private func iconRect(_ line: Int, _ size: NSSize = NSSize(width: 13, height: 13)) -> NSRect {
        let y = DiffTheme.inset.height + CGFloat(line) * DiffTheme.lineHeight - offset
        return NSRect(x: Self.numbersRight + 6, y: y + (DiffTheme.lineHeight - size.height) / 2, width: size.width, height: size.height)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let line = Int(floor((p.y + offset - DiffTheme.inset.height) / DiffTheme.lineHeight))
        guard let mark = marks[line], iconRect(line).insetBy(dx: -4, dy: -3).contains(p) else { return super.mouseDown(with: event) }
        onMarkClick?(line, mark, iconRect(line))
    }

    override func resetCursorRects() {
        for line in marks.keys { addCursorRect(iconRect(line).insetBy(dx: -4, dy: -3), cursor: .pointingHand) }
    }
}
