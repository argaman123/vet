import Foundation

/// An "unimportant" rule, as in the Working Tree extension:
/// `*` matches within one path segment, `?` one character, `**` zero or more segments.
/// A pattern without `/` matches a file or folder name at any depth (`*.html`); one with `/`
/// is relative to the repository root (`src/generated/**`). Case-sensitive.
public struct GlobRule: Sendable, Hashable {
    public static let maxRules = 200
    public static let maxLength = 256

    public let pattern: String
    private let regex: NSRegularExpression?
    private let nameOnly: Bool

    public init(_ pattern: String) {
        let p = String(pattern.trimmingCharacters(in: .whitespaces).prefix(Self.maxLength))
        self.pattern = p
        let body = p.hasPrefix("/") ? String(p.dropFirst()) : p
        nameOnly = !body.contains("/")
        regex = try? NSRegularExpression(pattern: "^" + Self.translate(body) + "$")
    }

    /// True when the rule matches `path` (repo-relative) or any folder above it,
    /// since a marked folder covers everything inside it.
    public func matches(_ path: String) -> Bool {
        guard let regex else { return false }
        var candidate = path
        while !candidate.isEmpty {
            let subject = nameOnly ? (candidate as NSString).lastPathComponent : candidate
            if regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil { return true }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        return false
    }

    public static func == (a: GlobRule, b: GlobRule) -> Bool { a.pattern == b.pattern }
    public func hash(into h: inout Hasher) { h.combine(pattern) }

    private static func translate(_ glob: String) -> String {
        var out = ""
        let chars = Array(glob)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*" && i + 1 < chars.count && chars[i + 1] == "*" {
                let atStart = i == 0 || chars[i - 1] == "/"
                let slashAfter = i + 2 < chars.count && chars[i + 2] == "/"
                if atStart && slashAfter { out += "(?:[^/]+/)*"; i += 3; continue } // **/ → any folders
                if atStart && i + 2 == chars.count {                                // trailing /** → the folder and everything in it
                    if out.hasSuffix("/") { out.removeLast(); out += "(?:/.*)?" } else { out += ".*" }
                    i += 2
                    continue
                }
                out += ".*"
                i += 2
            } else if c == "*" {
                out += "[^/]*"; i += 1
            } else if c == "?" {
                out += "[^/]"; i += 1
            } else if c == "/" {
                out += "/"; i += 1
            } else {
                out += NSRegularExpression.escapedPattern(for: String(c)); i += 1
            }
        }
        return out
    }
}
