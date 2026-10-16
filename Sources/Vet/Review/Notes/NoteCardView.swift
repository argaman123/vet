import AppKit

/// A note card shown in the rows reserved under a line: editable while new or being edited.
final class NoteCardView: NSView, NSTextViewDelegate {
    var onSave: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    private let title = NSTextField(labelWithString: "")
    private let scroll = NSTextView.scrollableTextView()
    private var text: NSTextView { scroll.documentView as! NSTextView }
    private let buttons = NSStackView()

    init(title label: String, text value: String, editing: Bool, sent: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = DiffTheme.border.cgColor
        layer?.backgroundColor = DiffTheme.foldBand.cgColor
        title.stringValue = sent ? "\(label) · sent" : label
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = DiffTheme.lineNumber
        text.string = value
        text.isEditable = editing
        text.isSelectable = true
        text.drawsBackground = editing
        text.backgroundColor = DiffTheme.background
        text.textColor = DiffTheme.text
        text.font = .systemFont(ofSize: 12.5)
        text.delegate = self
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = editing
        scroll.borderType = .noBorder
        func button(_ t: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: t, target: self, action: action)
            b.bezelStyle = .accessoryBarAction
            b.controlSize = .small
            return b
        }
        buttons.orientation = .horizontal
        buttons.spacing = 6
        if editing {
            buttons.addArrangedSubview(button("Cancel", #selector(cancel)))
            let save = button("Save note", #selector(saveNote))
            save.keyEquivalent = "\r"
            save.keyEquivalentModifierMask = .command
            buttons.addArrangedSubview(save)
        } else {
            buttons.addArrangedSubview(button("Edit", #selector(edit)))
            buttons.addArrangedSubview(button("Delete", #selector(delete)))
        }
        for v in [title, scroll, buttons] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 10, y: 6, width: bounds.width - 180, height: 16)
        buttons.frame = NSRect(x: bounds.width - 170, y: 2, width: 162, height: 22)
        buttons.alignment = .trailing
        scroll.frame = NSRect(x: 8, y: 24, width: bounds.width - 16, height: bounds.height - 30)
    }

    func focus() { window?.makeFirstResponder(text) }

    /// Rows a note needs: its text lines plus the header.
    static func rows(for text: String, editing: Bool) -> Int {
        editing ? 6 : max(3, text.split(separator: "\n", omittingEmptySubsequences: false).count + 2)
    }

    @objc private func saveNote() { onSave?(text.string) }
    @objc private func cancel() { onCancel?() }
    @objc private func edit() { onEdit?() }
    @objc private func delete() { onDelete?() }
}
