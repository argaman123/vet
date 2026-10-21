import AppKit
import VetCore

/// An inline hint (a parameter name or an inferred type), drawn as a small pill in a gap opened
/// in the text, as WebStorm and VS Code show them. The text itself doesn't change.
struct InlayHintMark: Equatable {
    let line: Int       // display line
    let character: Int  // UTF-16 column the hint sits before
    let label: String
    let padLeft: Bool
    let padRight: Bool
}

/// Grey text after a declaration's line: "3 usages · Dana". Clicking it shows the usages.
struct LineLensMark: Equatable {
    /// One clickable part: "2 usages" finds usages, "1 implementation" finds implementations.
    struct Part: Equatable {
        let text: String
        let kind: CodeTextView.Navigation
    }
    let line: Int       // display line
    let character: Int  // where the declared name starts (for Find Usages)
    let parts: [Part]
    var text: String { parts.map(\.text).joined(separator: " · ") }
}

/// The hint carried by the character before its gap, so the pill moves with the text you type.
final class HintBox: NSObject {
    let label: String, padLeft: Bool, padRight: Bool
    init(_ h: InlayHintMark) { label = h.label; padLeft = h.padLeft; padRight = h.padRight }

    /// The code font, smaller (IntelliJ draws hints in the editor's font).
    nonisolated(unsafe) static let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    /// Left to right even for a Hebrew string type.
    nonisolated(unsafe) static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.baseWritingDirection = .leftToRight
        return p
    }()
    var labelSize: NSSize { (label as NSString).size(withAttributes: [.font: Self.font]) }
    /// The gap opened in the text for the pill.
    var gap: CGFloat { ceil(labelSize.width) + 10 + (padLeft ? 4 : 0) + (padRight ? 4 : 0) }
}

extension NSAttributedString.Key {
    static let vetHint = NSAttributedString.Key("VetHint")
}

extension CodeTextView {
    /// Opens a gap for each hint (kerning on the character before it) and remembers its label.
    func applyHintGaps() {
        guard let storage = textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        let ns = storage.string as NSString
        storage.beginEditing()
        storage.removeAttribute(.kern, range: all)
        storage.removeAttribute(.vetHint, range: all)
        var starts: [Int] = [0], location = 0
        let lastLine = inlayHints.map(\.line).max() ?? -1
        while starts.count <= lastLine + 1 {
            let r = ns.range(of: "\n", options: .literal, range: NSRange(location: location, length: ns.length - location))
            if r.location == NSNotFound { break }
            location = NSMaxRange(r)
            starts.append(location)
        }
        for h in inlayHints where h.line < starts.count && h.character > 0 {
            let lineEnd = h.line + 1 < starts.count ? starts[h.line + 1] - 1 : ns.length
            let index = starts[h.line] + h.character
            guard index <= lineEnd, index - 1 < ns.length else { continue }
            let box = HintBox(h)
            let r = NSRange(location: index - 1, length: 1)
            storage.addAttribute(.kern, value: box.gap, range: r)
            storage.addAttribute(.vetHint, value: box, range: r)
        }
        storage.endEditing()
        relayoutVisibleText()
    }

    /// Attribute changes (gaps, colors) invalidate laid-out lines; lay the visible ones out again
    /// now, or they stay blank until the next scroll.
    func relayoutVisibleText() {
        textLayoutManager?.textViewportLayoutController.layoutViewport()
        needsDisplay = true
    }

    /// The frame of a character range in this view's coordinates (laid-out text only).
    func segmentFrame(_ range: NSRange) -> NSRect? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let start = tcm.location(tcm.documentRange.location, offsetBy: range.location),
              let end = tcm.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return nil }
        var out: NSRect?
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            out = out.map { $0.union(frame) } ?? frame
            return true
        }
        return out.map { $0.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y) }
    }

    /// Draws the hint pills and the end-of-line lenses in the visible part of the text.
    func drawDecorations(in rect: NSRect) {
        guard let storage = textStorage, storage.length > 0 else { lensRectsByLine = [:]; return }
        let ns = storage.string as NSString
        // The view can scroll above its first line (under the floating header, or bouncing at the
        // top), so a dirty rect can lie entirely before line 0: clamp both ends.
        let firstLine = max(0, line(at: NSPoint(x: 0, y: rect.minY)))
        let lastLine = max(firstLine, line(at: NSPoint(x: 0, y: rect.maxY)) + 1)
        // Character range of the dirty rows.
        var starts: [Int] = [0], location = 0
        while starts.count <= lastLine + 1 {
            let r = ns.range(of: "\n", options: .literal, range: NSRange(location: location, length: ns.length - location))
            if r.location == NSNotFound { break }
            location = NSMaxRange(r)
            starts.append(location)
        }
        let lo = firstLine < starts.count ? starts[firstLine] : ns.length
        let hi = lastLine + 1 < starts.count ? starts[lastLine + 1] : ns.length
        if hi > lo {
            storage.enumerateAttribute(.vetHint, in: NSRange(location: lo, length: hi - lo)) { value, r, _ in
                guard let box = value as? HintBox, let frame = segmentFrame(r) else { return }
                // TextKit 2 splits the kerning between this character's frame and the next one's,
                // so the gap starts half a gap before this frame's end.
                let size = box.labelSize
                let pill = NSRect(x: frame.maxX - box.gap / 2 + (box.padLeft ? 4 : 0) + 1, y: frame.minY + (DiffTheme.lineHeight - 15) / 2,
                                  width: ceil(size.width) + 8, height: 15)
                // See-through, so the pill takes the line's own color (green, blue or plain) instead
                // of sitting on it as a grey block.
                NSColor.white.withAlphaComponent(0.055).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
                (box.label as NSString).draw(at: NSPoint(x: pill.minX + 4, y: pill.minY + (15 - size.height) / 2),
                                             withAttributes: [.font: HintBox.font, .foregroundColor: DiffTheme.inlayText,
                                                              .paragraphStyle: HintBox.paragraph])
            }
        }
        var rects: [(NSRect, LineLensMark, Int)] = []
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: DiffTheme.lensText]
        for lens in lenses where lens.line >= firstLine && lens.line <= lastLine && lens.line < starts.count {
            let start = starts[lens.line]
            let end = lens.line + 1 < starts.count ? starts[lens.line + 1] - 1 : ns.length
            let lineEndX = end > start ? (segmentFrame(NSRange(location: start, length: end - start))?.maxX ?? 0) : textContainerOrigin.x
            // Each part is its own target, drawn lit while the pointer is on it.
            var x = lineEndX + 18
            let dot = (" · " as NSString), dotWidth = dot.size(withAttributes: attrs).width
            for (i, part) in lens.parts.enumerated() {
                if i > 0 {
                    dot.draw(at: NSPoint(x: x, y: y(ofLine: lens.line) + (DiffTheme.lineHeight - dot.size(withAttributes: attrs).height) / 2 + 0.5), withAttributes: attrs)
                    x += dotWidth
                }
                let size = (part.text as NSString).size(withAttributes: attrs)
                let r = NSRect(x: x, y: y(ofLine: lens.line) + (DiffTheme.lineHeight - size.height) / 2 + 0.5, width: ceil(size.width), height: size.height)
                var a = attrs
                if hoveredLens == LensHit(line: lens.line, part: i) {
                    a[.foregroundColor] = DiffTheme.accent
                    a[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                (part.text as NSString).draw(at: r.origin, withAttributes: a)
                rects.append((r, lens, i))
                x += ceil(size.width)
            }
        }
        // Only the lines this draw covered are replaced.
        for line in lensRectsByLine.keys where line >= firstLine && line <= lastLine { lensRectsByLine[line] = nil }
        for r in rects { lensRectsByLine[r.1.line, default: []].append(r) }
    }

    /// The lens under a point, if any.
    func lens(at point: NSPoint) -> (mark: LineLensMark, part: Int)? {
        lensRects.first { $0.0.insetBy(dx: -2, dy: -2).contains(point) }.map { ($0.1, $0.2) }
    }

    /// Colors names by what they are (functions, properties, parameters…), from the language
    /// server's semantic tokens, over the syntax colors. `display` maps a file line to its row.
    func applySemanticTokens(_ tokens: [SemanticToken], display: (Int) -> Int?) {
        guard let storage = textStorage, !tokens.isEmpty else { return }
        let ns = storage.string as NSString
        var starts: [Int] = [0], location = 0
        while true {
            let r = ns.range(of: "\n", options: .literal, range: NSRange(location: location, length: ns.length - location))
            if r.location == NSNotFound { break }
            location = NSMaxRange(r)
            starts.append(location)
        }
        storage.beginEditing()
        for t in tokens {
            guard let row = display(t.line), row < starts.count, let color = DiffTheme.semantic(t.type, modifiers: t.modifiers) else { continue }
            let lineEnd = row + 1 < starts.count ? starts[row + 1] - 1 : ns.length
            let start = starts[row] + t.character
            guard start + t.length <= lineEnd else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: start, length: t.length))
        }
        storage.endEditing()
        relayoutVisibleText()
    }

    /// The characters of the laid-out rows a rect covers.
    func characterRange(covering rect: NSRect) -> NSRange? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager, let storage = textStorage else { return nil }
        let origin = textContainerOrigin
        let top = tlm.textLayoutFragment(for: NSPoint(x: 0, y: max(0, rect.minY - origin.y)))
        let bottom = tlm.textLayoutFragment(for: NSPoint(x: 0, y: max(0, rect.maxY - origin.y)))
        let start = top.map { tcm.offset(from: tcm.documentRange.location, to: $0.rangeInElement.location) } ?? 0
        let end = bottom.map { tcm.offset(from: tcm.documentRange.location, to: $0.rangeInElement.endLocation) } ?? storage.length
        guard end > start else { return nil }
        return NSRange(location: start, length: min(end, storage.length) - start)
    }

    /// Changed-word marks, the full height of their row (rounded, inset a point).
    func drawWordHighlights(in rect: NSRect) {
        guard let storage = textStorage, let range = characterRange(covering: rect) else { return }
        storage.enumerateAttribute(.vetWordHighlight, in: range) { value, r, _ in
            guard let color = value as? NSColor, let frame = segmentFrame(r) else { return }
            let mark = NSRect(x: frame.minX - 1, y: frame.minY + 1, width: frame.width + 2, height: DiffTheme.lineHeight - 2)
            color.setFill()
            NSBezierPath(roundedRect: mark, xRadius: 3, yRadius: 3).fill()
        }
    }

    /// Fold rows drawn as WebStorm's separators: a wavy line across the row and a pill button
    /// (chevron and label) that lights up under the pointer.
    func drawFoldRows(in rect: NSRect) {
        guard let storage = textStorage, !foldLines.isEmpty, let range = characterRange(covering: rect) else { return }
        let hovered = hoveredFoldLine
        storage.enumerateAttribute(.vetFoldLabel, in: range) { value, r, _ in
            guard let label = value as? String, let frame = segmentFrame(NSRange(location: r.location, length: 1)) else { return }
            let row = NSRect(x: 0, y: frame.minY, width: max(bounds.width, enclosingScrollView?.contentSize.width ?? 0), height: DiffTheme.lineHeight)
            let lit = hovered == line(at: NSPoint(x: 0, y: row.midY))
            let reviewed = ((storage.attribute(.vetFold, at: r.location, effectiveRange: nil) as? Int) ?? 0) < 0
            if reviewed { DiffTheme.reviewedBand.setFill(); row.fill() } else { Self.drawWave(in: row) }
            let fg = lit ? DiffTheme.text : DiffTheme.foldLabel
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: fg, .paragraphStyle: HintBox.paragraph]
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [fg]))
            let chevron = reviewed
                ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Reviewed; show the change")?.withSymbolConfiguration(config)
                : NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: "Show unchanged lines")?.withSymbolConfiguration(config)
            let size = (label as NSString).size(withAttributes: attrs)
            let chevronWidth = chevron?.size.width ?? 0
            let pill = NSRect(x: textContainerOrigin.x, y: row.minY + 1.5, width: ceil(size.width) + chevronWidth + 22, height: DiffTheme.lineHeight - 3)
            (reviewed ? DiffTheme.reviewedPill : lit ? DiffTheme.foldPillHover : DiffTheme.foldPill).setFill()
            let shape = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
            shape.fill()
            DiffTheme.foldPillBorder.setStroke(); shape.lineWidth = 1; shape.stroke()
            var x = pill.minX + 8
            if let chevron {
                chevron.draw(in: NSRect(x: x, y: row.midY - chevron.size.height / 2, width: chevron.size.width, height: chevron.size.height))
                x += chevronWidth + 6
            }
            (label as NSString).draw(at: NSPoint(x: x, y: row.midY - size.height / 2), withAttributes: attrs)
        }
    }

    /// The thin wavy line WebStorm draws where unchanged lines are folded away.
    static func drawWave(in row: NSRect) {
        let wave = NSBezierPath()
        let mid = row.midY, amp: CGFloat = 1.6, step: CGFloat = 4
        var x = row.minX
        wave.move(to: NSPoint(x: x, y: mid))
        while x < row.maxX {
            wave.curve(to: NSPoint(x: x + step * 2, y: mid), controlPoint1: NSPoint(x: x + step * 0.5, y: mid - amp * 2), controlPoint2: NSPoint(x: x + step * 1.5, y: mid + amp * 2))
            x += step * 2
        }
        wave.lineWidth = 1
        DiffTheme.foldWave.setStroke()
        wave.stroke()
    }

    /// Re-applies the code font and row height after the text size changed (keeps edits).
    func applyCodeFont() {
        guard let storage = textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: all) { value, r, _ in
            if let f = value as? NSFont, f.isFixedPitch { storage.addAttribute(.font, value: DiffTheme.font, range: r) }
        }
        storage.addAttribute(.paragraphStyle, value: CodeTextView.paragraph, range: all)
        storage.endEditing()
        font = DiffTheme.font
        typingAttributes = CodeText.baseAttributes
        relayoutVisibleText()
    }

    // Pinch to change the code text size (every pane follows).
    override func magnify(with event: NSEvent) {
        pinch += event.magnification
        if abs(pinch) >= 0.12 {
            DiffTheme.setFontSize(DiffTheme.fontSize + (pinch > 0 ? 1 : -1))
            pinch = 0
        }
        if event.phase == .ended || event.phase == .cancelled { pinch = 0 }
    }
}

