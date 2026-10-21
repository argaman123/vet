import AppKit

/// A key with modifiers, written the way mods write them: "cmd+shift+k", "ctrl+d", "escape", "G".
struct KeyCombo: Equatable {
    var cmd = false, ctrl = false, alt = false, shift = false
    /// A named key ("escape", "enter", "up"…) or one character, lowercased for letters.
    var key: String

    static let named: [UInt16: String] = [
        53: "escape", 36: "enter", 76: "enter", 48: "tab", 49: "space", 51: "backspace", 117: "delete",
        126: "up", 125: "down", 123: "left", 124: "right", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]
    private static let aliases = ["esc": "escape", "return": "enter", "del": "delete", "bs": "backspace"]

    init?(_ text: String) {
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "cmd++" is cmd and the plus key.
        if text.hasSuffix("++") { parts.removeLast(2); parts.append("+") }
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        for p in parts {
            switch p.lowercased() {
            case "cmd", "command", "meta": cmd = true
            case "ctrl", "control": ctrl = true
            case "alt", "opt", "option": alt = true
            case "shift": shift = true
            default: return nil
            }
        }
        let lower = last.lowercased()
        if let alias = Self.aliases[lower] { key = alias }
        else if Self.named.values.contains(lower) { key = lower }
        else if last.count == 1 {
            // "G" means shift+g.
            if last != lower, last.uppercased() == last { shift = true }
            key = lower
        } else { return nil }
    }

    /// The key an event stands for, by the same rules.
    static func key(of event: NSEvent) -> String {
        if let name = named[event.keyCode] { return name }
        return (event.charactersIgnoringModifiers ?? "").lowercased()
    }

    func matches(_ event: NSEvent) -> Bool {
        let f = event.modifierFlags
        guard f.contains(.command) == cmd, f.contains(.control) == ctrl, f.contains(.option) == alt else { return false }
        let base = Self.key(of: event)
        if base == key && f.contains(.shift) == shift { return true }
        // Punctuation typed with Shift ("?", ":") matches the character itself.
        return !shift && key.count == 1 && event.characters == key
    }

    /// What a mod's key handler gets for an event.
    static func info(_ event: NSEvent, pane: String) -> [String: Any] {
        let f = event.modifierFlags
        let cmd = f.contains(.command), ctrl = f.contains(.control), alt = f.contains(.option), shift = f.contains(.shift)
        let base = key(of: event)
        // `key` is what was typed ("G", ":", "$"), or the named key; with ⌘/⌃ it's the base key.
        let typed = named[event.keyCode] ?? ((cmd || ctrl) ? base : (event.characters ?? base))
        var combo = [String]()
        if cmd { combo.append("cmd") }
        if ctrl { combo.append("ctrl") }
        if alt { combo.append("alt") }
        if shift { combo.append("shift") }
        combo.append(base)
        return ["key": typed, "combo": combo.joined(separator: "+"), "chars": event.characters ?? "",
                "cmd": cmd, "ctrl": ctrl, "alt": alt, "shift": shift, "repeat": event.isARepeat, "pane": pane]
    }
}
