import AppKit
import SwiftUI
import VetCore

/// Hosts the AppKit code editor for the Files tab.
struct CodeEditorRepresentable: NSViewRepresentable {
    let model: FilesModel
    let version: Int
    let jump: Int
    var navigator: ((CodeTextView.Navigation, URL, String, Int, Int) -> Void)?
    var hover: ((URL, String, Int, Int) -> Void)?
    /// Loads semantic colors, hints, lenses and gutter icons for the shown text.
    var readingAids: ((CodeEditorView, URL) -> Void)?

    func makeNSView(context: Context) -> CodeEditorView {
        let v = model.editorView // kept by the model across tab switches
        v.onSave = { [weak model] text in model?.save(text) }
        v.onDirtyChange = { [weak model] dirty in model?.isDirty = dirty }
        model.editorText = { [weak v] in v?.fileText() }
        return v
    }

    func updateNSView(_ view: CodeEditorView, context: Context) {
        view.onNavigate = { [weak view, weak model] kind, line, character in
            guard let view, let model, let url = model.openURL else { return }
            navigator?(kind, url, view.currentText, line, character)
        }
        view.onHover = { [weak view, weak model] line, character in
            guard let view, let model, let url = model.openURL else { return }
            hover?(url, view.currentText, line, character)
        }
        view.contextItems = { [weak view, weak model] line, character in
            guard let model, let url = model.openURL else { return [] }
            return Self.menuItems(kind: { kind in
                guard let view else { return }
                navigator?(kind, url, view.currentText, line, character)
            }, copyLocation: "\(model.relativePath ?? url.path):\(line + 1)")
        }
        view.onTextSettled = { [weak view, weak model] in
            guard let view, let url = model?.openURL else { return }
            readingAids?(view, url)
        }
        if view.shownVersion != version, let text = model.text {
            view.shownVersion = version
            view.shownJump = jump
            view.load(text, language: model.language, force: true)
            if let url = model.openURL { readingAids?(view, url) }
            // After layout, so the target can sit a third of the way down.
            if let target = model.target { DispatchQueue.main.async { view.scrollTo(line: target.line, character: target.character) } }
        } else if view.shownJump != jump {
            view.shownJump = jump
            if let target = model.target { DispatchQueue.main.async { view.scrollTo(line: target.line, character: target.character) } }
        }
    }

    /// Go to definition / implementation, Find references, Copy path and line.
    @MainActor static func menuItems(kind: @escaping (CodeTextView.Navigation) -> Void, copyLocation: String) -> [NSMenuItem] {
        func item(_ title: String, _ key: String = "", _ action: @escaping () -> Void) -> NSMenuItem {
            let i = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
            return i
        }
        return [
            item("Go to definition") { kind(.definition) },
            item("Go to implementation") { kind(.implementation) },
            item("Find references") { kind(.references) },
            .separator(),
            item("Copy path and line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyLocation, forType: .string)
            },
        ]
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, keyEquivalent: String = "", action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}
