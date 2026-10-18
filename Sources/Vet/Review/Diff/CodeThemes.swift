import AppKit

/// One of Vet's color themes: the app's surfaces (window, sidebar, bars), the code panes, the
/// diff, and the code colors. Vet is a dark app; `light` is used only if the system forces light.
struct Palette: Sendable {
    let id: String
    let name: String
    // App surfaces
    var window: UInt32, sidebar: UInt32, header: UInt32
    /// The accent (selected controls, focus) and the folder color.
    var accent: UInt32 = 0x4F8BFF, folder: UInt32 = 0x4FD1C5
    // Code panes
    var background: UInt32, text: UInt32, lineNumber: UInt32, lineNumberCurrent: UInt32, selection: UInt32
    var foldPill: UInt32, foldPillHover: UInt32, foldPillBorder: UInt32, foldLabel: UInt32, foldWave: UInt32
    var inlayBackground: UInt32, inlayText: UInt32, lensText: UInt32, searchMatch: UInt32
    // Diff
    var inserted: UInt32, modified: UInt32, deleted: UInt32
    var insertedWord: UInt32, modifiedWord: UInt32, deletedWord: UInt32
    var addedMark: UInt32, modifiedMark: UInt32, removedMark: UInt32
    // Code
    var keyword: UInt32, string: UInt32, comment: UInt32, number: UInt32, type: UInt32
    var decorator: UInt32, tag: UInt32, attribute: UInt32
    var function: UInt32, property: UInt32, parameter: UInt32, classType: UInt32, constant: UInt32, namespace: UInt32
    // File names by change (GitHub's colors, as in your VS Code)
    var fileModified: UInt32, fileAdded: UInt32, fileDeleted: UInt32, fileConflict: UInt32
}

extension Palette {
    /// Your VS Code theme (Bearded Monokai Black), made Vet's: near-black, vivid, warm.
    static let monokai = Palette(
        id: "monokai", name: "Monokai Black",
        window: 0x0B0B0B, sidebar: 0x0E0E0E, header: 0x101010,
        background: 0x141414, text: 0xD4D4D4, lineNumber: 0x4A4F4C, lineNumberCurrent: 0xB5B5B5, selection: 0x3A3D41,
        foldPill: 0x1C1C1C, foldPillHover: 0x2A2A2A, foldPillBorder: 0x303030, foldLabel: 0x8F8F8F, foldWave: 0x2E2E2E,
        inlayBackground: 0x222222, inlayText: 0x9A9A9A, lensText: 0x7E7E7E, searchMatch: 0x5C4A12,
        inserted: 0x1D3319, modified: 0x18304A, deleted: 0x3B1A1E,
        insertedWord: 0x2F5A26, modifiedWord: 0x24507E, deletedWord: 0x63262D,
        addedMark: 0x3FB950, modifiedMark: 0x58A6FF, removedMark: 0xF85149,
        keyword: 0xFFD866, string: 0xA9DC76, comment: 0x6A6A6A, number: 0xFC9867, type: 0xAB9DF2,
        decorator: 0xE991E3, tag: 0x78DCE8, attribute: 0xFFD866,
        function: 0x78DCE8, property: 0xFC9867, parameter: 0xE991E3, classType: 0xAB9DF2, constant: 0xFC6A67, namespace: 0x78E8C6,
        fileModified: 0x58A6FF, fileAdded: 0x3FB950, fileDeleted: 0xF85149, fileConflict: 0xD29922)

    /// Vet's own: the logo's blue, teal and green on a blue-black, with warm accents.
    static let vet = Palette(
        id: "vet", name: "Vet",
        window: 0x08090C, sidebar: 0x0B0D11, header: 0x0E1015,
        background: 0x111318, text: 0xD3D9E3, lineNumber: 0x3E4554, lineNumberCurrent: 0xAAB3C5, selection: 0x2A3A5C,
        foldPill: 0x171B22, foldPillHover: 0x222834, foldPillBorder: 0x2A303C, foldLabel: 0x8A93A6, foldWave: 0x262C37,
        inlayBackground: 0x1B2029, inlayText: 0x8E98AB, lensText: 0x6F7A8E, searchMatch: 0x5A4416,
        inserted: 0x12301F, modified: 0x152A47, deleted: 0x3A1720,
        insertedWord: 0x1F5A36, modifiedWord: 0x234A80, deletedWord: 0x6A2333,
        addedMark: 0x3FB950, modifiedMark: 0x58A6FF, removedMark: 0xF85149,
        keyword: 0x7AA2FF, string: 0x5ADB8A, comment: 0x5C6578, number: 0xFF9E64, type: 0x4FD1C5,
        decorator: 0xFF9E64, tag: 0x7AA2FF, attribute: 0x4FD1C5,
        function: 0xFFD166, property: 0xF48FB1, parameter: 0xC3A6FF, classType: 0x4FD1C5, constant: 0xFF6B8B, namespace: 0x4FD1C5,
        fileModified: 0x58A6FF, fileAdded: 0x3FB950, fileDeleted: 0xF85149, fileConflict: 0xD29922)

    /// High contrast and loud: true black, neon accents.
    static let neon = Palette(
        id: "neon", name: "Neon",
        window: 0x050506, sidebar: 0x08080A, header: 0x0B0B0E,
        background: 0x0C0C0F, text: 0xE8E8EE, lineNumber: 0x44444F, lineNumberCurrent: 0xC8C8D2, selection: 0x343456,
        foldPill: 0x16161C, foldPillHover: 0x22222B, foldPillBorder: 0x2C2C36, foldLabel: 0x9090A0, foldWave: 0x24242C,
        inlayBackground: 0x1A1A22, inlayText: 0x9A9AB0, lensText: 0x767688, searchMatch: 0x5E2E5A,
        inserted: 0x10351C, modified: 0x1A2550, deleted: 0x44121C,
        insertedWord: 0x1E6334, modifiedWord: 0x2B3F8A, deletedWord: 0x7A1F33,
        addedMark: 0x3FB950, modifiedMark: 0x58A6FF, removedMark: 0xF85149,
        keyword: 0xFF5FA2, string: 0xB8F35F, comment: 0x6E6E80, number: 0xFFB347, type: 0x9D7CFF,
        decorator: 0xFF5FA2, tag: 0x4CC9F0, attribute: 0xFFD23F,
        function: 0x4CC9F0, property: 0xFFD23F, parameter: 0xFF8F70, classType: 0x9D7CFF, constant: 0xFF5F5F, namespace: 0x4CC9F0,
        fileModified: 0x58A6FF, fileAdded: 0x3FB950, fileDeleted: 0xF85149, fileConflict: 0xD29922)

    /// Light mode (only when the system insists): IntelliJ Light's code colors.
    static let light = Palette(
        id: "light", name: "Light",
        window: 0xF2F3F5, sidebar: 0xF7F8FA, header: 0xF7F8FA,
        background: 0xFFFFFF, text: 0x080808, lineNumber: 0xAEB3C2, lineNumberCurrent: 0x767A8A, selection: 0xA6D2FF,
        foldPill: 0xEBECF0, foldPillHover: 0xDFE1E5, foldPillBorder: 0xD3D5DB, foldLabel: 0x6C707E, foldWave: 0xC9CCD6,
        inlayBackground: 0xEDEDED, inlayText: 0x7A7A7A, lensText: 0x7A7A7A, searchMatch: 0xFCD47E,
        inserted: 0xD7F0D7, modified: 0xD6E4F7, deleted: 0xF6D5D5,
        insertedWord: 0xA8DCA8, modifiedWord: 0xA9C6EE, deletedWord: 0xEDAFAF,
        addedMark: 0x2DA44E, modifiedMark: 0x0969DA, removedMark: 0xCF222E,
        keyword: 0x0033B3, string: 0x067D17, comment: 0x8C8C8C, number: 0x1750EB, type: 0x000000,
        decorator: 0x9E880D, tag: 0x0033B3, attribute: 0x174AD4,
        function: 0x00627A, property: 0x871094, parameter: 0x000000, classType: 0x000000, constant: 0x871094, namespace: 0x000000,
        fileModified: 0x0969DA, fileAdded: 0x1A7F37, fileDeleted: 0xCF222E, fileConflict: 0x9A6700)

    static let all: [Palette] = [.vet, .monokai, .neon]
}

/// The code font choices (SF Mono is the system's; Google Sans Code ships with Vet).
enum CodeFont: String, CaseIterable, Sendable {
    case sfMono = "SF Mono", googleSansCode = "Google Sans Code", menlo = "Menlo"

    func font(size: CGFloat) -> NSFont {
        switch self {
        case .sfMono: return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .googleSansCode, .menlo:
            return NSFont(name: rawValue, size: size) ?? NSFontManager.shared.font(withFamily: rawValue, traits: [], weight: 5, size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    /// Registers the fonts bundled in the app (once, at launch).
    static func registerBundled() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
