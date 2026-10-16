import AppKit
import SwiftUI
import VetCore

/// Files tab: the whole project on the left, the open file on the right.
struct FilesView: View {
    let model: FilesModel
    var navigator: ((CodeTextView.Navigation, URL, String, Int, Int) -> Void)?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text(model.root?.lastPathComponent ?? "No project").font(.headline).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 8)
                FileListTreeView(model: model, version: model.treeVersion, selected: model.openURL.flatMap(model.relative))
            }
            .frame(minWidth: 220, idealWidth: 300, maxWidth: 520)
            VStack(spacing: 0) {
                header
                if let message = model.message {
                    Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.text != nil {
                    CodeEditorRepresentable(model: model, version: model.docVersion, jump: model.jumpSerial, navigator: navigator)
                } else {
                    Text("Choose a file").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: DiffTheme.background))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).disabled(!model.canGoBack).help("Back (⌘[)")
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).disabled(!model.canGoForward).help("Forward (⌘])")
            Text(model.relativePath ?? "").lineLimit(1).truncationMode(.middle)
            if model.isDirty { Circle().fill(.white.opacity(0.7)).frame(width: 7, height: 7).help("Unsaved changes") }
            Spacer()
            if model.changedOnDisk {
                Text("Changed on disk").foregroundStyle(.orange)
                Button("Reload") { model.revertToDisk() }.buttonStyle(.borderless)
            }
            if let error = model.error { Text(error).foregroundStyle(.red).lineLimit(1) }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .foregroundStyle(Color(nsColor: DiffTheme.text))
        .background(Color(nsColor: DiffTheme.foldBand))
    }
}

/// Hosts the AppKit code editor for the Files tab.
struct CodeEditorRepresentable: NSViewRepresentable {
    let model: FilesModel
    let version: Int
    let jump: Int
    var navigator: ((CodeTextView.Navigation, URL, String, Int, Int) -> Void)?

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
        view.contextItems = { [weak view, weak model] line, character in
            guard let model, let url = model.openURL else { return [] }
            return Self.menuItems(kind: { kind in
                guard let view else { return }
                navigator?(kind, url, view.currentText, line, character)
            }, copyLocation: "\(model.relativePath ?? url.path):\(line + 1)")
        }
        if view.shownVersion != version, let text = model.text {
            view.shownVersion = version
            view.shownJump = jump
            view.load(text, language: model.language, force: true)
            if let target = model.target { view.scrollTo(line: target.line, character: target.character) }
        } else if view.shownJump != jump {
            view.shownJump = jump
            if let target = model.target { view.scrollTo(line: target.line, character: target.character) }
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
