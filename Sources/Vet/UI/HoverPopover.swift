import AppKit
import SwiftUI
import VetCore

/// What the language server says about the symbol under the pointer.
struct HoverContent: Equatable {
    var signature: String
    var documentation: String
    var language: CodeLanguage
}

/// Hover info: rest the pointer on a symbol and a popover shows its signature and docs, as in
/// VS Code and WebStorm. It stays while the pointer is on the symbol or inside the popover (so
/// you can select and copy from it) and goes away when you move off, type, scroll or click.
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
        let host = NSHostingController(rootView: HoverView(content: content))
        host.sizingOptions = []
        // Measure the content at most 560 pt wide (wrapping), and size the popover to it.
        let fit = host.sizeThatFits(in: NSSize(width: 560, height: 2000))
        let size = NSSize(width: ceil(min(560, max(140, fit.width))), height: ceil(min(520, fit.height)))
        host.view.frame = NSRect(origin: .zero, size: size)
        popover.contentViewController = host
        popover.contentSize = size
        popover.show(relativeTo: p.rect, of: p.view, preferredEdge: .maxY)
        self.popover = popover
        shownKey = p.key
        shownAnchor = (p.view, p.rect)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .scrollWheel, .keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        popover?.close()
        popover = nil
        shownKey = nil
        shownAnchor = nil
    }

    private func handle(_ event: NSEvent) {
        guard let popover else { return }
        let popoverWindow = popover.contentViewController?.view.window
        switch event.type {
        case .keyDown, .scrollWheel:
            if event.window !== popoverWindow { close() }
        case .leftMouseDown, .rightMouseDown:
            if event.window !== popoverWindow { close() }
        case .mouseMoved:
            guard let anchor = shownAnchor, let window = anchor.view.window else { close(); return }
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
    }

    func popoverDidClose(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        popover = nil
        shownKey = nil
        shownAnchor = nil
    }
}

/// The popover's content: the signature in the code font and colors, then the documentation.
private struct HoverView: View {
    let content: HoverContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !content.signature.isEmpty {
                Text(Self.code(content.signature, content.language))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let blocks = Self.blocks(content.documentation)
            if !content.signature.isEmpty, !blocks.isEmpty { Divider() }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let s):
                    Text(Self.markdown(s))
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let s):
                    Text(Self.code(s, content.language))
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 560, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)

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
