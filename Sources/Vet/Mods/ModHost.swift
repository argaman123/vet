import AppKit
import JavaScriptCore

/// Vet's mods: folders with a `mod.json` (key bindings, themes) and an optional `main.js` run in
/// JavaScriptCore with a `vet` object (ModAPI.swift). Agents install them over MCP (ModTools.swift).
///
/// Mods for every project live in ~/Library/Application Support/Vet/mods/<id> (VET_MODS_DIR in test
/// runs); a project's own in <project>/.vet/mods/<id>, which win over a user mod with the same id.
/// Vet watches both and reloads at once. A broken mod is reported, never fatal: its error shows
/// in the Mods menu and in `list_mods`.
@MainActor @Observable
final class ModHost {
    static let shared = ModHost()

    enum Scope: String, Sendable { case user, project }
    enum Status: Equatable {
        case loaded, disabled
        case failed(String)
    }

    struct Manifest: Codable {
        var id: String
        var name: String?
        var version: String?
        var description: String?
        var main: String?
        var keymap: [KeySpec]?
        var themes: [ThemeSpec]?
    }
    struct KeySpec: Codable {
        var key: String
        var command: String
        var when: String?
        var args: [String]?
    }
    struct ThemeSpec: Codable {
        var id: String
        var name: String?
        var base: String?
        var colors: [String: String]?
    }

    /// A key binding: a key combination that runs a command or a mod's function.
    struct Binding {
        let combo: KeyCombo
        let when: String
        let run: @MainActor () -> Void
    }

    /// One loaded (or failed, or switched off) mod and everything it registered.
    @MainActor final class Mod {
        let id: String
        let folder: URL
        let scope: Scope
        var manifest: Manifest?
        var status: Status = .loaded
        var log: [String] = []
        var errorCount = 0
        var lastError: String?
        var context: JSContext?
        var keyHandlers: [JSValue] = []
        var bindings: [Binding] = []
        var events: [String: [JSValue]] = [:]
        var timers: [Int: DispatchWorkItem] = [:]
        var nextTimer = 1
        /// Set by the exception handler: the last call into the mod threw.
        var threw = false

        init(id: String, folder: URL, scope: Scope) { self.id = id; self.folder = folder; self.scope = scope }

        var name: String { manifest?.name ?? id }

        func record(_ line: String) {
            log.append(line)
            if log.count > 300 { log.removeFirst(log.count - 300) }
        }
    }

    private(set) var mods: [Mod] = []
    /// Bumped whenever a mod's status changes (the Mods menu redraws).
    private(set) var revision = 0
    @ObservationIgnored weak var app: AppDelegate?
    /// The focused code pane, or the last one that had focus.
    @ObservationIgnored weak var pane: CodeTextView?
    /// Panes a mod changed (caret, highlights): reset when mods unload.
    @ObservationIgnored private var touched = NSHashTable<CodeTextView>.weakObjects()
    let ui = ModUIState()
    @ObservationIgnored private var watchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var pendingReload: DispatchWorkItem?
    @ObservationIgnored private var quietUntil = Date.distantPast
    @ObservationIgnored private weak var lastOffered: NSEvent?

    var userFolder: URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["VET_MODS_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        // A test run never touches your mods.
        if let snap = env["VET_SNAPSHOT_DIR"] { return URL(fileURLWithPath: snap, isDirectory: true).appendingPathComponent("mods", isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vet/mods", isDirectory: true)
    }
    var projectFolder: URL? { app?.workspace.root?.appendingPathComponent(".vet/mods", isDirectory: true) }

    func folder(_ scope: Scope) -> URL? { scope == .user ? userFolder : projectFolder }

    var active: [Mod] { mods.filter { $0.status == .loaded } }

    func start(app: AppDelegate) {
        self.app = app
        try? FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        installKeyMonitor()
        reload()
    }

    /// The open project changed: its mods replace the last project's.
    func projectChanged() { reload() }

    // MARK: Loading

    func reload() {
        pendingReload?.cancel()
        unloadAll()
        var found: [Mod] = []
        var ids = Set<String>()
        for scope in [Scope.project, .user] {
            guard let dir = folder(scope), let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let id = url.lastPathComponent
                guard !id.hasPrefix("."), (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true, !ids.contains(id) else { continue }
                ids.insert(id)
                found.append(Mod(id: id, folder: url, scope: scope))
            }
        }
        mods = found
        let disabled = Set(UserDefaults.standard.stringArray(forKey: "disabledMods") ?? [])
        for mod in found {
            if disabled.contains(mod.id) { mod.status = .disabled; continue }
            load(mod)
        }
        Palette.modThemes = found.filter { $0.status == .loaded }.flatMap { m in (m.manifest?.themes ?? []).compactMap { Self.palette($0, mod: m) } }
        DiffTheme.reapplySavedTheme()
        revision += 1
        watch()
    }

    private func load(_ mod: Mod) {
        let manifestURL = mod.folder.appendingPathComponent("mod.json")
        do {
            let data = try Data(contentsOf: manifestURL)
            mod.manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            // JSONSerialization says where bad JSON breaks ("around line 3, column 5").
            let syntax = (try? Data(contentsOf: manifestURL)).flatMap { data -> String? in
                do { _ = try JSONSerialization.jsonObject(with: data); return nil } catch { return (error as NSError).userInfo["NSDebugDescription"] as? String }
            }
            fail(mod, "mod.json: \(syntax ?? Self.describe(error))")
            return
        }
        guard let manifest = mod.manifest else { return }
        if manifest.id != mod.id { mod.record("note: mod.json's id \"\(manifest.id)\" differs from the folder name; the folder name is used") }
        for spec in manifest.keymap ?? [] {
            guard let combo = KeyCombo(spec.key) else { fail(mod, "mod.json: unknown key \"\(spec.key)\""); return }
            let command = spec.command, args = spec.args ?? []
            mod.bindings.append(Binding(combo: combo, when: spec.when ?? "always") {
                if !CommandRegistry.shared.run(command, args) { mod.record("keymap: no command \"\(command)\"") }
            })
        }
        guard let main = manifest.main ?? (FileManager.default.fileExists(atPath: mod.folder.appendingPathComponent("main.js").path) ? "main.js" : nil) else { return }
        let scriptURL = mod.folder.appendingPathComponent(main)
        guard let source = try? String(contentsOf: scriptURL, encoding: .utf8) else { fail(mod, "can't read \(main)"); return }
        guard let context = JSContext(virtualMachine: JSVirtualMachine()) else { fail(mod, "JavaScriptCore didn't start"); return }
        mod.context = context
        context.name = "Vet mod: \(mod.id)"
        context.exceptionHandler = { [weak self, weak mod] _, exception in
            MainActor.assumeIsolated {
                guard let mod else { return }
                let message = Self.describe(exception)
                mod.threw = true
                mod.errorCount += 1
                mod.lastError = message
                mod.record("error: " + message)
                self?.revision += 1
            }
        }
        Watchdog.limit(context, seconds: 1.5)
        ModAPI.install(in: context, mod: mod, host: self)
        mod.threw = false
        context.evaluateScript(source, withSourceURL: scriptURL)
        if mod.threw { fail(mod, mod.lastError ?? "error while loading") }
    }

    private func fail(_ mod: Mod, _ message: String) {
        unload(mod)
        mod.status = .failed(message)
        mod.lastError = message
        mod.record("failed: " + message)
    }

    /// Everything a mod registered goes; the panes get their own caret back.
    private func unload(_ mod: Mod) {
        CommandRegistry.shared.remove(owner: mod.id)
        mod.keyHandlers = []
        mod.bindings = []
        mod.events = [:]
        mod.timers.values.forEach { $0.cancel() }
        mod.timers = [:]
        ui.removeAll(owner: mod.id)
        mod.context?.exceptionHandler = nil
        mod.context = nil
    }

    private func unloadAll() {
        mods.forEach(unload)
        for pane in touched.allObjects {
            pane.caretStyle = .bar
            pane.modMarks = []
        }
        touched.removeAllObjects()
    }

    func touch(_ pane: CodeTextView) { touched.add(pane) }

    // MARK: Watching the folders

    private func watch() {
        watchers.forEach { $0.cancel() }
        watchers = []
        var dirs = [userFolder]
        if let p = projectFolder { dirs.append(p) }
        dirs += mods.map(\.folder)
        // The files themselves too: an in-place write doesn't touch the folder.
        for mod in mods {
            dirs += (try? FileManager.default.contentsOfDirectory(at: mod.folder, includingPropertiesForKeys: nil))?
                .filter { ["json", "js"].contains($0.pathExtension) } ?? []
        }
        for dir in dirs {
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.changed() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    private func changed() {
        guard Date() > quietUntil else { return }
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reload() } }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Managing (the Mods menu and the MCP tools)

    func setEnabled(_ id: String, _ on: Bool) {
        var disabled = Set(UserDefaults.standard.stringArray(forKey: "disabledMods") ?? [])
        if on { disabled.remove(id) } else { disabled.insert(id) }
        UserDefaults.standard.set(disabled.sorted(), forKey: "disabledMods")
        reload()
    }

    /// Writes a mod's files (replacing the folder), loads it, and says how that went.
    func install(id: String, scope: Scope, files: [String: String]) -> (String, Bool) {
        guard id.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else {
            return ("The id must be lowercase letters, digits, '.', '_' or '-' (like \"vim\").", true)
        }
        guard let base = folder(scope) else { return ("No project is open in Vet, so there's no project folder for the mod. Use scope \"user\".", true) }
        guard files["mod.json"] != nil else { return ("files must include mod.json.", true) }
        for path in files.keys where path.hasPrefix("/") || path.split(separator: "/").contains("..") || path.isEmpty {
            return ("Bad file path \"\(path)\": paths are relative to the mod's folder.", true)
        }
        let fm = FileManager.default
        let target = base.appendingPathComponent(id, isDirectory: true)
        let staging = base.appendingPathComponent(".\(id).installing", isDirectory: true)
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            try? fm.removeItem(at: staging)
            for (path, text) in files {
                let url = staging.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: staging, to: target)
        } catch {
            try? fm.removeItem(at: staging)
            return ("Couldn't write the mod: \(error.localizedDescription)", true)
        }
        quietUntil = Date().addingTimeInterval(1)
        reload()
        return report(id, verb: "Installed")
    }

    func remove(id: String, scope: Scope?) -> (String, Bool) {
        let candidates = scope.map { [$0] } ?? [.project, .user]
        for s in candidates {
            guard let url = folder(s)?.appendingPathComponent(id, isDirectory: true), FileManager.default.fileExists(atPath: url.path) else { continue }
            do { try FileManager.default.removeItem(at: url) } catch { return ("Couldn't remove it: \(error.localizedDescription)", true) }
            quietUntil = Date().addingTimeInterval(1)
            reload()
            return ("Removed the \(s.rawValue) mod \"\(id)\".", false)
        }
        return ("There's no mod \"\(id)\".", true)
    }

    /// How a mod is doing, for an agent: loaded or why not, and its latest log lines.
    func report(_ id: String, verb: String) -> (String, Bool) {
        guard let mod = mods.first(where: { $0.id == id }) else { return ("\(verb), but Vet didn't find the mod folder afterwards.", true) }
        let tail = mod.log.suffix(15).joined(separator: "\n")
        switch mod.status {
        case .loaded:
            return ("\(verb) \"\(id)\" (\(mod.scope.rawValue)): loaded and running.\(tail.isEmpty ? "" : "\nLog:\n" + tail)", false)
        case .disabled:
            return ("\(verb) \"\(id)\", but it's switched off in the Mods menu.", false)
        case .failed(let why):
            return ("\(verb) \"\(id)\", but it failed to load: \(why)\(tail.isEmpty ? "" : "\nLog:\n" + tail)", true)
        }
    }

    func summary() -> [[String: Any]] {
        mods.map { m in
            var d: [String: Any] = ["id": m.id, "name": m.name, "scope": m.scope.rawValue, "folder": m.folder.path]
            switch m.status {
            case .loaded: d["status"] = "loaded"
            case .disabled: d["status"] = "disabled"
            case .failed(let why): d["status"] = "failed"; d["error"] = why
            }
            if let v = m.manifest?.version { d["version"] = v }
            if let s = m.manifest?.description { d["description"] = s }
            if m.errorCount > 0 { d["runtimeErrors"] = m.errorCount; d["lastError"] = m.lastError ?? "" }
            return d
        }
    }

    // MARK: Keys

    /// Every key pressed in a code pane: the mods' key handlers first, then their bindings.
    /// True when a mod took it.
    func offer(_ event: NSEvent, to pane: CodeTextView) -> Bool {
        if lastOffered === event { return false } // the app's key monitor already asked
        lastOffered = event
        self.pane = pane
        let mods = active
        guard !mods.isEmpty else { return false }
        let info = KeyCombo.info(event, pane: pane.paneKind)
        for mod in mods {
            for handler in mod.keyHandlers {
                if call(mod, handler, [info])?.toBool() == true { return true }
            }
        }
        return runBinding(event, context: pane.paneKind)
    }

    /// Bindings everywhere else (and modifier keys before the menus see them).
    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let host = self, !host.active.isEmpty else { return event }
            if let pane = event.window?.firstResponder as? CodeTextView {
                return host.offer(event, to: pane) ? nil : event
            }
            let typing = (event.window?.firstResponder as? NSTextView)?.isFieldEditor == true
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            if typing && flags.isEmpty { return event } // a search field or the prompt bar
            return host.runBinding(event, context: "other") ? nil : event
        }
    }

    private func runBinding(_ event: NSEvent, context: String) -> Bool {
        for mod in active {
            for b in mod.bindings where b.combo.matches(event) && Self.applies(b.when, context) {
                b.run()
                return true
            }
        }
        return false
    }

    private static func applies(_ when: String, _ context: String) -> Bool {
        switch when {
        case "always": return true
        case "code": return context != "other"
        case "editor": return context == "editor"
        case "diff": return context == "diff" || context == "diffOld"
        case "notCode": return context == "other"
        default: return false
        }
    }

    // MARK: Calling into mods

    /// Calls a mod's function; nil when it threw (the error is in the mod's log).
    @discardableResult
    func call(_ mod: Mod, _ fn: JSValue, _ args: [Any]) -> JSValue? {
        guard mod.status == .loaded, mod.context != nil else { return nil }
        mod.threw = false
        let result = fn.call(withArguments: args)
        return mod.threw ? nil : result
    }

    /// Tells every mod listening for `event`.
    func emit(_ event: String, _ payload: [String: Any]) {
        for mod in active {
            for fn in mod.events[event] ?? [] { call(mod, fn, [payload]) }
        }
    }

    /// The file on screen, relative to the project.
    var currentFile: String? {
        switch app?.ui.location {
        case .diff(let path)?: return path
        case .file?: return app?.workspace.files.relativePath
        default: return nil
        }
    }

    func paneFocused(_ pane: CodeTextView) {
        guard self.pane !== pane else { return }
        self.pane = pane
        emit("focus", ["pane": pane.paneKind])
    }

    // MARK: Helpers

    private static func palette(_ spec: ThemeSpec, mod: Mod) -> Palette? {
        let base = Palette.available.first { $0.id == (spec.base ?? "ink") } ?? Palette.all[0]
        guard var dict = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(base))) as? [String: Any] else { return nil }
        dict["id"] = spec.id
        dict["name"] = spec.name ?? spec.id
        for (key, value) in spec.colors ?? [:] {
            guard dict[key] is NSNumber, let v = UInt32(value.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), radix: 16) else {
                mod.record("theme \(spec.id): unknown color \"\(key)\" or bad value \"\(value)\"")
                continue
            }
            dict[key] = v
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(Palette.self, from: data)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? DecodingError {
            switch e {
            case .keyNotFound(let key, _): return "missing \"\(key.stringValue)\""
            case .typeMismatch(_, let c), .valueNotFound(_, let c): return "wrong type at \(c.codingPath.map(\.stringValue).joined(separator: "."))"
            case .dataCorrupted(let c): return c.underlyingError.map { ($0 as NSError).localizedDescription } ?? "not valid JSON"
            @unknown default: return "\(e)"
            }
        }
        return error.localizedDescription
    }

    static func describe(_ exception: JSValue?) -> String {
        guard let e = exception else { return "unknown error" }
        var s = e.toString() ?? "error"
        if let line = e.objectForKeyedSubscript("line"), line.isNumber { s += " (line \(line.toInt32()))" }
        if let stack = e.objectForKeyedSubscript("stack"), stack.isString, let st = stack.toString(), !st.isEmpty {
            s += "\n" + st.split(separator: "\n").prefix(4).joined(separator: "\n")
        }
        return s
    }
}

/// Stops a mod's script that runs too long (an endless loop in a key handler would hang Vet).
/// JavaScriptCore's time limit is looked up at run time; without it, there's no limit.
enum Watchdog {
    typealias SetLimit = @convention(c) (OpaquePointer, Double, OpaquePointer?, UnsafeMutableRawPointer?) -> Void
    nonisolated(unsafe) private static let setLimit: SetLimit? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(sym, to: SetLimit.self)
    }()

    static func limit(_ context: JSContext, seconds: Double) {
        guard let setLimit, let group = JSContextGetGroup(context.jsGlobalContextRef) else { return }
        setLimit(group, seconds, nil, nil)
    }
}

// MARK: Test aids (driven by SnapshotHook in test runs)

extension ModHost {
    /// Types keys into the focused code pane as if pressed, in Vim's notation: plain characters,
    /// <esc> <cr> <bs> <tab> <space> <up> <down> <left> <right>, <c-x> for ctrl+x. While a prompt
    /// is open the keys go to it.
    func debugKeys(_ notation: String, pane: CodeTextView) {
        var i = notation.startIndex
        while i < notation.endIndex {
            var token = String(notation[i])
            if notation[i] == "<", let close = notation[i...].firstIndex(of: ">") {
                token = String(notation[i...close])
                i = notation.index(after: close)
            } else {
                i = notation.index(after: i)
            }
            if let prompt = ui.prompt {
                switch token.lowercased() {
                case "<cr>": ui.submitPrompt()
                case "<esc>": ui.cancelPrompt()
                case "<bs>": if prompt.text.isEmpty { ui.cancelPrompt() } else { ui.promptChanged(String(prompt.text.dropLast())) }
                case "<space>": ui.promptChanged(prompt.text + " ")
                default: ui.promptChanged(prompt.text + token)
                }
                continue
            }
            guard let event = Self.event(token, window: pane.window) else { continue }
            if !offer(event, to: pane) { pane.keyDown(with: event) }
            // After each real event AppKit closes the undo groups it opened (one undo step per key);
            // these keys aren't events, so close them the same way.
            let end = NSSelectorFromString("_endTopLevelGroupings")
            if UndoManager.responds(to: end) { _ = (UndoManager.self as AnyObject).perform(end) }
        }
    }

    private static func event(_ token: String, window: NSWindow?) -> NSEvent? {
        let named: [String: (UInt16, String)] = [
            "<esc>": (53, "\u{1b}"), "<cr>": (36, "\r"), "<bs>": (51, "\u{7f}"), "<tab>": (48, "\t"), "<space>": (49, " "),
            "<up>": (126, String(UnicodeScalar(NSUpArrowFunctionKey)!)), "<down>": (125, String(UnicodeScalar(NSDownArrowFunctionKey)!)),
            "<left>": (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!)), "<right>": (124, String(UnicodeScalar(NSRightArrowFunctionKey)!)),
        ]
        var flags: NSEvent.ModifierFlags = []
        var code: UInt16 = 0
        var chars = token, base = token
        if let n = named[token.lowercased()] {
            code = n.0; chars = n.1; base = n.1
        } else if token.lowercased().hasPrefix("<c-"), token.count == 5 {
            flags.insert(.control)
            base = String(token.dropFirst(3).prefix(1)).lowercased()
            chars = String(UnicodeScalar((base.unicodeScalars.first!.value & 0x1f))!)
        } else if token.count == 1, token != token.lowercased() || "~!@#$%^&*()_+{}|:\"<>?".contains(token) {
            flags.insert(.shift)
            base = token.lowercased()
        }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars,
                                charactersIgnoringModifiers: base, isARepeat: false, keyCode: code)
    }
}
