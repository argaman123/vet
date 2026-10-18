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

    static let background = NSColor.textBackgroundColor
    static let gutter = NSColor.textBackgroundColor
    /// Folded unchanged lines and note cards: a faint band in the content layer.
    static let foldBand = dynamic(light: NSColor.black.withAlphaComponent(0.045), dark: NSColor.white.withAlphaComponent(0.05))
    static let text = NSColor.textColor
    static let lineNumber = NSColor.tertiaryLabelColor
    static let border = NSColor.separatorColor
    static let added = NSColor.systemGreen
    static let removed = NSColor.systemRed
    static let modified = NSColor.systemBlue
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

    /// Fill for a section's lines and ribbon: stronger while it needs review, faded once staged.
    static func fill(head: Range<Int>, work: Range<Int>, staged: Bool) -> NSColor {
        solid(color(head: head, work: work), staged ? 0.07 : 0.16)
    }

    /// Ribbon/line color for a section: replaced = blue, only added = green, only removed = red.
    static func color(head: Range<Int>, work: Range<Int>) -> NSColor {
        head.isEmpty ? added : work.isEmpty ? removed : modified
    }
}
