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
        v.onToggle = { [weak model] id, staged in model?.setHunk(id, staged: staged) }
        v.onFoldClick = { [weak model] id in model?.expandFold(id) }
        return v
    }

    func updateNSView(_ view: RibbonDiffNSView, context: Context) {
        if view.shownVersion != version {
            view.shownVersion = version
            view.show(model.diff, folding: model.folding, expanded: model.expandedFolds)
        }
        if jumpSerial != view.lastJump {
            view.lastJump = jumpSerial
            view.jump(forward: model.jump.forward)
        }
    }
}

/// HEAD on the left, the working file on the right, joined by the ribbon gutter.
final class RibbonDiffNSView: NSView {
    var onToggle: ((Int, Bool) -> Void)?
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
    private var syncing = false
    private var split: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "diffSplit")
        return v == 0 ? 0.5 : v
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
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
        gutter.onToggle = { [weak self] id, staged in self?.onToggle?(id, staged) }
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
        let keepLeft = leftScroll.contentView.bounds.origin, keepRight = rightScroll.contentView.bounds.origin
        shownPath = doc.change.path

        mode = switch doc.change.kind {
        case .added, .untracked: .rightOnly
        case .deleted: .leftOnly
        default: staging.head.count == 0 ? .rightOnly : .split
        }
        let layout = DiffLayout(headCount: staging.head.count, workCount: staging.work.count,
                                hunks: staging.hunks, folding: folding, expanded: expanded)
        diffLayout = layout
        var states: [Int: StageState] = [:]
        for h in staging.hunks { states[h.id] = staging.state(of: h) }

        var leftWords: [Int: [Range<Int>]] = [:], rightWords: [Int: [Range<Int>]] = [:]
        for h in staging.hunks {
            for w in h.wordChanges {
                leftWords[w.headLine] = w.headCols
                rightWords[w.workLine] = w.workCols
            }
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
                let alpha: CGFloat = states[id] == .staged ? 0.07 : 0.16
                if s.left.isEmpty { leftMarkers.append((s.left.lowerBound, color)) }
                else { leftBands.append(.init(lines: s.left, color: (h.work.isEmpty ? DiffTheme.removed : color).withAlphaComponent(alpha))) }
                if s.right.isEmpty { rightMarkers.append((s.right.lowerBound, color)) }
                else { rightBands.append(.init(lines: s.right, color: (h.head.isEmpty ? DiffTheme.added : color).withAlphaComponent(alpha))) }
            case .fold(let id):
                leftBands.append(.init(lines: s.left, color: DiffTheme.foldBand))
                rightBands.append(.init(lines: s.right, color: DiffTheme.foldBand))
                leftFolds[s.left.lowerBound] = id
                rightFolds[s.right.lowerBound] = id
            case .same: break
            }
        }
        leftText.bands = leftBands; rightText.bands = rightBands
        leftText.markers = leftMarkers.map { (line: $0.0, color: $0.1) }
        rightText.markers = rightMarkers.map { (line: $0.0, color: $0.1) }
        leftText.foldLines = leftFolds; rightText.foldLines = rightFolds
        leftText.window?.invalidateCursorRects(for: leftText)
        rightText.window?.invalidateCursorRects(for: rightText)

        gutter.mode = mode
        gutter.diffLayout = layout
        gutter.hunks = staging.hunks
        gutter.states = states
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
        if !samePath, mode == .split { align(from: rightScroll) }
        syncGutter()
        displayIfNeeded()
        Timing.diffShown(doc.change.path)
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
        let full = lines.joinedString()
        let tokens = Highlighter.tokens(full, language: language)
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        var offset = 0
        for l in lines.lines {
            starts.append(offset)
            offset += l.text.utf16.count + l.terminator.utf16.count
        }
        let base: [NSAttributedString.Key: Any] = [.font: DiffTheme.font, .foregroundColor: DiffTheme.text,
                                                   .paragraphStyle: CodeTextView.paragraph, .baselineOffset: 2]
        let out = NSMutableAttributedString()
        out.beginEditing()
        for d in display {
            let at = out.length
            switch d {
            case .code(let l):
                let line = String(lines.lines[l].text)
                out.append(NSAttributedString(string: line + "\n", attributes: base))
                let start = starts[l], length = line.utf16.count
                var k = firstToken(tokens, endingAfter: start)
                while k < tokens.count, tokens[k].range.location < start + length {
                    let t = tokens[k]
                    let lo = max(t.range.location, start), hi = min(t.range.location + t.range.length, start + length)
                    if hi > lo { out.addAttribute(.foregroundColor, value: DiffTheme.token(t.kind), range: NSRange(location: at + lo - start, length: hi - lo)) }
                    k += 1
                }
                for r in words[l] ?? [] where r.upperBound <= length {
                    out.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.35), range: NSRange(location: at + r.lowerBound, length: r.count))
                }
            case .fold(_, let hidden):
                var attrs = base
                attrs[.foregroundColor] = DiffTheme.lineNumber
                out.append(NSAttributedString(string: "   ⋯   \(hidden) unchanged lines\n", attributes: attrs))
            }
        }
        out.endEditing()
        return out
    }

    private static func firstToken(_ tokens: [Highlighter.Token], endingAfter offset: Int) -> Int {
        var lo = 0, hi = tokens.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if tokens[mid].range.location + tokens[mid].range.length <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo
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
        let centre = (src.contentView.bounds.midY - DiffTheme.inset.height) / DiffTheme.lineHeight
        let mapped = layout.map(Double(centre), fromLeft: fromLeft)
        let targetY = DiffTheme.inset.height + CGFloat(mapped) * DiffTheme.lineHeight - dst.contentView.bounds.height / 2
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
