import AppKit
import SwiftUI

/// Review notes in a popover beside their line: yours to read, edit or delete (or a new one to
/// write), and Claude's pointers to read and dismiss.
@MainActor
final class NotePopover {
    static let shared = NotePopover()
    private var popover: NSPopover?

    struct Actions {
        var save: (String?, String) -> Void // (note id, or nil for a new note; its text)
        var delete: (String) -> Void
        /// To Claude, to fix: (note id, or nil for a new note; its edited text, or nil when unchanged).
        var send: (String?, String?) -> Void
    }

    /// Shows a line's notes, or an empty one to write when `notes` is empty.
    func show(_ notes: [ReviewNote], line: Int, at rect: NSRect, in view: NSView, actions: Actions) {
        popover?.close()
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        let content = NoteList(notes: notes, line: line, close: { [weak p] in p?.close() }, actions: actions)
        p.contentViewController = NSHostingController(rootView: content)
        p.show(relativeTo: rect, of: view, preferredEdge: .maxX)
        popover = p
    }

    func close() { popover?.close() }

    /// Tests: a popover's content drawn off screen, to a PNG.
    static func debugRender(_ notes: [ReviewNote], line: Int, to path: String) {
        let view = NSHostingView(rootView: NoteList(notes: notes, line: line, close: {}, actions: .init(save: { _, _ in }, delete: { _ in }, send: { _, _ in }))
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

private struct NoteList: View {
    let notes: [ReviewNote]
    let line: Int
    let close: () -> Void
    let actions: NotePopover.Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if notes.isEmpty {
                NoteItem(note: nil, line: line, editing: true, close: close, actions: actions)
            }
            ForEach(Array(notes.enumerated()), id: \.element.id) { i, note in
                if i > 0 { Divider() }
                NoteItem(note: note, line: line, editing: false, close: close, actions: actions)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct NoteItem: View {
    let note: ReviewNote?
    let line: Int
    @State var editing: Bool
    let close: () -> Void
    let actions: NotePopover.Actions
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let claude = note?.isClaude == true
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                if claude { Image(systemName: "sparkle") }
                Text(claude ? "Claude" : note == nil ? "New note" : "Your note")
                Text("· line \(line + 1)").foregroundStyle(.tertiary)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            if editing {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(.horizontal, 4).padding(.vertical, 6)
                    .frame(height: 84)
                    .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
            } else {
                Text(note?.text ?? "")
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if claude {
                    Button("Dismiss") { if let note { actions.delete(note.id) }; close() }
                } else if editing {
                    let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button("Cancel") { if note == nil { close() } else { editing = false } }.keyboardShortcut(.cancelAction)
                    Button("Save") { actions.save(note?.id, text); close() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(empty)
                    // ⌘↩ saves the note and hands it to Claude to fix.
                    Button("Send to Claude") { actions.send(note?.id, text); close() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.glassProminent)
                        .disabled(empty)
                        .help("Save and send to Claude to fix (⌘↩)")
                } else {
                    if note?.sent == true { Text("Sent").font(.caption).foregroundStyle(.tertiary) }
                    Button("Delete") { if let note { actions.delete(note.id) }; close() }
                    Button("Edit") { text = note?.text ?? ""; editing = true; focused = true }
                    Button(note?.sent == true ? "Send Again" : "Send to Claude") { if let note { actions.send(note.id, nil) }; close() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.glassProminent)
                        .help("Send to Claude to fix (⌘↩)")
                }
            }
            .controlSize(.small)
        }
        .onAppear { if editing { text = note?.text ?? ""; focused = true } }
    }
}
