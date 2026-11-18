import AppKit
import SwiftUI

/// Review notes in a popover beside their line: yours to read, edit or delete (or a new one to
/// write), and Claude's pointers to read and dismiss.
@MainActor
final class NotePopover: NSObject, NSPopoverDelegate {
    static let shared = NotePopover()
    private var popover: NSPopover?
    /// What closing keeps: each open note's unsaved text, saved when the popover closes.
    private let drafts = Drafts()
    /// Whether a Claude chat is listening on the project (set by the app): sending reaches it now.
    static var isListening: () -> Bool = { false }

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
        p.delegate = self
        p.behavior = .transient
        p.animates = true
        p.appearance = NSAppearance(named: .darkAqua)
        let content = NoteList(notes: notes, line: line, close: { [weak p] in p?.close() }, actions: actions, drafts: drafts)
        p.contentViewController = NSHostingController(rootView: content)
        p.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .maxY : .minY) // under the line (above near the bottom): the arrow on an edge, not wedged in a corner
        popover = p
        // Notes open to read: their text is editable, but nothing takes the caret until clicked.
        if !notes.isEmpty { DispatchQueue.main.async { [weak p] in p?.contentViewController?.view.window?.makeFirstResponder(nil) } }
    }

    func close() { popover?.close() }

    func popoverDidClose(_ notification: Notification) {
        let pending = drafts.saves.values
        drafts.saves = [:]
        pending.forEach { $0() }
    }

    /// Tests: a popover's content drawn off screen, to a PNG.
    static func debugRender(_ notes: [ReviewNote], line: Int, to path: String) {
        let view = NSHostingView(rootView: NoteList(notes: notes, line: line, close: {}, actions: .init(save: { _, _ in }, delete: { _ in }, send: { _, _ in }), drafts: Drafts())
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

@MainActor
final class Drafts {
    var saves: [String: () -> Void] = [:]
}

private struct NoteList: View {
    let notes: [ReviewNote]
    let line: Int
    let close: () -> Void
    let actions: NotePopover.Actions
    let drafts: Drafts

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if notes.isEmpty {
                NoteItem(note: nil, line: line, editing: true, close: close, actions: actions, drafts: drafts)
            }
            ForEach(Array(notes.enumerated()), id: \.element.id) { i, note in
                if i > 0 { Divider() }
                NoteItem(note: note, line: line, editing: false, close: close, actions: actions, drafts: drafts)
            }
        }
        .padding(14)
        .frame(width: 320)
        // The window's dark tone over the popover's glass, out to its edges and arrow.
        .background(Glass.sheet.padding(-60))
    }
}

private struct NoteItem: View {
    let note: ReviewNote?
    let line: Int
    let editing: Bool // a new note: the field starts focused
    let close: () -> Void
    let actions: NotePopover.Actions
    let drafts: Drafts
    @State private var text = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var key: String { note?.id ?? "new" }

    var body: some View {
        let claude = note?.isClaude == true
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                if claude { Image(systemName: RibbonGutterView.claudeSymbol) }
                Text(note?.isExplanation == true ? "\(Agent.name) on this change" : note?.isReply == true ? "\(Agent.name) replied" : claude ? Agent.name : note == nil ? "New note" : "Your note")
                Text("· line \(line + 1)").foregroundStyle(.tertiary)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            // A reply: what you wrote, quoted above Claude's answer.
            if let question = note?.question {
                Text(question)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Capsule().fill(.quaternary).frame(width: 2) }
                    .fixedSize(horizontal: false, vertical: true)
            }
            if claude {
                Text(note?.text ?? "")
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Your note is its own editor: click the text to change it; it keeps when the popover closes.
                TextField("", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(note == nil ? 3 ... 14 : 1 ... 14)
                    .focused($focused)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(Glass.fill.opacity(focused ? 1 : hovering ? 0.6 : 0), in: .rect(cornerRadius: Glass.rowRadius))
                    .padding(.horizontal, -7)
                    .onHover { hovering = $0 }
                    .animation(Motion.quick, value: focused)
                    .animation(Motion.quick, value: hovering)
            }
            HStack(spacing: 6) {
                if note?.isExplanation == true {
                } else if claude {
                    Spacer()
                    Button { if let note { actions.delete(note.id) }; close() } label: { Image(systemName: "xmark") }
                        .buttonStyle(PanelIconButtonStyle()).help("Dismiss").accessibilityLabel("Dismiss")
                } else {
                    let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let changed = text != (note?.text ?? "")
                    Button { drafts.saves[key] = nil; if let note { actions.delete(note.id) }; close() } label: { Image(systemName: "trash.fill") }
                        .buttonStyle(DeleteButtonStyle()).help("Delete").accessibilityLabel("Delete")
                    Spacer()
                    // ⌘↩ hands the note (as it reads now) to the agent to fix.
                    Button(note?.sent == true && !changed ? "Send Again" : "Send") { drafts.saves[key] = nil; actions.send(note?.id, changed ? text : nil); close() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(PanelButtonStyle(prominent: true))
                        .disabled(empty)
                        .help("Send (⌘↩)")
                }
            }
        }
        .onAppear {
            text = note?.text ?? ""
            if editing { focused = true }
        }
        // Closing keeps what you wrote: a new note stays as an unsent one, an edit is saved.
        .onChange(of: text) { _, now in
            let keep = !claude && now != (note?.text ?? "") && !now.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let (save, id) = (actions.save, note?.id)
            drafts.saves[key] = keep ? { save(id, now) } : nil
        }
    }
}
