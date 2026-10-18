import AppKit
import SwiftUI
import VetCore

/// The main area: the diff, the editor or the browser, with Run's output below when shown.
struct MainArea: View {
    let app: AppDelegate

    @AppStorage("outputHeight") private var outputHeight = 220.0
    @State private var dragStart: Double?

    var body: some View {
        let run = app.workspace.run
        // A plain stack with a drag handle: SwiftUI's VSplitView gives its lower pane the
        // toolbar's safe-area inset, leaving a blank band above the output.
        GeometryReader { geo in
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) { Banner(app: app) }
                    .overlay(alignment: .bottom) { Toast(app: app) }
                if run.outputVisible {
                    Divider()
                        .overlay {
                            Color.clear
                                .frame(height: 7)
                                .contentShape(Rectangle())
                                .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                    .onChanged { g in
                                        let start = dragStart ?? outputHeight
                                        if dragStart == nil { dragStart = start }
                                        outputHeight = min(max(100, start - g.translation.height), max(100, geo.size.height - 160))
                                    }
                                    .onEnded { _ in dragStart = nil })
                        }
                    OutputPane(app: app)
                        .frame(height: min(outputHeight, max(100, geo.size.height - 160)))
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch app.ui.location {
        case .diff?: DiffScreen(app: app)
        case .file?: EditorScreen(app: app)
        case .browser?: BrowserScreen(app: app)
        case nil: Placeholder(app: app)
        }
    }
}

private struct Placeholder: View {
    let app: AppDelegate
    var body: some View {
        VStack(spacing: 6) {
            if app.projects.current == nil {
                Text("Open a project to start").font(.title3)
                Button("Open Folder…") { app.projects.showOpenPanel() }.buttonStyle(.glassProminent).padding(.top, 6)
            } else {
                Text("Select a change to review").font(.title3).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: Diff

struct DiffScreen: View {
    let app: AppDelegate

    var body: some View {
        let review = app.workspace.review
        VStack(spacing: 0) {
            if let doc = review.diff {
                DiffHeader(app: app, doc: doc)
            }
            RibbonDiffView(model: review, version: review.diffVersion, jumpSerial: review.jump.serial)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// The diff's header: the file, its review state and its actions.
struct DiffHeader: View {
    let app: AppDelegate
    let doc: DiffDocument

    var body: some View {
        let review = app.workspace.review
        // The file as git sees it now (the diff's copy keeps the state it was loaded with).
        let change = review.changes.first { $0.path == doc.change.path } ?? doc.change
        HeaderBar {
            TriStateCheckbox(state: review.stage(of: change)) { on in
                if let node = FileTreeNode.build([change]).first.map(leaf) { review.setStaged(node, on) }
            }
            Image(nsImage: FileIcons.icon(for: change.path)).resizable().frame(width: 16, height: 16)
            Text((change.path as NSString).lastPathComponent).fontWeight(.semibold).foregroundStyle(change.kind.color)
            if let orig = change.origPath {
                Text("renamed from \(orig)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                Text((change.path as NSString).deletingLastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 12)
            if review.diffDirty {
                Text("Edited").foregroundStyle(.secondary)
                Button("Revert") { review.revertDiffEdits() }
                Button("Save") { review.diffSave?() }.keyboardShortcut("s", modifiers: .command)
            } else if let staging = doc.staging {
                let total = staging.hunks.count
                let staged = staging.hunks.filter { staging.state(of: $0) == .staged }.count
                Text(total == 0 ? "No changes" : "\(staged) of \(total) change\(total == 1 ? "" : "s") reviewed")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // The diff's own controls, where WebStorm keeps them: change navigation and layout.
            Button { review.jumpToChange(forward: false) } label: { Image(systemName: "chevron.up") }
                .help("Previous Change (⌥⌘↑)")
            Button { review.jumpToChange(forward: true) } label: { Image(systemName: "chevron.down") }
                .help("Next Change (⌥⌘↓)")
            Picker("Layout", selection: Bindable(review).unified) {
                Image(systemName: "rectangle.split.2x1").accessibilityLabel("Side by Side").help("Side by Side").tag(false)
                Image(systemName: "rectangle.grid.1x2").accessibilityLabel("Unified").help("Unified").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            Menu {
                Button("Open in Editor") { if let url = review.url(for: change.path) { app.showFile(url) } }
                Button(review.folding ? "Show Unchanged Lines" : "Fold Unchanged Lines") { review.folding.toggle() }
                Divider()
                Button("Show in Finder") { if let url = review.url(for: change.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(change.path, forType: .string)
                }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.button).menuIndicator(.hidden).fixedSize()
        }
    }

    private func leaf(_ node: FileTreeNode) -> FileTreeNode {
        node.isFolder ? (node.children.first.map(leaf) ?? node) : node
    }
}

// MARK: Editor

struct EditorScreen: View {
    let app: AppDelegate

    var body: some View {
        let files = app.workspace.files
        VStack(spacing: 0) {
            HeaderBar {
                if let url = files.openURL {
                    Image(nsImage: FileIcons.icon(for: url.lastPathComponent)).resizable().frame(width: 16, height: 16)
                    Text(url.lastPathComponent).fontWeight(.semibold)
                        .foregroundStyle(app.workspace.review.changes.first { $0.path == files.relativePath }.map { AnyShapeStyle($0.kind.color) } ?? AnyShapeStyle(.primary))
                    Text(((files.relativePath ?? "") as NSString).deletingLastPathComponent)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 12)
                if files.changedOnDisk {
                    Text("Changed on disk").foregroundStyle(.orange)
                    Button("Reload") { files.revertToDisk() }
                }
                if files.isDirty {
                    Text("Edited").foregroundStyle(.secondary)
                    Button("Save") { files.saveEditor() }
                }
                if let path = files.relativePath, app.workspace.review.changes.contains(where: { $0.path == path }) {
                    Button("Show Changes") { app.showDiff(path) }
                }
                Menu {
                    if let url = files.openURL {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("Reveal in Project") { app.ui.tool = .project; if let p = files.relativePath { files.expandAncestors(of: p) } }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(files.relativePath ?? url.path, forType: .string)
                        }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).menuIndicator(.hidden).fixedSize()
            }
            if let message = files.message {
                Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CodeEditorRepresentable(model: files, version: files.docVersion, jump: files.jumpSerial, navigator: { kind, url, text, line, character in
                    app.workspace.navigate(kind, url: url, text: text, line: line, character: character)
                }, hover: { url, text, line, character in
                    app.workspace.hover(url: url, text: text, line: line, character: character)
                }, readingAids: { view, url in
                    app.workspace.loadReadingAids(editor: view, url: url)
                })
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: Shared

/// A file header in standard material across the top of the content.
struct HeaderBar<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 8) { content }
            .font(.callout)
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Color(nsColor: DiffTheme.header))
            .overlay(alignment: .bottom) { Divider() }
    }
}

/// Problems from git or saving, for 10 seconds (or until clicked).
private struct Banner: View {
    let app: AppDelegate
    var body: some View {
        let review = app.workspace.review, files = app.workspace.files
        if let message = review.error ?? files.error {
            Text(message)
                .font(.callout)
                .lineLimit(3)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular.tint(.red.opacity(0.25)), in: .rect(cornerRadius: 12))
                .padding(.top, 44)
                .onTapGesture { review.dismissError() }
                .help("Click to dismiss")
        }
    }
}

/// Transient status: "Finding definition…", "Draft is in Claude's message box".
private struct Toast: View {
    let app: AppDelegate
    var body: some View {
        let ws = app.workspace
        Group {
            if let busy = ws.navBusy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy) }
            } else if let toast = ws.link.toast {
                Text(toast)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 18)
        .opacity(ws.navBusy == nil && ws.link.toast == nil ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: ws.navBusy == nil && ws.link.toast == nil)
    }
}

/// Run's output, in a pane under the content.
struct OutputPane: View {
    let app: AppDelegate
    var body: some View {
        let run = app.workspace.run
        VStack(spacing: 0) {
            HeaderBar {
                Circle().fill(run.isRunning ? Color.green : (run.crashed ? Color.red : Color.secondary)).frame(width: 7, height: 7)
                Text(run.selected?.name ?? "Output")
                Spacer()
                Button("Clear") { run.clearOutput() }
                Button { run.outputVisible = false } label: { Image(systemName: "xmark") }.help("Hide Output (⇧⌘Y)")
            }
            OutputText(text: run.output, version: run.outputVersion, epoch: run.outputEpoch)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The browser in the main area, with its address bar on top.
struct BrowserScreen: View {
    let app: AppDelegate
    @FocusState private var editing: Bool

    var body: some View {
        let browser = app.workspace.browser
        VStack(spacing: 0) {
            HeaderBar {
                Button { browser.back() } label: { Image(systemName: "chevron.left") }.disabled(!browser.canGoBack).help("Back")
                Button { browser.forward() } label: { Image(systemName: "chevron.right") }.disabled(!browser.canGoForward).help("Forward")
                Button { browser.reload() } label: { Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise") }.help(browser.isLoading ? "Stop Loading" : "Reload")
                TextField("Address, e.g. localhost:4200", text: Bindable(browser).address)
                    .textFieldStyle(.roundedBorder)
                    .focused($editing)
                    .onSubmit { browser.go(browser.address); editing = false }
            }
            WebViewHost(webView: browser.webView)
        }
    }
}

