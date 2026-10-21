import AppKit
import SwiftUI
import VetCore

/// Clicking a change bar in the editor's gutter: the file as it was in the last commit, in a
/// read-only editor like the usages preview, scrolled to those lines and banded as the diff bands
/// them — the old version in its context, as JetBrains IDEs show it. Show Changes opens the diff.
@MainActor
enum ChangeBarPopover {
    private static var popover: NSPopover?

    /// `head`: the last commit's file (nil for a new file). `tokens`: the language server's name
    /// colors for that text.
    static func show(_ bar: LineNumberGutter.ChangeBar, head: TextLines?, url: URL, tokens: ((URL, String) async -> [SemanticToken])?,
                     at rect: NSRect, in view: NSView, showChanges: @escaping () -> Void) {
        popover?.close()
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        let old = bar.old.isEmpty ? nil : head
        let host = NSHostingController(rootView: ChangeBarView(bar: bar, head: old, url: url, tokens: tokens, showChanges: { [weak p] in
            p?.close()
            showChanges()
        }))
        if old != nil {
            host.sizingOptions = []
            host.view.frame = NSRect(x: 0, y: 0, width: 760, height: 300)
            p.contentSize = NSSize(width: 760, height: 300)
        } else {
            host.sizingOptions = .preferredContentSize
        }
        p.contentViewController = host
        popover = p
        p.show(relativeTo: rect, of: view, preferredEdge: .maxX)
    }
}

private struct ChangeBarView: View {
    let bar: LineNumberGutter.ChangeBar
    let head: TextLines?
    let url: URL
    let tokens: ((URL, String) async -> [SemanticToken])?
    let showChanges: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).fontWeight(.semibold)
                if head != nil { Text(lines).foregroundStyle(.secondary) }
                Spacer(minLength: 24)
                Button("Show Changes", action: showChanges).buttonStyle(.hand)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .frame(height: 32)
            if let head {
                Divider()
                OldVersionPreview(lines: head, url: url, old: bar.oldStart..<(bar.oldStart + bar.old.count),
                                  color: DiffTheme.block(bar.kind), tokens: tokens)
            }
        }
        .frame(minWidth: 260)
    }

    private var title: String {
        switch bar.kind {
        case .inserted: bar.lines.count == 1 ? "1 new line" : "\(bar.lines.count) new lines"
        case .modified: "Before"
        case .deleted: bar.old.count == 1 ? "1 line removed" : "\(bar.old.count) lines removed"
        }
    }

    /// Where the old lines were, as the last commit numbers them.
    private var lines: String {
        bar.old.count == 1 ? "line \(bar.oldStart + 1)" : "lines \(bar.oldStart + 1)–\(bar.oldStart + bar.old.count)"
    }
}

/// The last commit's file in a read-only editor (line numbers, pinned declarations, the server's
/// name colors), the old lines banded a third of the way down.
private struct OldVersionPreview: NSViewRepresentable {
    let lines: TextLines
    let url: URL
    let old: Range<Int>
    let color: NSColor
    let tokens: ((URL, String) async -> [SemanticToken])?

    func makeNSView(context: Context) -> CodeEditorView {
        let v = CodeEditorView()
        v.readOnly = true
        v.load(lines, language: CodeLanguage(path: url.path), force: true)
        if let tokens {
            let text = v.currentText, url = url
            Task { @MainActor [weak v] in
                let found = await tokens(url, text)
                guard let v, v.currentText == text else { return }
                v.pane.applySemanticTokens(found, display: { $0 })
            }
        }
        // After layout, so the lines can sit a third of the way down.
        let old = old, color = color
        DispatchQueue.main.async { [weak v] in
            guard let v else { return }
            v.reveal(line: old.lowerBound, columns: nil)
            v.pane.bands = [.init(lines: old, color: color)]
        }
        return v
    }

    func updateNSView(_ v: CodeEditorView, context: Context) {}
}
