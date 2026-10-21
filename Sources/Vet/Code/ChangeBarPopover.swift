import AppKit
import Observation
import SwiftUI
import VetCore

/// Clicking a change bar in the editor's gutter: what those lines were in the last commit, as in
/// JetBrains IDEs, with a way into the full diff.
@MainActor
enum ChangeBarPopover {
    private static var popover: NSPopover?

    /// `semantic`: the language server's tokens for the last commit's file; the old lines take
    /// its name colors when they arrive.
    static func show(_ bar: LineNumberGutter.ChangeBar, language: CodeLanguage, semantic: (() async -> [SemanticToken])?,
                     at rect: NSRect, in view: NSView, showChanges: @escaping () -> Void) {
        popover?.close()
        let old = OldLines(CodeText.lines(bar.old, language: language))
        if let semantic, !bar.old.isEmpty {
            Task { @MainActor in
                let tokens = await semantic()
                if !tokens.isEmpty { old.lines = CodeText.lines(bar.old, language: language, semantic: tokens, firstLine: bar.oldStart) }
            }
        }
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        let host = NSHostingController(rootView: ChangeBarView(bar: bar, old: old, showChanges: { [weak p] in
            p?.close()
            showChanges()
        }))
        host.sizingOptions = .preferredContentSize
        p.contentViewController = host
        popover = p
        p.show(relativeTo: rect, of: view, preferredEdge: .maxX)
    }
}

@MainActor @Observable
private final class OldLines {
    var lines: [AttributedString]
    init(_ lines: [AttributedString]) { self.lines = lines }
}

private struct ChangeBarView: View {
    let bar: LineNumberGutter.ChangeBar
    /// The old lines in the editor's colors.
    let old: OldLines
    let showChanges: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer(minLength: 24)
                Button("Show Changes", action: showChanges).buttonStyle(.hand).font(.callout)
            }
            if !bar.old.isEmpty {
                ScrollView([.vertical, .horizontal]) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .trailing, spacing: 0) {
                            ForEach(Array(bar.old.indices), id: \.self) { i in
                                Text("\(bar.oldStart + i + 1)").foregroundStyle(.tertiary)
                            }
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(old.lines.enumerated()), id: \.offset) { _, line in
                                Text(line.characters.isEmpty ? AttributedString(" ") : line).textSelection(.enabled)
                            }
                        }
                    }
                    .font(Font(DiffTheme.font))
                    .fixedSize()
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: 640, maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(minWidth: 260)
    }

    private var title: String {
        switch bar.kind {
        case .inserted: bar.lines.count == 1 ? "1 new line" : "\(bar.lines.count) new lines"
        case .modified: "Before"
        case .deleted: bar.old.count == 1 ? "1 line removed" : "\(bar.old.count) lines removed"
        }
    }
}
