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
                    Button("Cancel") { if note == nil { close() } else { editing = false } }.keyboardShortcut(.cancelAction)
                    Button("Save") { actions.save(note?.id, text); close() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.glassProminent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("Delete") { if let note { actions.delete(note.id) }; close() }
                    Button("Edit") { text = note?.text ?? ""; editing = true; focused = true }
                }
            }
            .controlSize(.small)
        }
        .onAppear { if editing { text = note?.text ?? ""; focused = true } }
    }
}
