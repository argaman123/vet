import AppKit
import VetCore

/// Colors and metrics of the app and its code panes, from the chosen theme (CodeThemes.swift).
@MainActor
enum DiffTheme {
    nonisolated static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
    }
    /// A color with a light and a dark variant. Vet is always dark (VetApp sets it), so the dark one
    /// is used as is: a provider would be asked again on every draw, which scrolling feels.
    nonisolated static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        if alwaysDark { return dark }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
                .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false ? dark : light
        }
    }

    nonisolated(unsafe) static var alwaysDark = true

    // MARK: Theme (Settings ▸ Theme; see CodeThemes.swift)

    nonisolated(unsafe) private static var current: Palette = Palette.all.first { $0.id == UserDefaults.standard.string(forKey: "theme") } ?? .tide
    static var palette: Palette { current }
    static func setTheme(_ id: String) {
        guard let p = Palette.available.first(where: { $0.id == id }), p.id != current.id else { return }
        current = p
        UserDefaults.standard.set(id, forKey: "theme")
        resolved = [:]
        NotificationCenter.default.post(name: .vetThemeChanged, object: nil)
    }
    /// After mods load: their theme, if it's the one you chose; off a mod theme whose mod is gone.
    static func reapplySavedTheme() {
        let saved = UserDefaults.standard.string(forKey: "theme") ?? "tide"
        if let p = Palette.available.first(where: { $0.id == saved }) {
            if p.id == current.id { current = p; resolved = [:]; NotificationCenter.default.post(name: .vetThemeChanged, object: nil) } // its colors may have changed
            else { setTheme(saved) }
        } else if !Palette.all.contains(where: { $0.id == current.id }) {
            current = .tide
            resolved = [:]
            NotificationCenter.default.post(name: .vetThemeChanged, object: nil)
        }
    }
    nonisolated(unsafe) private static var resolved: [String: NSColor] = [:]
    /// A palette color as a light/dark color (cached until the theme changes).
    nonisolated private static func color(_ key: String, _ value: (Palette) -> UInt32) -> NSColor {
        if let c = resolved[key] { return c }
        let c = dynamic(light: hex(value(.light)), dark: hex(value(current)))
        resolved[key] = c
        return c
    }

    static var window: NSColor { color("window") { $0.window } }
    static var accent: NSColor { current.systemAccent ? .controlAccentColor : color("accent") { $0.accent } }
    static var folder: NSColor { color("folder") { $0.folder } }
    static var sidebar: NSColor { color("sidebar") { $0.sidebar } }
    static var header: NSColor { veil(color("header") { $0.header }, 0.55) }
    static var background: NSColor { veil(color("background") { $0.background }, 0.8) }
    /// Frosted: a surface becomes a veil over the desktop (its alpha), else stays solid.
    static func veil(_ c: NSColor, _ alpha: CGFloat) -> NSColor { Design.frosted ? c.withAlphaComponent(alpha) : c }
    static var gutter: NSColor { background }
    static var foldLabel: NSColor { color("foldLabel") { $0.foldLabel } }
    static var foldPill: NSColor { color("foldPill") { $0.foldPill } }
    static var foldPillHover: NSColor { color("foldPillHover") { $0.foldPillHover } }
    static var foldPillBorder: NSColor { color("foldPillBorder") { $0.foldPillBorder } }
    static var foldWave: NSColor { color("foldWave") { $0.foldWave } }
    static var foldBand: NSColor { foldPill }
    /// A change you've reviewed and folded away: a quiet green, so it reads apart from unchanged lines.
    static var reviewedBand: NSColor { solid(added, 0.09) }
    static var reviewedPill: NSColor { solid(added, 0.18) }
    static var text: NSColor { color("text") { $0.text } }
    static var lineNumber: NSColor { color("lineNumber") { $0.lineNumber } }
    static var lineNumberCurrent: NSColor { color("lineNumberCurrent") { $0.lineNumberCurrent } }
    static let border = NSColor.separatorColor
    static var selection: NSColor { color("selection") { $0.selection } }
    static var inlayBackground: NSColor { color("inlayBackground") { $0.inlayBackground } }
    static var inlayText: NSColor { color("inlayText") { $0.inlayText } }
    static var lensText: NSColor { color("lensText") { $0.lensText } }
    static var searchMatch: NSColor { color("searchMatch") { $0.searchMatch } }

    /// Change markers (gutter bars, the thin line where the other side has nothing).
    static var added: NSColor { color("addedMark") { $0.addedMark } }
    static var modified: NSColor { color("modifiedMark") { $0.modifiedMark } }
    static var removed: NSColor { dynamic(light: hex(0x9A9DA6), dark: hex(0x7C808A)) } // grey, as deleted files

    /// Diff blocks: inserted green, modified blue, deleted red.
    enum Change { case inserted, modified, deleted }
    static func block(_ change: Change) -> NSColor {
        // Monolith: the blocks are quiet greys; color is left to the changed words and the code.
        if Design.direction == .monolith {
            switch change {
            case .inserted: return hex(0x1B231D)
            case .modified: return hex(0x1E2128)
            case .deleted: return hex(0x261C1E)
            }
        }
        switch change {
        case .inserted: return veil(color("inserted") { $0.inserted }, 0.85)
        case .modified: return veil(color("modified") { $0.modified }, 0.85)
        case .deleted: return veil(dynamic(light: hex(0xE2E3E6), dark: hex(0x2B2C30)), 0.85) // removed: grey, as in the file list
        }
    }
    static func change(head: Range<Int>, work: Range<Int>) -> Change {
        head.isEmpty ? .inserted : work.isEmpty ? .deleted : .modified
    }
    /// Unified layout: HEAD lines red, new lines green, so the two read apart in one column.
    static var unifiedRemoved: NSColor { block(.deleted) }
    static var unifiedAdded: NSColor { block(.inserted) }
    static var unifiedRemovedWord: NSColor { dynamic(light: hex(0xC9CBD1), dark: hex(0x44464C)) }
    static var unifiedAddedWord: NSColor { color("insertedWord") { $0.insertedWord } }

    // Code text size: pinch a code pane, or ⌘+ / ⌘− / ⌘0. Rows are 1.5× the font size.
    static let defaultFontSize: CGFloat = 12
    static var fontSize: CGFloat {
        let v = UserDefaults.standard.double(forKey: "codeFontSize")
        return v == 0 ? defaultFontSize : CGFloat(v)
    }
    static func setFontSize(_ size: CGFloat) {
        let clamped = min(28, max(9, size.rounded()))
        guard clamped != fontSize else { return }
        UserDefaults.standard.set(Double(clamped), forKey: "codeFontSize")
        cached = nil
        NotificationCenter.default.post(name: .vetCodeFontChanged, object: nil)
    }
    private static var cached: (size: CGFloat, font: NSFont, number: NSFont, line: CGFloat)?
    static var codeFont: CodeFont { CodeFont(rawValue: UserDefaults.standard.string(forKey: "codeFont") ?? "") ?? .sfMono }
    static func setCodeFont(_ f: CodeFont) {
        guard f != codeFont else { return }
        UserDefaults.standard.set(f.rawValue, forKey: "codeFont")
        cached = nil
        NotificationCenter.default.post(name: .vetCodeFontChanged, object: nil)
    }
    private static var metrics: (size: CGFloat, font: NSFont, number: NSFont, line: CGFloat) {
        // Read on every line drawn: the size is looked up again only when it was changed here.
        if let c = cached { return c }
        let s = fontSize
        let m = (s, codeFont.font(size: s),
                 NSFont.monospacedDigitSystemFont(ofSize: max(9, s - 1.5), weight: .regular), (s * 1.5).rounded())
        cached = m
        return m
    }
    static var font: NSFont { metrics.font }
    static var numberFont: NSFont { metrics.number }
    static var lineHeight: CGFloat { metrics.line }
    static let inset = NSSize(width: 10, height: 6)

    static func token(_ kind: TokenKind) -> NSColor {
        switch kind {
        case .keyword: color("keyword") { $0.keyword }
        case .string: color("string") { $0.string }
        case .comment: color("comment") { $0.comment }
        case .number: color("number") { $0.number }
        case .type: color("type") { $0.type }
        case .decorator: color("decorator") { $0.decorator }
        case .tag: color("tag") { $0.tag }
        case .attribute: color("attribute") { $0.attribute }
        }
    }

    /// Semantic token colors (from the language server).
    static func semantic(_ type: String, modifiers: Set<String>) -> NSColor? {
        switch type {
        case "function", "method", "member": return color("function") { $0.function } // TypeScript calls methods "member"
        case "property": return color("property") { $0.property }
        case "enumMember": return color("constant") { $0.constant }
        case "parameter": return color("parameter") { $0.parameter }
        case "class", "interface", "enum", "type", "typeParameter": return color("classType") { $0.classType }
        case "namespace": return color("namespace") { $0.namespace }
        case "variable":
            return modifiers.contains("readonly") && (modifiers.contains("static") || modifiers.contains("defaultLibrary")) ? color("constant") { $0.constant } : nil
        case "decorator": return token(.decorator)
        default: return nil
        }
    }

    /// `color` at `alpha` over the code background, as one opaque color (WebStorm uses one
    /// opaque color for a change's lines and its ribbon, so touching sections don't darken).
    static func solid(_ color: NSColor, _ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var out = NSColor.clear
            appearance.performAsCurrentDrawingAppearance {
                let c = color.usingColorSpace(.sRGB) ?? color, b = background.usingColorSpace(.sRGB) ?? .black
                out = NSColor(srgbRed: b.redComponent + (c.redComponent - b.redComponent) * alpha,
                              green: b.greenComponent + (c.greenComponent - b.greenComponent) * alpha,
                              blue: b.blueComponent + (c.blueComponent - b.blueComponent) * alpha, alpha: b.alphaComponent)
            }
            return out
        }
    }

    /// A section's line color: IntelliJ's block color at full strength; a reviewed section is only
    /// a faint wash of it (it's accepted: it stays readable but stops asking for attention).
    static func fill(_ change: Change, hasWords: Bool, staged: Bool) -> NSColor {
        fill(block(change), hasWords: hasWords, staged: staged)
    }
    static func fill(_ base: NSColor, hasWords: Bool, staged: Bool) -> NSColor {
        staged ? solid(base, 0.16) : base
    }
    /// Changed words inside a modified section: a brighter shade of it, so they stand out.
    static var modifiedWord: NSColor { Design.direction == .monolith ? hex(0x2D4A78) : color("modifiedWord") { $0.modifiedWord } }
    /// Changed words (faded once reviewed).
    static func word(_ base: NSColor, staged: Bool) -> NSColor { staged ? solid(base, 0.22) : base }

    /// The marker color for a section (pure insertions and deletions get a line on the other side).
    static func marker(_ change: Change) -> NSColor {
        switch change {
        case .inserted: added
        case .modified: modified
        case .deleted: removed
        }
    }

    /// File names by change, as IntelliJ colors them in the commit tree and project view.
    nonisolated static func fileStatus(_ kind: ChangeKind) -> NSColor {
        switch kind {
        case .modified, .renamed: color("fileModified") { $0.fileModified }
        case .added, .untracked: color("fileAdded") { $0.fileAdded } // new is new, in git or not
        case .deleted: NSColor.secondaryLabelColor // gone: grey, not alarming
        case .conflicted: color("fileConflict") { $0.fileConflict }
        }
    }

}

extension Notification.Name {
    /// The code text size changed (every code pane re-lays out).
    static let vetCodeFontChanged = Notification.Name("VetCodeFontChanged")
    /// The color theme changed (every view redraws with the new palette).
    static let vetThemeChanged = Notification.Name("VetThemeChanged")
}
