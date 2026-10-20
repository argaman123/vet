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
    @State private var top: CGFloat = 0
    @State private var bottom: CGFloat = 0

    var body: some View {
        let review = app.workspace.review
        let glass = Design.direction == .glass
        let header = VStack(spacing: 0) {
            if let doc = review.diff {
                DiffHeader(app: app, doc: doc)
            }
        }
        let diff = RibbonDiffView(model: review, version: review.diffVersion, jumpSerial: review.jump.serial, approveSerial: review.approveSerial,
                                  overlay: NSEdgeInsets(top: glass ? top : 0, left: 0, bottom: glass ? bottom : 0, right: 0))
        if glass {
            // Glass: the header and the actions float over the code, which scrolls under them.
            diff
                // The fades sit in their own layer under the glass, so the glass samples them.
                .overlay(alignment: .top) { EdgeFade(edge: .top, height: top) }
                .overlay(alignment: .top) { header.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { top = $0 } }
                .overlay(alignment: .bottom) { ReviewFooter(app: app, floating: true).onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottom = $0 } }
        } else {
            VStack(spacing: 0) {
                header
                diff
                ReviewFooter(app: app, floating: false)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
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
            let node = FileTreeNode.build([change]).first.map(leaf)
            TriStateCheckbox(state: review.stage(of: change)) { on in
                if let node { review.setStaged(node, on) }
            }
            Image(nsImage: FileIcons.icon(for: change.path)).resizable().frame(width: 16, height: 16)
            ChangeName(name: (change.path as NSString).lastPathComponent, kind: change.kind).fontWeight(.semibold)
            if let orig = change.origPath {
                Text("renamed from \(orig)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                Text((change.path as NSString).deletingLastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            // Claude's note on this file, one click away instead of a second bar.
            if let f = review.plan?.file(change.path) { ClaudeNoteButton(file: f) }
            Spacer(minLength: 12)
            if review.diffDirty {
                Text("Edited").foregroundStyle(.secondary)
                Button("Revert") { review.revertDiffEdits() }
                Button("Save") { review.diffSave?() }.keyboardShortcut("s", modifiers: .command)
            } else if let staging = doc.staging {
                let total = staging.hunks.count
                let staged = staging.hunks.filter { staging.state(of: $0) == .staged }.count
                Text(total == 0 ? "" : "\(staged)/\(total)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help("\(staged) of \(total) changes reviewed")
            }
            // The diff's own controls, where WebStorm keeps them: change navigation and layout.
            Button { review.jumpToChange(forward: false) } label: { Image(systemName: "chevron.up") }
                .help("Previous Change (⌥⌘↑)")
            Button { review.jumpToChange(forward: true) } label: { Image(systemName: "chevron.down") }
                .help("Next Change (⌥⌘↓)")
            // One button that flips the layout (its icon shows the other one).
            Button { withAnimation(.easeInOut(duration: 0.2)) { review.unified.toggle() } } label: {
                Image(systemName: review.unified ? "rectangle.split.2x1" : "rectangle.grid.1x2")
            }
            .help(review.unified ? "Side by Side" : "Unified")
            .accessibilityLabel(review.unified ? "Side by Side" : "Unified")
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
    @State private var top: CGFloat = 0

    var body: some View {
        let glass = Design.direction == .glass
        if glass {
            // Glass: the header floats over the code, which scrolls under it.
            editor(overlayTop: top)
                .overlay(alignment: .top) { EdgeFade(edge: .top, height: top) }
                .overlay(alignment: .top) { header.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { top = $0 } }
        } else {
            VStack(spacing: 0) { header; editor(overlayTop: 0) }
                .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var header: some View {
        let files = app.workspace.files
        return HeaderBar {
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
    }

    @ViewBuilder private func editor(overlayTop: CGFloat) -> some View {
        let files = app.workspace.files
            if let message = files.message {
                Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CodeEditorRepresentable(model: files, version: files.docVersion, jump: files.jumpSerial, navigator: { kind, url, text, line, character in
                    app.workspace.navigate(kind, url: url, text: text, line: line, character: character)
                }, hover: { url, text, line, character in
                    app.workspace.hover(url: url, text: text, line: line, character: character)
                }, readingAids: { view, url in
                    app.workspace.loadReadingAids(editor: view, url: url)
                }, overlayTop: overlayTop)
            }
    }
}

// MARK: Shared

/// Where code passes under floating glass, it fades out first (as Tahoe's scroll edges do), so
/// the glass reads cleanly instead of showing sharp text through it. Reaches up under the top bar.
struct EdgeFade: View {
    let edge: VerticalEdge
    /// The bar's height.
    let height: CGFloat
    var body: some View {
        let bg = Color(nsColor: DiffTheme.background).opacity(1)
        // One smooth gradient, no solid band: the theme's color is itself translucent when frosted,
        // so a solid stretch stacked on the code read as a grey slab.
        LinearGradient(stops: [.init(color: bg, location: 0), .init(color: bg.opacity(0), location: 1)],
                       startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
            .frame(height: height + (edge == .top ? 60 : 26)) // up under the window's top bar; gone by the bar's bottom, where sticky lines start
            .padding(.top, edge == .top ? -60 : 0)
            .allowsHitTesting(false)
    }
}

/// A file header in standard material across the top of the content.
struct HeaderBar<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        if Design.direction == .glass {
            // Glass: the file's controls float in a Liquid Glass bar over the code's edge.
            HStack(spacing: 8) { content }
                .font(.callout)
                .buttonStyle(.borderless)
                .onContinuousHover { if case .active = $0 { NSCursor.arrow.set() } } // not the code's I-beam
                .padding(.horizontal, 14)
                .frame(height: 34)
                // A light tint of the code's own color keeps the header readable over passing code.
                .glassEffect(.regular.tint(Color(nsColor: DiffTheme.background).opacity(0.55)), in: .capsule)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        } else {
            HStack(spacing: 8) { content }
                .font(.callout)
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .frame(height: Design.direction == .studio ? 38 : 32)
                .background(Color(nsColor: Design.direction == .monolith || Design.direction == .studio ? DiffTheme.background : DiffTheme.header))
                .overlay(alignment: .bottom) { Divider().opacity(Design.direction == .studio ? 0.5 : 1) }
        }
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
            if let toast = ws.link.toast {
                Text(toast)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 18)
        .opacity(ws.link.toast == nil ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: ws.link.toast == nil)
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

/// Under the diff: how far the review is, approve-and-next, and Commit (rarely used: Claude
/// usually commits, so it sits here rather than in the toolbar).
struct ReviewFooter: View {
    let app: AppDelegate
    /// Glass: the action in a floating Liquid Glass capsule over the code, instead of a bar.
    var floating = false
    var body: some View {
        let review = app.workspace.review
        // One action under the code. Commit is rarer: the project menu in the title bar, or ⌘K.
        let buttons = HStack(spacing: 14) {
            Button { review.approveAndNext() } label: { Label("Approve and Next", systemImage: "checkmark") }
                .help("Approve the change with the lit line numbers and go to the next (⌘↩)")
        }
        .font(.callout)
        .buttonStyle(.borderless)
        .pointerStyle(.link)
        .onContinuousHover { if case .active = $0 { NSCursor.pointingHand.set() } }
        if floating {
            HStack {
                Spacer()
                buttons
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .glassEffect(.regular.tint(Color(nsColor: DiffTheme.background).opacity(0.55)).interactive(), in: .capsule)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        } else {
            HStack { Spacer(); buttons }
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(Color(nsColor: DiffTheme.background))
                .overlay(alignment: .top) { Divider().opacity(0.6) }
        }
    }
}

/// Claude's summary of the open file (from the review plan), with its notes on key functions.
/// Claude's note on the open file (from the review plan): a sparkle in the file's header that
/// opens the summary and the notes on key functions.
struct ClaudeNoteButton: View {
    let file: ReviewPlan.File
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Image(systemName: "sparkle") }
            .foregroundStyle(.secondary)
            .help(file.summary)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(file.summary).fixedSize(horizontal: false, vertical: true)
                    if let notes = file.notes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        if let sym = n.symbol { Text(sym).font(.system(.callout, design: .monospaced)).foregroundStyle(Color(nsColor: DiffTheme.semantic("function", modifiers: []) ?? .labelColor)) }
                                        if let l = n.line { Text("line \(l + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }
                                    }
                                    Text(n.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .font(.callout)
                .padding(14)
                .frame(width: 360, alignment: .leading)
            }
    }
}

