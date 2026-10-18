import AppKit
import SwiftUI

struct OutputText: NSViewRepresentable {
    let text: String
    let version: Int
    let epoch: Int

    final class Coordinator {
        var shown = -1
        var shownEpoch = -1
        var shownBytes = 0
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        tv.textColor = DiffTheme.text
        tv.backgroundColor = DiffTheme.background
        scroll.backgroundColor = DiffTheme.background
        tv.textContainerInset = NSSize(width: 8, height: 6)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.shown != version, let tv = scroll.documentView as? NSTextView else { return }
        let c = context.coordinator
        c.shown = version
        let atBottom = scroll.contentView.bounds.maxY >= (tv.frame.height - 30)
        let bytes = text.utf8
        if c.shownEpoch == epoch, c.shownBytes <= bytes.count, let storage = tv.textStorage {
            // Only the new output: appending keeps a chatty dev server cheap.
            let added = String(text[bytes.index(bytes.startIndex, offsetBy: c.shownBytes)...])
            storage.append(NSAttributedString(string: added, attributes: [.font: tv.font as Any, .foregroundColor: DiffTheme.text]))
        } else {
            tv.string = text
            c.shownEpoch = epoch
        }
        c.shownBytes = bytes.count
        if atBottom { tv.scrollToEndOfDocument(nil) } // follow new output unless you scrolled up
    }
}

/// Add, edit and remove run configurations.
struct RunConfigEditor: View {
    let run: RunModel
    @Binding var isPresented: Bool
    @State private var draft: [RunConfig] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run Configurations").font(.title3)
            Text("A shell command run in the project folder, e.g. npm run start, python3 app.py, ./gradlew run.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($draft) { $c in
                        HStack(spacing: 8) {
                            TextField("Name", text: $c.name).frame(width: 130)
                            TextField("Command", text: $c.command)
                            TextField("Folder", text: $c.cwd).frame(width: 90)
                            Button { draft.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Remove")
                        }
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 300)
            HStack {
                Button { draft.append(RunConfig(name: "", command: "")) } label: { Label("Add", systemImage: "plus") }
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Save") { run.setConfigs(draft); isPresented = false }.keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 640)
        .onAppear { draft = run.configs.isEmpty ? [RunConfig(name: "", command: "")] : run.configs }
    }
}
