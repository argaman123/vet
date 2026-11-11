import AppKit
import JavaScriptCore
import SwiftUI

/// What mods put on screen: a prompt bar at the bottom of the code (one at a time) and panels of
/// native blocks. Vet draws them; mods only describe them.
@MainActor @Observable
final class ModUIState {
    struct Prompt: Equatable {
        let owner: String
        let serial: Int
        var prefix: String
        var text: String
        var placeholder: String
        static func == (a: Prompt, b: Prompt) -> Bool { a.serial == b.serial && a.text == b.text && a.prefix == b.prefix }
    }
    struct Block: Identifiable {
        enum Kind: String { case heading, text, code, row, button, divider }
        let id: Int
        let kind: Kind
        let text: String
        let detail: String
        let action: (@MainActor () -> Void)?
    }
    struct Panel: Identifiable {
        let owner: String
        let key: String
        var title: String
        var blocks: [Block]
        var id: String { owner + "/" + key }
    }

    var prompt: Prompt?
    var panels: [Panel] = []
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var onChange: (@MainActor (String) -> Void)?
    @ObservationIgnored private var onSubmit: (@MainActor (String) -> Void)?
    @ObservationIgnored private var onCancel: (@MainActor (String) -> Void)?

    func showPrompt(owner: String, prefix: String, text: String, placeholder: String,
                    onChange: (@MainActor (String) -> Void)?, onSubmit: (@MainActor (String) -> Void)?, onCancel: (@MainActor (String) -> Void)?) {
        serial += 1
        prompt = Prompt(owner: owner, serial: serial, prefix: prefix, text: text, placeholder: placeholder)
        self.onChange = onChange
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    func closePrompt(owner: String) {
        guard prompt?.owner == owner else { return }
        dismissPrompt()
    }

    func promptChanged(_ text: String) {
        guard prompt != nil, prompt?.text != text else { return }
        prompt?.text = text
        onChange?(text)
    }

    func submitPrompt() {
        guard let p = prompt else { return }
        let submit = onSubmit
        dismissPrompt()
        submit?(p.text)
    }

    func cancelPrompt() {
        guard let p = prompt else { return }
        let cancel = onCancel
        dismissPrompt()
        cancel?(p.text)
    }

    private func dismissPrompt() {
        prompt = nil
        onChange = nil; onSubmit = nil; onCancel = nil
        // Back to the code the prompt was opened from.
        if let pane = ModHost.shared.pane { pane.window?.makeFirstResponder(pane) }
    }

    /// A panel from a mod's description: `{title, blocks: [{type, text, detail, onClick}]}`.
    func showPanel(owner: String, id: String, spec: JSValue, call: @escaping @MainActor (JSValue) -> Void) -> Bool {
        let title = spec.objectForKeyedSubscript("title").toString().flatMap { $0 == "undefined" ? nil : $0 } ?? ""
        let raw = spec.objectForKeyedSubscript("blocks")
        var blocks: [Block] = []
        let count = raw?.isArray == true ? Int(raw!.objectForKeyedSubscript("length").toInt32()) : 0
        for i in 0..<min(count, 400) {
            guard let b = raw?.objectAtIndexedSubscript(i), b.isObject else { continue }
            func str(_ k: String) -> String { let v = b.objectForKeyedSubscript(k); return v?.isString == true ? v!.toString() : "" }
            let kind = Block.Kind(rawValue: str("type")) ?? .text
            let click = JSBox(b.objectForKeyedSubscript("onClick"), call)
            var action: (@MainActor () -> Void)?
            if click.value?.isObject == true { action = { @MainActor in click.run() } }
            blocks.append(Block(id: i, kind: kind, text: str("text"), detail: str("detail"), action: action))
        }
        let panel = Panel(owner: owner, key: id, title: title, blocks: blocks)
        if let i = panels.firstIndex(where: { $0.id == panel.id }) { panels[i] = panel } else { panels.append(panel) }
        return true
    }

    func closePanel(owner: String, id: String) { panels.removeAll { $0.owner == owner && $0.key == id } }

    func removeAll(owner: String) {
        panels.removeAll { $0.owner == owner }
        if prompt?.owner == owner { prompt = nil; onChange = nil; onSubmit = nil; onCancel = nil }
    }
}

/// The prompt bar: a glass capsule at the bottom of the code while a mod asks for a line
/// (a Vim mod's `:` and `/`).
struct ModPromptBar: View {
    let state: ModUIState
    @FocusState private var focused: Bool

    var body: some View {
        if let prompt = state.prompt {
            let text = Binding(get: { state.prompt?.text ?? "" }, set: { state.promptChanged($0) })
            HStack(spacing: 2) {
                Text(prompt.prefix).foregroundStyle(.secondary)
                TextField(prompt.placeholder, text: text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { state.submitPrompt() }
                    .onExitCommand { state.cancelPrompt() }
                    .onKeyPress(.delete) {
                        // Backspace on an empty line closes it, as in Vim.
                        if text.wrappedValue.isEmpty { state.cancelPrompt(); return .handled }
                        return .ignored
                    }
            }
            .font(.system(size: DiffTheme.fontSize, design: .monospaced))
            .padding(.horizontal, 18)
            .frame(width: 460, height: 36)
            .glassPanel(radius: 11)
            .padding(.bottom, 22)
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
            .onAppear { focused = true }
            .onChange(of: prompt.serial) { focused = true }
        }
    }
}

/// Mods' panels: glass cards at the top right of the content, drawn with Vet's own controls.
struct ModPanels: View {
    let state: ModUIState

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(state.panels) { panel in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(panel.title).font(.headline)
                        Spacer()
                        Button { state.closePanel(owner: panel.owner, id: panel.key) } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Close")
                    }
                    ForEach(panel.blocks) { block in blockView(block) }
                }
                .padding(14)
                .frame(width: 300, alignment: .leading)
                .modifier(ModPanelSurface())
            }
        }
        .padding(.top, 56).padding(.trailing, 14)
    }

    @ViewBuilder private func blockView(_ b: ModUIState.Block) -> some View {
        switch b.kind {
        case .heading: Text(b.text).font(.subheadline.weight(.semibold))
        case .text: Text(b.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .code: Text(b.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        case .divider: Divider()
        case .button:
            Button(b.text) { b.action?() }.buttonStyle(.glass)
        case .row:
            Button { b.action?() } label: {
                HStack {
                    Text(b.text).lineLimit(1)
                    Spacer()
                    Text(b.detail).foregroundStyle(.secondary).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(b.action == nil)
        }
    }
}

/// The menu bar's Mods menu: each mod with a checkmark, failures with their error.
struct ModsMenu: Commands {
    let host: ModHost

    var body: some Commands {
        CommandMenu("Mods") {
            let _ = host.revision
            if host.mods.isEmpty {
                Text("No Mods — ask Claude for one")
            }
            ForEach(host.mods, id: \.id) { mod in
                switch mod.status {
                case .failed(let why):
                    Menu("⚠︎ \(mod.name)") {
                        Text(why.split(separator: "\n").first.map(String.init) ?? why)
                        Button("Turn Off") { host.setEnabled(mod.id, false) }
                    }
                default:
                    Toggle(mod.scope == .project ? "\(mod.name) (this project)" : mod.name,
                           isOn: Binding(get: { mod.status == .loaded }, set: { host.setEnabled(mod.id, $0) }))
                }
            }
            Divider()
            Button("Reload Mods") { CommandRegistry.shared.run("app.mods.reload") }
            Button("Open Mods Folder") { CommandRegistry.shared.run("app.mods.openFolder") }
        }
    }
}

/// A mod's function kept for a later click (only ever used on the main thread).
final class JSBox: @unchecked Sendable {
    let value: JSValue?
    private let call: @MainActor (JSValue) -> Void
    init(_ value: JSValue?, _ call: @escaping @MainActor (JSValue) -> Void) { self.value = value; self.call = call }
    @MainActor func run() { if let value { call(value) } }
}

/// A mod's panel: the sidebar's sheet (float), or tinted system glass.
private struct ModPanelSurface: ViewModifier {
    func body(content: Content) -> some View {
        if Design.look == .float { content.glassPanel(radius: 12) }
        else { content.glassEffect(.regular.tint(Color(nsColor: DiffTheme.background).opacity(0.55)), in: .rect(cornerRadius: 16)) }
    }
}
