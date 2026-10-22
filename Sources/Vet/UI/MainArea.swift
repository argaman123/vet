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
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 8) {
                            ClaudeBanner(app: app)
                            Toast(app: app)
                        }
                        .animation(.easeOut(duration: 0.25), value: app.workspace.claudeEvent)
                    }
                    .overlay(alignment: .bottom) { ModPromptBar(state: ModHost.shared.ui) }
                    .overlay(alignment: .topTrailing) { ModPanels(state: ModHost.shared.ui) }
                    .animation(.easeOut(duration: 0.18), value: ModHost.shared.ui.prompt?.serial)
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
        let scope = review.scope
        HeaderBar(extra: Design.sticky == .pill && !scope.isEmpty ? AnyView(ScopeRows(rows: scope) { review.scopeJump?($0) }) : nil) {
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
            if Design.sticky == .crumbs { ScopeCrumbs(rows: scope) { review.scopeJump?($0) } }
            if let f = review.plan?.file(change.path) {
                ClaudeNoteButton(file: f, key: ReviewModel.summaryKey(change.path, f.summary, doc.staging?.snapshotID ?? ""), review: review)
            }
            Spacer(minLength: 12)
            if review.diffDirty {
                Text("Edited").foregroundStyle(.secondary)
                Button("Revert") { review.revertDiffEdits() }
                Button("Save") { review.diffSave?() }.keyboardShortcut("s", modifiers: .command)
            } else if let staging = doc.staging {
                let total = staging.hunks.count
                let staged = review.hunkStates.values.filter { $0 == .staged }.count
                Text(total == 0 ? "" : "\(staged)/\(total)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help("\(staged) of \(total) changes reviewed")
            }
            // The way back to the file, as the editor's header offers Show Changes (JetBrains' pencil
            // for Jump to Source).
            Button { if let url = review.url(for: change.path) { app.showFile(url) } } label: { Image(systemName: "pencil") }
                .help("Open in Editor")
                .accessibilityLabel("Open in Editor")
            // The diff's own controls, where WebStorm keeps them: change navigation and layout.
            Button { review.jumpToChange(forward: false) } label: { Image(systemName: "chevron.up") }
                .help("Previous Change (⌘↑)")
            Button { review.jumpToChange(forward: true) } label: { Image(systemName: "chevron.down") }
                .help("Next Change (⌘↓)")
            // Fold or open every unchanged region and reviewed change at once (its icon shows what it does).
            Button { review.setAllCollapsed(!review.allCollapsed) } label: {
                Image(systemName: review.allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
            }
            .help(review.allCollapsed ? "Expand All (⌥⇧⌘→)" : "Collapse All (⌥⇧⌘←)")
            .accessibilityLabel(review.allCollapsed ? "Expand All" : "Collapse All")
            // One button that flips the layout (its icon shows the other one).
            Button { withAnimation(.easeInOut(duration: 0.2)) { review.unified.toggle() } } label: {
                Image(systemName: review.unified ? "rectangle.split.2x1" : "rectangle.grid.1x2")
            }
            .help(review.unified ? "Side by Side" : "Unified")
            .accessibilityLabel(review.unified ? "Side by Side" : "Unified")
            Menu {
                Button(review.folding ? "Show Unchanged Lines" : "Fold Unchanged Lines") { review.folding.toggle() }
                Divider()
                Button("Show in Finder") { if let url = review.url(for: change.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(change.path, forType: .string)
                }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.button).menuIndicator(.hidden).fixedSize().pointerStyle(.link)
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
                    if Design.sticky == .crumbs { ScopeCrumbs(rows: files.scope) { files.editorView.scrollTo(line: $0) } }
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
                .menuStyle(.button).menuIndicator(.hidden).fixedSize().pointerStyle(.link)
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
    /// Rows under the controls, inside the same glass (the pinned declarations, say).
    var extra: AnyView? = nil
    @ViewBuilder let content: Content
    var body: some View {
        if Design.direction == .glass {
            // Glass: the file's controls float in a Liquid Glass bar over the code's edge.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) { content }
                    .frame(height: 34)
                if let extra { extra.padding(.bottom, 7) }
            }
                .font(.callout)
                .buttonStyle(.hand)
                .onContinuousHover { if case .active = $0 { NSCursor.arrow.set() } } // not the code's I-beam
                .padding(.horizontal, 14)
                // A light tint of the code's own color keeps the header readable over passing code.
                .glassEffect(.regular.tint(Color(nsColor: DiffTheme.background).opacity(0.55)), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        } else {
            HStack(spacing: 8) { content }
                .font(.callout)
                .buttonStyle(.hand)
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
        // The address bar sits on the window's own grey, as the headers do over code, and the page
        // starts under it: a web page's colors under glass read as a grey box.
        VStack(spacing: 0) {
            HeaderBar {
                Button { browser.back() } label: { Image(systemName: "chevron.left") }.disabled(!browser.canGoBack).help("Back")
                Button { browser.forward() } label: { Image(systemName: "chevron.right") }.disabled(!browser.canGoForward).help("Forward")
                Button { browser.reload() } label: { Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise") }.help(browser.isLoading ? "Stop Loading" : "Reload")
                // Typed straight onto the glass: no box of its own.
                TextField("Address, e.g. localhost:4200", text: Bindable(browser).address)
                    .textFieldStyle(.plain)
                    .focused($editing)
                    .onSubmit { browser.go(browser.address); editing = false }
            }
            WebViewHost(webView: browser.webView)
                .overlay {
                    // Vet's grey and a word on what happened, not WebKit's blank white page.
                    if browser.loadError != nil || browser.address.isEmpty { BrowserPlaceholder(app: app) }
                }
        }
        .background(Color(nsColor: DiffTheme.background))
    }
}

/// The browser with no page to show: nothing opened yet, or the page couldn't open.
private struct BrowserPlaceholder: View {
    let app: AppDelegate
    var body: some View {
        let browser = app.workspace.browser, run = app.workspace.run
        let host = URL(string: browser.address).map { u in u.host.map { h in u.port.map { "\(h):\($0)" } ?? h } ?? browser.address } ?? browser.address
        VStack(spacing: 6) {
            Text(browser.loadError == nil ? "No Page" : "Can't Open \(host)").font(.headline)
            Text(browser.loadError ?? "Type an address above, or run your app to open it here.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                if let config = run.selected, !run.isRunning {
                    Button("Run ‘\(config.name)’") { run.start(); run.outputVisible = true }
                }
                if browser.loadError != nil { Button("Try Again") { browser.reload() } }
            }
            .buttonStyle(.hand)
            .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: DiffTheme.background))
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
        .buttonStyle(.hand)
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
/// Claude's summary of the file, from the review order: open the first time you see the file,
/// and once you close it, closed for the session until the file (or the summary) changes.
struct ClaudeNoteButton: View {
    let file: ReviewPlan.File
    /// The file, its summary and its contents: a new key opens the summary again.
    let key: String
    let review: ReviewModel
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Image(systemName: "sparkle") }
            .task(id: key) {
                guard !review.closedSummaries.contains(key) else { return }
                try? await Task.sleep(for: .seconds(0.35)) // once the header is in its window
                if !Task.isCancelled { open = true }
            }
            .onChange(of: open) { _, isOpen in
                guard !isOpen else { return }
                review.closedSummaries.insert(key)
                // Then Claude's note on the change you're on, if it has one.
                if review.claudeNoteHere { DispatchQueue.main.async { review.diffView.showClaudeNoteHere() } }
            }
            .foregroundStyle(.secondary)
            .help(file.summary)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(file.summary).fixedSize(horizontal: false, vertical: true)
                    // Notes on a line or a function show beside it in the diff; the rest here.
                    if let notes = file.notes?.filter({ $0.line == nil && $0.symbol == nil }), !notes.isEmpty {
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


/// Where the top of the view is, in the header: the enclosing declarations, each a jump to it.
/// The same in the diff and the editor.
struct ScopeCrumbs: View {
    let rows: [(line: Int, text: NSAttributedString)]
    let jump: (Int) -> Void
    var body: some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            Button(ScopeRows.name(row.text.string)) { jump(row.line) }
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}

/// The pinned declarations as code, inside the header's glass: each one a jump to it.
struct ScopeRows: View {
    let rows: [(line: Int, text: NSAttributedString)]
    let jump: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                CodeLabel(text: row.text)
                    .frame(height: DiffTheme.lineHeight, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { jump(row.line) }
                    .pointerStyle(.link)
            }
        }
    }

    /// A declaration's name from its line: "LightningLayer" for a class, "hover()" for a function.
    static func name(_ line: String) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        if let m = t.firstMatch(of: /(?:class|interface|enum|struct|function|def|fun|object|namespace|type|extension)\s+([A-Za-z_$][\w$]*)/) { return String(m.1) }
        if let m = t.firstMatch(of: /([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*\(/) { return String(m.1) + "()" }
        return String(t.prefix(28))
    }
}

/// A line of colored code (AppKit draws the attributed text exactly as the panes do).
private struct CodeLabel: NSViewRepresentable {
    let text: NSAttributedString
    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(labelWithAttributedString: text)
        f.lineBreakMode = .byTruncatingTail
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }
    func updateNSView(_ f: NSTextField, context: Context) { f.attributedStringValue = text }
}
