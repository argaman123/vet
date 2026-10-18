import AppKit
import VetCore

/// Colors and metrics of code panes. Surfaces are the system's own (they follow light/dark,
/// increased contrast and the accent color); code colors are WebStorm's light and dark schemes.
@MainActor
enum DiffTheme {
    nonisolated static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
    }
    /// A color with a light and a dark variant.
    nonisolated static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
                .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false ? dark : light
        }
    }

    // IntelliJ's own colors: the Islands Dark scheme (WebStorm's default, and the user's) with the
    // Darcula diff colors it inherits; IntelliJ Light for light mode.
    static let background = dynamic(light: hex(0xFFFFFF), dark: hex(0x191A1C))
    static let gutter = background
    /// Folded unchanged lines (IntelliJ's diff separators) and note cards.
    static let foldBand = dynamic(light: hex(0xE4E6EB), dark: hex(0x2B2D30))
    static let foldLabel = dynamic(light: hex(0x6C707E), dark: hex(0x868991))
    static let text = dynamic(light: hex(0x080808), dark: hex(0xBCBEC4))
    static let lineNumber = dynamic(light: hex(0xAEB3C2), dark: hex(0x4B5059))
    static let lineNumberCurrent = dynamic(light: hex(0x767A8A), dark: hex(0xA1A3AB))
    static let border = NSColor.separatorColor
    static let selection = dynamic(light: hex(0xA6D2FF), dark: hex(0x214283))
    /// Inline hints: IntelliJ's inlay colors.
    static let inlayBackground = dynamic(light: hex(0xEDEDED), dark: hex(0x393B40))
    static let inlayText = dynamic(light: hex(0x7A7A7A), dark: hex(0x868A91))
    /// "N usages · author" after a declaration.
    static let lensText = dynamic(light: hex(0x7A7A7A), dark: hex(0x868A91))
    /// A search match (Find in Files, usages): IntelliJ's text-search highlight.
    static let searchMatch = dynamic(light: hex(0xFCD47E), dark: hex(0x114957))

    /// Change markers (gutter bars, the thin line where the other side has nothing).
    static let added = dynamic(light: hex(0x7FC784), dark: hex(0x549159))
    static let modified = dynamic(light: hex(0x88ADF7), dark: hex(0x375FAD))
    static let removed = dynamic(light: hex(0xE55B5B), dark: hex(0xC75450))

    /// IntelliJ's diff blocks: inserted green, modified blue, deleted gray.
    enum Change { case inserted, modified, deleted }
    static func block(_ change: Change) -> NSColor {
        switch change {
        case .inserted: dynamic(light: hex(0xBEE6BE), dark: hex(0x294436))
        case .modified: dynamic(light: hex(0xC2D8F2), dark: hex(0x385570))
        case .deleted: dynamic(light: hex(0xD6D6D6), dark: hex(0x484A4A))
        }
    }
    static func change(head: Range<Int>, work: Range<Int>) -> Change {
        head.isEmpty ? .inserted : work.isEmpty ? .deleted : .modified
    }
    /// Unified layout: HEAD lines red, new lines green, so the two read apart in one column.
    static let unifiedRemoved = dynamic(light: hex(0xF6D5D5), dark: hex(0x4A2A2C))
    static let unifiedAdded = block(.inserted)
    static let unifiedRemovedWord = dynamic(light: hex(0xEDAFAF), dark: hex(0x7A3A3D))
    static let unifiedAddedWord = dynamic(light: hex(0x93D193), dark: hex(0x3E7050))

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    static let lineHeight: CGFloat = 18
    static let inset = NSSize(width: 10, height: 6)

    static func token(_ kind: TokenKind) -> NSColor {
        switch kind {
        case .keyword: dynamic(light: hex(0x0033B3), dark: hex(0xCF8E6D))
        case .string: dynamic(light: hex(0x067D17), dark: hex(0x6AAB73))
        case .comment: dynamic(light: hex(0x8C8C8C), dark: hex(0x7A7E85))
        case .number: dynamic(light: hex(0x1750EB), dark: hex(0x2AACB8))
        case .type: dynamic(light: hex(0x000000), dark: hex(0xBCBEC4))
        case .decorator: dynamic(light: hex(0x9E880D), dark: hex(0xB3AE60))
        case .tag: dynamic(light: hex(0x0033B3), dark: hex(0xD5B778))
        case .attribute: dynamic(light: hex(0x174AD4), dark: hex(0xBABABA))
        }
    }

    /// Semantic token colors (from the language server), WebStorm's scheme.
    static func semantic(_ type: String, modifiers: Set<String>) -> NSColor? {
        switch type {
        case "function", "method":
            return modifiers.contains("declaration") || modifiers.contains("definition")
                ? dynamic(light: hex(0x00627A), dark: hex(0x56A8F5))
                : dynamic(light: hex(0x00627A), dark: hex(0x57AAF7))
        case "property", "enumMember":
            return dynamic(light: hex(0x871094), dark: hex(0xC77DBB))
        case "parameter": return dynamic(light: hex(0x000000), dark: hex(0xBCBEC4))
        case "class", "interface", "enum", "type", "typeParameter", "namespace":
            return dynamic(light: hex(0x000000), dark: hex(0xBCBEC4))
        case "variable":
            return modifiers.contains("readonly") && modifiers.contains("static") ? dynamic(light: hex(0x871094), dark: hex(0xC77DBB)) : nil
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
                              blue: b.blueComponent + (c.blueComponent - b.blueComponent) * alpha, alpha: 1)
            }
            return out
        }
    }

    /// A section's line color: IntelliJ's block color at full strength; a reviewed section fades.
    static func fill(_ change: Change, hasWords: Bool, staged: Bool) -> NSColor {
        fill(block(change), hasWords: hasWords, staged: staged)
    }
    static func fill(_ base: NSColor, hasWords: Bool, staged: Bool) -> NSColor {
        staged ? solid(base, 0.35) : base
    }
    /// Changed words inside a modified section: a brighter shade of it, so they stand out.
    static let modifiedWord = dynamic(light: hex(0x9DBFF0), dark: hex(0x4B70A3))
    /// Changed words (faded once reviewed).
    static func word(_ base: NSColor, staged: Bool) -> NSColor { staged ? solid(base, 0.5) : base }

    /// The marker color for a section (pure insertions and deletions get a line on the other side).
    static func marker(_ change: Change) -> NSColor {
        switch change {
        case .inserted: added
        case .modified: modified
        case .deleted: dynamic(light: hex(0x767A8A), dark: hex(0x868A91))
        }
    }

    /// File names by change, as IntelliJ colors them in the commit tree and project view.
    nonisolated static func fileStatus(_ kind: ChangeKind) -> NSColor {
        switch kind {
        case .modified: dynamic(light: hex(0x0033B3), dark: hex(0x70AEFF))
        case .renamed: dynamic(light: hex(0x0033B3), dark: hex(0x70AEFF))
        case .added: dynamic(light: hex(0x067D17), dark: hex(0x73BD79))
        case .untracked: dynamic(light: hex(0xB23247), dark: hex(0xE88F89))
        case .deleted: dynamic(light: hex(0x6C707E), dark: hex(0x6F737A))
        case .conflicted: dynamic(light: hex(0xC4221D), dark: hex(0xDE6A66))
        }
    }
}
