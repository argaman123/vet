import AppKit
import VetCore

/// GitHub Dark Default colors for the code area (spec §2.1).
@MainActor
enum DiffTheme {
    nonisolated static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
    }
    static let background = hex(0x0d1117)
    static let gutter = hex(0x0d1117)
    static let foldBand = hex(0x161b22)
    static let text = hex(0xc9d1d9)
    static let lineNumber = hex(0x6e7681)
    static let border = hex(0x30363d)
    static let added = hex(0x3fb950)
    static let removed = hex(0xf85149)
    static let modified = hex(0xd29922)
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    static let lineHeight: CGFloat = 18
    static let inset = NSSize(width: 10, height: 6)

    static func token(_ kind: TokenKind) -> NSColor {
        switch kind {
        case .keyword: hex(0xff7b72)
        case .string: hex(0xa5d6ff)
        case .comment: hex(0x8b949e)
        case .number: hex(0x79c0ff)
        case .type: hex(0xffa657)
        case .decorator: hex(0xd2a8ff)
        case .tag: hex(0x7ee787)
        case .attribute: hex(0x79c0ff)
        }
    }

    /// Ribbon/line color for a section: replaced = orange, only added = green, only removed = red.
    static func color(head: Range<Int>, work: Range<Int>) -> NSColor {
        head.isEmpty ? added : work.isEmpty ? removed : modified
    }
}
