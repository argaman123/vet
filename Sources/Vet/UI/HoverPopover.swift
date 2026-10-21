import AppKit
import SwiftUI
import VetCore

/// What the language server says about the symbol under the pointer.
struct HoverContent: Equatable {
    var signature: String
    var documentation: String
    var language: CodeLanguage
}

/// Hover info: rest the pointer on a symbol and a popover shows its signature and the start of its
/// docs, as WebStorm does; F1 (or More) shows all of it. It stays while the pointer is on the
/// symbol or inside the popover (so you can select and copy from it) and goes away when you move
/// off, type, scroll or click.
@MainActor
final class HoverPresenter: NSObject, NSPopoverDelegate {
    static let shared = HoverPresenter()
    private var popover: NSPopover?
    private var monitor: Any?
    /// The request being answered: the view and the symbol's rect in it, and its token.
    private var pending: (view: NSView, rect: NSRect, key: String, token: Int)?
    private var tokens = 0
    /// The token of the latest request; an answer carrying any other token is stale.
    private(set) var currentToken = 0
    private var shownKey: String?
    private var shownAnchor: (view: NSView, rect: NSRect)?
    private var shownContent: HoverContent?

    /// Called when the pointer has rested on a symbol; `show` follows if the server answers.
    func prepare(view: NSView, rect: NSRect, key: String) {
        guard key != shownKey || popover == nil else { return }
        tokens += 1
        currentToken = tokens
        pending = (view, rect, key, tokens)
    }

    /// Drops a request whose answer hasn't arrived (the pointer moved on).
    func cancelPending() { pending = nil }

    func isShowing(_ key: String) -> Bool { popover != nil && shownKey == key }

    /// Shows the answer to request `token`; a late answer to an older request is dropped.
    func show(_ content: HoverContent, token: Int) {
        guard let p = pending, p.token == token, p.view.window != nil else { return }
        pending = nil
        close()
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = host(content, expanded: false, popover: popover)
        popover.show(relativeTo: p.rect, of: p.view, preferredEdge: .maxY)
        self.popover = popover
        shownKey = p.key
        shownAnchor = (p.view, p.rect)
        shownContent = content
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .scrollWheel, .keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// The popover's content, measured at most 560 pt wide (wrapping), and the popover sized to it.
    private func host(_ content: HoverContent, expanded: Bool, popover: NSPopover) -> NSViewController {
        let host = NSHostingController(rootView: HoverView(content: content, expanded: expanded) { [weak self] in self?.expand() })
        host.sizingOptions = []
        let fit = host.sizeThatFits(in: NSSize(width: 560, height: 2000))
        let size = NSSize(width: ceil(min(560, max(140, fit.width))), height: ceil(min(520, fit.height)))
        host.view.frame = NSRect(origin: .zero, size: size)
        popover.contentSize = size
        return host
    }

    /// The whole documentation, in place of the short version.
    func expand() {
        guard let popover, let content = shownContent, HoverView.isLong(content) else { return }
        popover.contentViewController = host(content, expanded: true, popover: popover)
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        popover?.close()
        popover = nil
        shownKey = nil
        shownAnchor = nil
        shownContent = nil
    }

    /// True when the event was used here (F1 expands the docs, as Quick Documentation does).
    private func handle(_ event: NSEvent) -> Bool {
        guard let popover else { return false }
        let popoverWindow = popover.contentViewController?.view.window
        if event.type == .keyDown, event.keyCode == 122, let content = shownContent, HoverView.isLong(content) { // F1
            expand()
            return true
        }
        switch event.type {
        case .keyDown, .scrollWheel:
            if event.window !== popoverWindow { close() }
        case .leftMouseDown, .rightMouseDown:
            if event.window !== popoverWindow { close() }
        case .mouseMoved:
            guard let anchor = shownAnchor, let window = anchor.view.window else { close(); return false }
            let screen = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            let symbol = window.convertToScreen(anchor.view.convert(anchor.rect, to: nil)).insetBy(dx: -3, dy: -3)
            // The gap between the symbol and the popover counts as inside, so you can move into it.
            let frame = popoverWindow?.frame ?? .zero
            let bridge = symbol.union(frame).insetBy(dx: 0, dy: -2)
            let inBridge = bridge.contains(screen) && screen.x >= min(symbol.minX, frame.minX) && screen.x <= max(symbol.maxX, frame.maxX)
            if !symbol.contains(screen), !frame.contains(screen), !(inBridge && abs(screen.x - symbol.midX) < max(symbol.width, 40)) {
                close()
            }
        default: break
        }
        return false
    }

    func popoverDidClose(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        popover = nil
        shownKey = nil
        shownAnchor = nil
        shownContent = nil
    }
}

/// The popover's content: the signature in the code font and colors, then the documentation.
/// Short by default, as WebStorm's hover: the signature (a few lines at most) and the docs' first
/// paragraph; `expanded` shows everything.
private struct HoverView: View {
    let content: HoverContent
    var expanded = false
    var expand: () -> Void = {}

    /// Short-version limits.
    static let signatureLines = 4, summaryLines = 3

    /// Whether the short version leaves something out.
    static func isLong(_ content: HoverContent) -> Bool {
        let blocks = blocks(content.documentation)
        let signatureLines = content.signature.components(separatedBy: "\n").count
        if blocks.count > 1 || signatureLines > Self.signatureLines { return true }
        if case .text(let s)? = blocks.first {
            let summary = firstParagraph(s)
            return summary != s.trimmingCharacters(in: .whitespacesAndNewlines) || summary.count > 220 || summary.components(separatedBy: "\n").count > summaryLines
        }
        return false
    }

    var body: some View {
        let all = Self.blocks(content.documentation)
        // The short version keeps the first paragraph of prose.
        let blocks = expanded ? all : Array(all.prefix { if case .text = $0 { true } else { false } }.prefix(1))
        VStack(alignment: .leading, spacing: 8) {
            if !content.signature.isEmpty {
                Text(Self.code(content.signature, content.language))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(expanded ? nil : Self.signatureLines)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !content.signature.isEmpty, !blocks.isEmpty { Divider() }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let s):
                    Text(Self.markdown(expanded ? s : Self.firstParagraph(s)))
                        .font(.callout)
                        .lineLimit(expanded ? nil : Self.summaryLines)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let s):
                    Text(Self.code(s, content.language))
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !expanded, Self.isLong(content) {
                Button(action: expand) {
                    HStack(spacing: 6) {
                        Text("More")
                        Text("F1").foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                }
                .buttonStyle(.hand)
                .help("Show the whole documentation (F1)")
            }
        }
        .padding(12)
        // As wide as the text needs, wrapping at the 560 pt the presenter offers.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Prose up to the first blank line or tag (the summary JSDoc and Swift docs start with).
    static func firstParagraph(_ s: String) -> String {
        var out: [String] = []
        for line in s.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("@") || t.hasPrefix("- ") && !out.isEmpty { break }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    enum Block { case text(String), code(String) }

    /// Splits markdown into prose and fenced code blocks.
    static func blocks(_ markdown: String) -> [Block] {
        var out: [Block] = [], prose: [String] = [], code: [String]? = nil
        func flushProse() {
            let s = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(.text(s)) }
            prose = []
        }
        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let c = code {
                    let s = c.joined(separator: "\n").trimmingCharacters(in: .newlines)
                    if !s.isEmpty { out.append(.code(s)) }
                    code = nil
                } else {
                    flushProse()
                    code = []
                }
            } else if code != nil {
                code!.append(line)
            } else {
                prose.append(line)
            }
        }
        if let c = code, !c.isEmpty { out.append(.code(c.joined(separator: "\n"))) }
        flushProse()
        return out
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: tags(s), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    /// JSDoc tags as VS Code shows them: "*@param* `name` — text" on one line.
    static func tags(_ s: String) -> String {
        var lines = s.components(separatedBy: "\n"), out: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let m = line.wholeMatch(of: /@(\w+)(?:\s+(\S+))?\s*(.*)/) {
                var text = String(m.3)
                if text.isEmpty, i + 1 < lines.count, !lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty, !lines[i + 1].hasPrefix("@") {
                    i += 1
                    text = lines[i]
                }
                // The server's own "name - text" dash would double the one added here.
                text = text.replacing(/^\s*[-–—]\s*/, with: "")
                let name = m.2.map { " `\($0)`" } ?? ""
                out.append("*@\(m.1)*\(name)\(text.isEmpty ? "" : " — \(text)")")
            } else {
                out.append(line)
            }
            i += 1
        }
        lines = out
        return lines.joined(separator: "\n")
    }

    /// Code with the editor's colors (never plain white).
    @MainActor static func code(_ s: String, _ language: CodeLanguage) -> AttributedString {
        CodeText.line(s, language: language)
    }

}
