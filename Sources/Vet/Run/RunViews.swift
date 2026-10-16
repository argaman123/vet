import AppKit
import SwiftUI

/// Run/Stop and the output toggle at the bottom of the rail.
struct RunControls: View {
    let run: RunModel
    @Binding var editing: Bool

    var body: some View {
        VStack(spacing: 10) {
            Button { run.outputVisible.toggle() } label: {
                Image(systemName: "rectangle.bottomthird.inset.filled")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(run.outputVisible ? Color.white : Color.primary)
                    .frame(width: 38, height: 38)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(run.outputVisible ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .circle)
            .help(run.outputVisible ? "Hide output" : "Show output")

            Button {
                if run.configs.isEmpty { editing = true } else { run.toggle() }
            } label: {
                Image(systemName: run.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(run.isRunning ? Color.red : Color.green)
                    .frame(width: 38, height: 38)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .overlay(alignment: .topTrailing) {
                if run.crashed { Circle().fill(.red).frame(width: 9, height: 9).offset(x: 1, y: -1) }
            }
            .help(run.isRunning ? "Stop \(run.selected?.name ?? "")" : run.configs.isEmpty ? "Add a run configuration" : "Run \(run.selected?.name ?? "")")
            .contextMenu {
                ForEach(run.configs) { c in
                    Button { run.selectedID = c.id } label: {
                        if c.id == run.selected?.id { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                    }
                }
                if !run.configs.isEmpty { Divider() }
                Button("Edit Run Configurations…") { editing = true }
                Button(run.outputVisible ? "Hide Output" : "Show Output") { run.outputVisible.toggle() }
            }
        }
    }
}

/// The bottom panel with the running app's output.
struct OutputPanel: View {
    let run: RunModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(run.isRunning ? Color.green : (run.crashed ? Color.red : Color.secondary)).frame(width: 7, height: 7)
                Text(run.selected?.name ?? "Output").font(.callout)
                Spacer()
                Button("Clear") { run.clearOutput() }.buttonStyle(.borderless)
                Button { run.outputVisible = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Hide output")
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color(nsColor: DiffTheme.foldBand))
            OutputText(text: run.output, version: run.outputVersion)
        }
        .frame(height: 240)
    }
}

struct OutputText: NSViewRepresentable {
    let text: String
    let version: Int

    final class Coordinator { var shown = -1 }
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
        context.coordinator.shown = version
        let atBottom = scroll.contentView.bounds.maxY >= (tv.frame.height - 30)
        tv.string = text
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
