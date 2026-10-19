import AppKit

/// One of Vet's color themes: the app's surfaces (window, sidebar, bars), the code panes, the
/// diff, and the code colors. Vet is a dark app; `light` is used only if the system forces light.
struct Palette: Sendable {
    let id: String
    let name: String
    // App surfaces
    var window: UInt32, sidebar: UInt32, header: UInt32
    /// The accent (selected controls, focus) and the folder color.
    var accent: UInt32 = 0x4F8BFF, folder: UInt32 = 0x7D8796
    /// The sidebar is the system's Liquid Glass (not painted); the accent is the user's system accent.
    var glassSidebar = false, systemAccent = false
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

    /// Neutral graphite: the system's own glass sidebar and accent color, code colors of its own.
    static let graphite = Palette(
        id: "graphite", name: "Graphite",
        window: 0x1A1A1C, sidebar: 0x1E1E20, header: 0x1C1C1E, accent: 0x0A84FF, folder: 0x8E8E93, glassSidebar: true, systemAccent: true,
        background: 0x18181A, text: 0xE2E2E6, lineNumber: 0x48484E, lineNumberCurrent: 0xB4B4BC, selection: 0x3A3A44,
        foldPill: 0x232326, foldPillHover: 0x2E2E33, foldPillBorder: 0x34343A, foldLabel: 0x8E8E96, foldWave: 0x2C2C31,
        inlayBackground: 0x26262A, inlayText: 0x9898A0, lensText: 0x76767E, searchMatch: 0x5A4A1C,
        inserted: 0x1C3424, modified: 0x232F45, deleted: 0x3F2128,
        insertedWord: 0x2C5A3A, modifiedWord: 0x33497A, deletedWord: 0x6B2A35,
        addedMark: 0x32D74B, modifiedMark: 0x64A8FF, removedMark: 0xFF6961,
        keyword: 0xF2A65A, string: 0x9CD67A, comment: 0x6E7480, number: 0xF5D76E, type: 0xC5A8FF,
        decorator: 0xFF9DB0, tag: 0x7CC4FF, attribute: 0xF2A65A,
        function: 0x7CC4FF, property: 0xFF9DB0, parameter: 0xE6B8FF, classType: 0xC5A8FF, constant: 0xFF8B7B, namespace: 0x7CDCD0,
        fileModified: 0x64A8FF, fileAdded: 0x32D74B, fileDeleted: 0xFF6961, fileConflict: 0xFFD60A)

    /// Warm charcoal with an amber accent.
    static let ember = Palette(
        id: "ember", name: "Ember",
        window: 0x110E0D, sidebar: 0x141110, header: 0x171312, accent: 0xFF9E5E, folder: 0xFFB86B,
        background: 0x1A1614, text: 0xEAE0D8, lineNumber: 0x4E443E, lineNumberCurrent: 0xC4B6AC, selection: 0x4A3628,
        foldPill: 0x221C19, foldPillHover: 0x2E2622, foldPillBorder: 0x352C27, foldLabel: 0x9A8C82, foldWave: 0x302824,
        inlayBackground: 0x261F1C, inlayText: 0xA0928A, lensText: 0x7E7068, searchMatch: 0x5C3E14,
        inserted: 0x22331E, modified: 0x3B2E1A, deleted: 0x3E1E1C,
        insertedWord: 0x37562E, modifiedWord: 0x664A22, deletedWord: 0x6A2C28,
        addedMark: 0x8CCF5A, modifiedMark: 0xFFB454, removedMark: 0xFF6B5B,
        keyword: 0xFF9E5E, string: 0xC3E88D, comment: 0x7A6C62, number: 0xF78C6C, type: 0x8FD3C7,
        decorator: 0xF0A3B5, tag: 0xFF9E5E, attribute: 0xFFD27A,
        function: 0xFFD27A, property: 0xF0A3B5, parameter: 0xD7B6FF, classType: 0x8FD3C7, constant: 0xFF7B6B, namespace: 0x8FD3C7,
        fileModified: 0xFFB454, fileAdded: 0x8CCF5A, fileDeleted: 0xFF6B5B, fileConflict: 0xFF6B5B)

    /// Near-black greys with no tint (like your VS Code's Monokai Black), Vet's code colors.
    static let carbon: Palette = {
        var p = Palette.vet
        p = Palette(id: "carbon", name: "Carbon",
            window: 0x0B0B0B, sidebar: 0x0E0E0E, header: 0x111111, accent: 0x4F8BFF, folder: 0x7D8796,
            background: 0x141414, text: 0xD9D9D9, lineNumber: 0x404040, lineNumberCurrent: 0xB0B0B0, selection: 0x37393D,
            foldPill: 0x1B1B1B, foldPillHover: 0x262626, foldPillBorder: 0x2C2C2C, foldLabel: 0x8C8C8C, foldWave: 0x2A2A2A,
            inlayBackground: 0x1F1F1F, inlayText: 0x8F8F8F, lensText: 0x6E6E6E, searchMatch: 0x5A4416,
            inserted: 0x1A3022, modified: 0x1C2A40, deleted: 0x371B20,
            insertedWord: 0x2A5538, modifiedWord: 0x2A4675, deletedWord: 0x632430,
            addedMark: 0x3FB950, modifiedMark: 0x58A6FF, removedMark: 0xF85149,
            keyword: p.keyword, string: p.string, comment: 0x5E5E5E, number: p.number, type: p.type,
            decorator: p.decorator, tag: p.tag, attribute: p.attribute,
            function: p.function, property: p.property, parameter: p.parameter, classType: p.classType, constant: p.constant, namespace: p.namespace,
            fileModified: 0x58A6FF, fileAdded: 0x3FB950, fileDeleted: 0xF85149, fileConflict: 0xD29922)
        return p
    }()

    /// Deeper: almost black, the chrome nearly vanishes, code at full strength.
    static let obsidian: Palette = {
        var p = Palette.carbon
        p = Palette(id: "obsidian", name: "Obsidian",
            window: 0x070707, sidebar: 0x090909, header: 0x0B0B0B, accent: 0x5E9BFF, folder: 0x7D8796,
            background: 0x0D0D0D, text: 0xE4E4E4, lineNumber: 0x383838, lineNumberCurrent: 0xBDBDBD, selection: 0x333539,
            foldPill: 0x161616, foldPillHover: 0x212121, foldPillBorder: 0x262626, foldLabel: 0x878787, foldWave: 0x232323,
            inlayBackground: 0x191919, inlayText: 0x8A8A8A, lensText: 0x666666, searchMatch: 0x5A4416,
            inserted: 0x14301E, modified: 0x172842, deleted: 0x381419,
            insertedWord: 0x245C36, modifiedWord: 0x26487E, deletedWord: 0x6A1F2C,
            addedMark: 0x3FB950, modifiedMark: 0x58A6FF, removedMark: 0xF85149,
            keyword: p.keyword, string: p.string, comment: 0x5A5A5A, number: p.number, type: p.type,
            decorator: p.decorator, tag: p.tag, attribute: p.attribute,
            function: p.function, property: p.property, parameter: p.parameter, classType: p.classType, constant: p.constant, namespace: p.namespace,
            fileModified: 0x58A6FF, fileAdded: 0x3FB950, fileDeleted: 0xF85149, fileConflict: 0xD29922)
        return p
    }()

    /// A step lighter: dark charcoal grey, softer contrast, still neutral.
    static let charcoal: Palette = {
        var p = Palette.carbon
        p = Palette(id: "charcoal", name: "Charcoal",
            window: 0x151515, sidebar: 0x181818, header: 0x1B1B1B, accent: 0x4F8BFF, folder: 0x7D8796,
            background: 0x1E1E1E, text: 0xD4D4D4, lineNumber: 0x4A4A4A, lineNumberCurrent: 0xB4B4B4, selection: 0x3A3D41,
            foldPill: 0x252525, foldPillHover: 0x2F2F2F, foldPillBorder: 0x353535, foldLabel: 0x8E8E8E, foldWave: 0x313131,
            inlayBackground: 0x2A2A2A, inlayText: 0x939393, lensText: 0x737373, searchMatch: 0x5A4416,
            inserted: 0x213626, modified: 0x223249, deleted: 0x3D2226,
            insertedWord: 0x305B3D, modifiedWord: 0x304D7C, deletedWord: 0x672C35,
            addedMark: 0x3FB950, modifiedMark: 0x58A6FF, removedMark: 0xF85149,
            keyword: p.keyword, string: p.string, comment: 0x6A6A6A, number: p.number, type: p.type,
            decorator: p.decorator, tag: p.tag, attribute: p.attribute,
            function: p.function, property: p.property, parameter: p.parameter, classType: p.classType, constant: p.constant, namespace: p.namespace,
            fileModified: 0x58A6FF, fileAdded: 0x3FB950, fileDeleted: 0xF85149, fileConflict: 0xD29922)
        return p
    }()

    /// Aurora: Vet's own. One cool family from the logo (blue → cyan → mint → green) for code
    /// structure, a single warm amber for values, quiet slate neutrals.
    static let aurora = Palette(
        id: "aurora", name: "Aurora",
        window: 0x0C0D10, sidebar: 0x0F1014, header: 0x121318, accent: 0x6E9BFF, folder: 0x7D8796,
        background: 0x14161B, text: 0xD6DCE8, lineNumber: 0x434A58, lineNumberCurrent: 0xAEB7C8, selection: 0x2C3A55,
        foldPill: 0x1B1E25, foldPillHover: 0x252935, foldPillBorder: 0x2B303B, foldLabel: 0x8892A6, foldWave: 0x272B35,
        inlayBackground: 0x1D2028, inlayText: 0x8590A4, lensText: 0x6C7689, searchMatch: 0x4A3E1C,
        inserted: 0x14302A, modified: 0x182A46, deleted: 0x3A1D26,
        insertedWord: 0x1F5446, modifiedWord: 0x26477A, deletedWord: 0x66283A,
        addedMark: 0x48D7A4, modifiedMark: 0x6E9BFF, removedMark: 0xF0708A,
        keyword: 0x7EA6FF, string: 0x9CDE8A, comment: 0x5E687C, number: 0xFFC27A, type: 0x5FD3E6,
        decorator: 0xFFC27A, tag: 0x7EA6FF, attribute: 0x5FD3E6,
        function: 0x67E3C2, property: 0xB9C6F2, parameter: 0xD3DCF5, classType: 0x5FD3E6, constant: 0xFFC27A, namespace: 0x5FD3E6,
        fileModified: 0x6E9BFF, fileAdded: 0x48D7A4, fileDeleted: 0xF0708A, fileConflict: 0xFFC27A)

    static let all: [Palette] = [.aurora, .vet, .carbon, .obsidian, .charcoal, .graphite, .ember, .monokai, .neon]
}

/// Design variants being tried (Settings-free switches read from defaults; mockups for now).
enum Design {
    /// How a file or section is marked reviewed.
    enum Marker: String { case ring, native, dot, inline, bar, row, check, circle, mono, progress }
    /// The whole app's look around the code.
    enum Direction: String { case current, glass, monolith, studio }
    static var direction: Direction { Direction(rawValue: UserDefaults.standard.string(forKey: "design.direction") ?? "") ?? .glass }
    /// How changed files' names show their status.
    enum Names { case colored, dot, glyph }
    static var names: Names { direction == .monolith ? .glyph : .colored }
    static var monoIcons: Bool { direction == .monolith }
    static var accentFolders: Bool { false }
    /// Surfaces let the desktop through, in levels: window clear, bars thin, code a dark veil.
    static var frosted: Bool { UserDefaults.standard.object(forKey: "design.frosted") as? Bool ?? true }
    /// What joins the two sides of the diff.
    enum Bridge: String { case ribbon, lines, map }
    static var marker: Marker { Marker(rawValue: UserDefaults.standard.string(forKey: "design.marker") ?? "") ?? .progress }
    static var bridge: Bridge { Bridge(rawValue: UserDefaults.standard.string(forKey: "design.bridge") ?? "") ?? .ribbon }
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
