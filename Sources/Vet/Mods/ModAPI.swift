import AppKit
import JavaScriptCore

/// The `vet` object a mod's script sees. Documented for agents in ModDocs.swift (keep them in step).
/// Lines and columns count from 0 (UTF-16 columns, as in the language server protocol); a position
/// is `{line, ch}` or an offset into the pane's text.
@MainActor
enum ModAPI {
    static func install(in ctx: JSContext, mod: ModHost.Mod, host: ModHost) {
        /// A JS function backed by Swift; it gets the call's arguments.
        func fn(_ body: @escaping ([JSValue]) -> Any?) -> Any {
            let block: @convention(block) () -> Any? = {
                let args = (JSContext.currentArguments() as? [JSValue]) ?? []
                return body(args)
            }
            return block
        }
        func object(_ members: [String: Any]) -> JSValue {
            let o = JSValue(newObjectIn: ctx)!
            for (k, v) in members { o.setObject(v, forKeyedSubscript: k as NSString) }
            return o
        }
        func text(_ args: [JSValue]) -> String { args.map { $0.isString ? $0.toString() : (json($0) ?? $0.toString()) }.joined(separator: " ") }
        func log(_ prefix: String) -> Any { fn { args in mod.record(prefix + text(args)); return nil } }

        // vet.log, console.*
        ctx.setObject(object(["log": log(""), "info": log(""), "warn": log("warn: "), "error": log("error: ")]), forKeyedSubscript: "console" as NSString)

        // setTimeout / clearTimeout (cancelled when the mod unloads)
        ctx.setObject(fn { args in
            guard let f = args.first, !f.isUndefined else { return nil }
            let id = mod.nextTimer
            mod.nextTimer += 1
            let work = DispatchWorkItem { [weak mod] in
                MainActor.assumeIsolated {
                    guard let mod else { return }
                    mod.timers[id] = nil
                    host.call(mod, f, [])
                }
            }
            mod.timers[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, (args.count > 1 ? args[1].toDouble() : 0)) / 1000, execute: work)
            return id
        }, forKeyedSubscript: "setTimeout" as NSString)
        ctx.setObject(fn { args in
            if let id = args.first.map({ Int($0.toInt32()) }) { mod.timers.removeValue(forKey: id)?.cancel() }
            return nil
        }, forKeyedSubscript: "clearTimeout" as NSString)

        let commands = object([
            "list": fn { _ in CommandRegistry.shared.commands.map { ["id": $0.id, "title": $0.title] } },
            "run": fn { args in
                guard let id = args.first?.toString() else { return false }
                return CommandRegistry.shared.run(id, args.dropFirst().compactMap { $0.toObject() })
            },
            "register": fn { args in
                guard args.count >= 3, var id = args[0].toString(), let title = args[1].toString() else { return false }
                if !id.contains(".") { id = mod.id + "." + id }
                let f = args[2]
                CommandRegistry.shared.register(id, title, owner: mod.id) { [weak mod] callArgs in
                    if let mod { host.call(mod, f, callArgs) }
                }
                return id
            },
        ])

        let keys = object([
            "onKey": fn { args in
                if let f = args.first, f.isObject { mod.keyHandlers.append(f) }
                return nil
            },
            "bind": fn { args in
                guard args.count >= 2, let spec = args[0].toString(), let combo = KeyCombo(spec) else {
                    mod.record("keys.bind: unknown key \(args.first?.toString() ?? "")")
                    return false
                }
                let when = args.count > 2 && args[2].isString ? args[2].toString()! : "always"
                let target = args[1]
                if target.isString, let id = target.toString() {
                    mod.bindings.append(.init(combo: combo, when: when) { CommandRegistry.shared.run(id) })
                } else {
                    mod.bindings.append(.init(combo: combo, when: when) { [weak mod] in if let mod { host.call(mod, target, []) } })
                }
                return true
            },
        ])

        let ui = object([
            "prompt": fn { args in
                let o = args.first
                func cb(_ name: String) -> (@MainActor (String) -> Void)? {
                    guard let f = o?.objectForKeyedSubscript(name), f.isObject else { return nil }
                    nonisolated(unsafe) let callback = f
                    return { [weak mod] s in if let mod { host.call(mod, callback, [s]) } }
                }
                host.ui.showPrompt(owner: mod.id, prefix: o?.objectForKeyedSubscript("prefix").toString().nonUndefined ?? "",
                                   text: o?.objectForKeyedSubscript("text").toString().nonUndefined ?? "",
                                   placeholder: o?.objectForKeyedSubscript("placeholder").toString().nonUndefined ?? "",
                                   onChange: cb("onChange"), onSubmit: cb("onSubmit"), onCancel: cb("onCancel"))
                return nil
            },
            "closePrompt": fn { _ in host.ui.closePrompt(owner: mod.id); return nil },
            "toast": fn { args in host.app?.workspace.link.flash(text(args)); return nil },
            "panel": fn { args in
                guard args.count >= 2, let id = args[0].toString() else { return false }
                return host.ui.showPanel(owner: mod.id, id: id, spec: args[1]) { [weak mod] f in if let mod { host.call(mod, f, []) } }
            },
            "closePanel": fn { args in host.ui.closePanel(owner: mod.id, id: args.first?.toString() ?? ""); return nil },
        ])

        let editor = editorAPI(mod: mod, host: host, fn: fn, object: object)

        let vet = object([
            "version": "1",
            "modId": mod.id,
            "log": log(""),
            "commands": commands,
            "keys": keys,
            "editor": editor,
            "ui": ui,
            "on": fn { args in
                guard args.count >= 2, let name = args[0].toString() else { return nil }
                mod.events[name, default: []].append(args[1])
                return nil
            },
            "clipboard": object([
                "read": fn { _ in NSPasteboard.general.string(forType: .string) ?? "" },
                "write": fn { args in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(args.first?.toString() ?? "", forType: .string)
                    return nil
                },
            ]),
            "storage": object([
                "get": fn { args in
                    let all = UserDefaults.standard.dictionary(forKey: "modStorage." + mod.id) as? [String: String] ?? [:]
                    guard let key = args.first?.toString(), let s = all[key] else { return nil }
                    return ctx.objectForKeyedSubscript("JSON").invokeMethod("parse", withArguments: [s])
                },
                "set": fn { args in
                    guard args.count >= 2, let key = args[0].toString() else { return nil }
                    var all = UserDefaults.standard.dictionary(forKey: "modStorage." + mod.id) as? [String: String] ?? [:]
                    all[key] = json(args[1])
                    UserDefaults.standard.set(all, forKey: "modStorage." + mod.id)
                    return nil
                },
            ]),
            "project": fn { _ in host.app?.workspace.root?.path },
            "file": fn { _ in host.currentFile },
        ])
        ctx.setObject(vet, forKeyedSubscript: "vet" as NSString)
    }

    private static func json(_ v: JSValue) -> String? {
        guard let ctx = v.context, let s = ctx.objectForKeyedSubscript("JSON").invokeMethod("stringify", withArguments: [v]), s.isString else { return nil }
        return s.toString()
    }

    // MARK: vet.editor

    private static func editorAPI(mod: ModHost.Mod, host: ModHost, fn: (@escaping ([JSValue]) -> Any?) -> Any, object: ([String: Any]) -> JSValue) -> JSValue {
        /// The pane, or nil when no code pane has been focused (every call then answers null/false).
        func pane() -> CodeTextView? { host.pane.flatMap { $0.window == nil ? nil : $0 } }
        func ns(_ p: CodeTextView) -> NSString { p.string as NSString }
        func pos(_ p: CodeTextView, _ offset: Int) -> [String: Any] {
            let s = ns(p)
            let o = min(max(0, offset), s.length)
            let lineStart = s.lineRange(for: NSRange(location: o, length: 0)).location
            let line = p.displayLines(of: NSRange(location: o, length: 0)).lowerBound
            return ["line": line, "ch": o - lineStart, "offset": o]
        }
        /// An offset from a number or {line, ch} (clamped to the line's end).
        func offset(_ p: CodeTextView, _ v: JSValue?) -> Int? {
            guard let v, !v.isUndefined, !v.isNull else { return nil }
            if v.isNumber { return min(max(0, Int(v.toInt32())), ns(p).length) }
            guard v.isObject else { return nil }
            if let o = v.objectForKeyedSubscript("offset"), o.isNumber { return min(max(0, Int(o.toInt32())), ns(p).length) }
            let line = Int(v.objectForKeyedSubscript("line").toInt32()), ch = Int(v.objectForKeyedSubscript("ch").toInt32())
            guard let start = lineStart(p, max(0, line)) else { return ns(p).length }
            let s = ns(p)
            let end = s.lineRange(for: NSRange(location: start, length: 0))
            let contentEnd = NSMaxRange(end) - (NSMaxRange(end) > start && s.character(at: NSMaxRange(end) - 1) == 10 ? 1 : 0)
            return min(start + max(0, ch), contentEnd)
        }
        func lineStart(_ p: CodeTextView, _ line: Int) -> Int? { p.range(line: line, character: 0)?.location }
        func lines(_ p: CodeTextView) -> Int { p.string.reduce(into: 1) { if $1 == "\n" { $0 += 1 } } }
        func lineText(_ p: CodeTextView, _ line: Int) -> String? {
            guard let start = lineStart(p, line) else { return nil }
            let s = ns(p)
            var r = s.lineRange(for: NSRange(location: start, length: 0))
            if r.length > 0, NSMaxRange(r) <= s.length, s.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
            return s.substring(with: r)
        }
        /// An edit through the text view's own path for changes made in code: its guards (the
        /// diff's fold and note rows), its undo (one step per edit, not merged like typing) and its
        /// delegate (dirty state, highlighting).
        func replace(_ p: CodeTextView, _ range: NSRange, _ text: String) -> Bool {
            guard p.isEditable, NSMaxRange(range) <= ns(p).length, let storage = p.textStorage else { return false }
            p.breakUndoCoalescing()
            guard p.shouldChangeText(in: range, replacementString: text) else { return false }
            storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: p.typingAttributes))
            p.didChangeText()
            p.setSelectedRange(NSRange(location: range.location + text.utf16.count, length: 0))
            host.touch(p)
            return true
        }

        return object([
            "available": fn { _ in pane() != nil },
            "kind": fn { _ in pane()?.paneKind },
            "editable": fn { _ in pane()?.isEditable ?? false },
            "text": fn { _ in pane()?.string },
            "lineCount": fn { _ in pane().map(lines) ?? 0 },
            "line": fn { args in
                guard let p = pane(), let n = args.first, n.isNumber else { return nil }
                return lineText(p, Int(n.toInt32()))
            },
            "cursor": fn { _ in
                guard let p = pane() else { return nil }
                let r = p.selectedRange()
                return pos(p, r.location)
            },
            "setCursor": fn { args in
                guard let p = pane() else { return false }
                let o: Int?
                if args.count >= 2, args[0].isNumber, args[1].isNumber {
                    o = offset(p, JSValue(object: ["line": args[0].toInt32(), "ch": args[1].toInt32()], in: args[0].context))
                } else { o = offset(p, args.first) }
                guard let o else { return false }
                p.setSelectedRange(NSRange(location: o, length: 0))
                p.scrollRangeToVisible(NSRange(location: o, length: 0))
                return true
            },
            "selection": fn { _ in
                guard let p = pane() else { return nil }
                let r = p.selectedRange()
                return ["start": pos(p, r.location), "end": pos(p, NSMaxRange(r)), "text": ns(p).substring(with: r)]
            },
            "select": fn { args in
                guard let p = pane(), let a = offset(p, args.first), let b = offset(p, args.count > 1 ? args[1] : nil) else { return false }
                let r = NSRange(location: min(a, b), length: abs(b - a))
                p.setSelectedRange(r)
                p.scrollRangeToVisible(NSRange(location: b, length: 0))
                return true
            },
            "offsetOf": fn { args in pane().flatMap { p in offset(p, args.first) } },
            "positionOf": fn { args in
                guard let p = pane(), let n = args.first, n.isNumber else { return nil }
                return pos(p, Int(n.toInt32()))
            },
            "insert": fn { args in
                guard let p = pane() else { return false }
                return replace(p, p.selectedRange(), args.first?.toString() ?? "")
            },
            "replace": fn { args in
                guard let p = pane(), args.count >= 3, let a = offset(p, args[0]), let b = offset(p, args[1]) else { return false }
                return replace(p, NSRange(location: min(a, b), length: abs(b - a)), args[2].toString() ?? "")
            },
            "group": fn { args in
                // One undo step for everything the function changes.
                guard let p = pane(), let f = args.first else { return nil }
                p.breakUndoCoalescing()
                p.undoManager?.beginUndoGrouping()
                defer { p.undoManager?.endUndoGrouping() }
                return host.call(mod, f, [])
            },
            "perform": fn { args in CommandRegistry.performText(args.first?.toString() ?? "") },
            "undo": fn { _ in
                guard let p = pane(), p.isEditable, p.undoManager?.canUndo == true else { return false }
                p.undoManager?.undo()
                return true
            },
            "redo": fn { _ in
                guard let p = pane(), p.isEditable, p.undoManager?.canRedo == true else { return false }
                p.undoManager?.redo()
                return true
            },
            "find": fn { args in
                guard let p = pane(), let query = args.first?.toString(), !query.isEmpty else { return nil }
                let o = args.count > 1 && args[1].isObject ? args[1] : nil
                let backward = o?.objectForKeyedSubscript("backward").toBool() ?? false
                let regex = o?.objectForKeyedSubscript("regex").toBool() ?? false
                let s = ns(p)
                let from = offset(p, o?.objectForKeyedSubscript("from")) ?? p.selectedRange().location
                // Smart case: lowercase queries ignore case.
                var options: NSString.CompareOptions = query == query.lowercased() ? [.caseInsensitive] : []
                if regex { options.insert(.regularExpression) }
                if backward { options.insert(.backwards) }
                func search(_ range: NSRange) -> NSRange { s.range(of: query, options: options, range: range) }
                var hit = backward ? search(NSRange(location: 0, length: from)) : search(NSRange(location: min(from + 1, s.length), length: s.length - min(from + 1, s.length)))
                if hit.location == NSNotFound { hit = search(NSRange(location: 0, length: s.length)) } // wrap around
                guard hit.location != NSNotFound else { return nil }
                return ["start": pos(p, hit.location), "end": pos(p, NSMaxRange(hit)), "text": s.substring(with: hit)]
            },
            "findAll": fn { args in
                guard let p = pane(), let query = args.first?.toString(), !query.isEmpty else { return [] }
                let s = ns(p)
                let options: NSString.CompareOptions = query == query.lowercased() ? [.caseInsensitive] : []
                var out: [[String: Any]] = [], at = 0
                while at < s.length, out.count < 5000 {
                    let r = s.range(of: query, options: options, range: NSRange(location: at, length: s.length - at))
                    guard r.location != NSNotFound else { break }
                    out.append(["start": r.location, "end": NSMaxRange(r)])
                    at = NSMaxRange(r)
                }
                return out
            },
            "scrollTo": fn { args in
                guard let p = pane(), let o = offset(p, args.first) else { return false }
                p.scrollRangeToVisible(NSRange(location: o, length: 0))
                return true
            },
            "visibleLines": fn { _ in
                guard let p = pane(), let clip = p.enclosingScrollView?.contentView.bounds else { return nil }
                let first = max(0, p.line(at: NSPoint(x: 0, y: clip.minY + (p.enclosingScrollView?.contentInsets.top ?? 0))))
                return ["first": first, "last": max(first, min(lines(p) - 1, p.line(at: NSPoint(x: 0, y: clip.maxY))))]
            },
            "caret": fn { args in
                guard let p = pane() else { return false }
                guard let style = CaretStyle(rawValue: args.first?.toString() ?? "") else { return false }
                p.caretStyle = style
                host.touch(p)
                return true
            },
            "highlight": fn { args in
                // highlight([{start, end}…]) marks ranges like search matches; highlight([]) clears.
                guard let p = pane() else { return false }
                let list = args.first?.toArray() ?? []
                p.modMarks = list.prefix(5000).compactMap { item in
                    guard let d = item as? [String: Any], let a = (d["start"] as? NSNumber)?.intValue, let b = (d["end"] as? NSNumber)?.intValue,
                          a >= 0, b >= a, b <= ns(p).length else { return nil }
                    return NSRange(location: a, length: b - a)
                }
                host.touch(p)
                return true
            },
            "focus": fn { _ in
                guard let p = pane() else { return false }
                p.window?.makeFirstResponder(p)
                return true
            },
            "save": fn { _ in CommandRegistry.shared.run("app.save") },
        ])
    }
}

private extension String {
    /// JSValue.toString() of undefined is "undefined".
    var nonUndefined: String? { self == "undefined" || self == "null" ? nil : self }
}
