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

    init(title label: String, text value: String, editing: Bool, sent: Bool, fromClaude: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = DiffTheme.border.cgColor
        layer?.backgroundColor = DiffTheme.foldBand.cgColor
        title.stringValue = sent ? "\(label) · sent" : label
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = DiffTheme.foldLabel
        text.string = value
        text.isEditable = editing
        text.isSelectable = true
        text.drawsBackground = editing
        text.backgroundColor = DiffTheme.background
        text.textColor = DiffTheme.text
        text.font = Self.textFont
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
        buttons.alignment = .centerY
        buttons.spacing = 6
        if fromClaude {
            buttons.setViews([button("Dismiss", #selector(delete))], in: .trailing)
        } else if editing {
            let save = button("Save note", #selector(saveNote))
            save.keyEquivalent = "\r"
            save.keyEquivalentModifierMask = .command
            buttons.setViews([button("Cancel", #selector(cancel)), save], in: .trailing)
        } else {
            buttons.setViews([button("Edit", #selector(edit)), button("Delete", #selector(delete))], in: .trailing)
        }
        for v in [title, scroll, buttons] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 10, y: 6, width: bounds.width - 180, height: 16)
        buttons.frame = NSRect(x: bounds.width - 178, y: 3, width: 170, height: 20)
        scroll.frame = NSRect(x: 8, y: 24, width: bounds.width - 16, height: bounds.height - 30)
    }

    func focus() { window?.makeFirstResponder(text) }

    static let textFont = NSFont.systemFont(ofSize: 12.5)

    /// Rows a note needs at a card width: the header plus its text as wrapped.
    static func rows(for text: String, editing: Bool, width: CGFloat = 600) -> Int {
        if editing { return 6 }
        let textWidth = max(120, width - 16 - 10) // the text view's insets
        let height = (text as NSString).boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                     attributes: [.font: textFont]).height
        return max(2, Int(ceil((24 + height + 10) / DiffTheme.lineHeight)))
    }

    @objc private func saveNote() { onSave?(text.string) }
    @objc private func cancel() { onCancel?() }
    @objc private func edit() { onEdit?() }
    @objc private func delete() { onDelete?() }
}
