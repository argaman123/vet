import Foundation

// What language servers say about the code being read: hover, semantic tokens, inlay hints,
// code lenses, symbols. Each type parses the server's JSON; nothing here talks to a process.

// MARK: Hover

public struct HoverInfo: Sendable, Equatable, Hashable {
    /// The first fenced code block of a markdown hover (or a MarkedString's code), e.g.
    /// `(method) Shape.area(): number`.
    public let signature: String?
    /// The rest of the hover as plain text: markdown links, emphasis and code marks stripped.
    public let documentation: String?
    /// The range the hover is about, when the server says.
    public let range: LSPRange?

    public init(signature: String?, documentation: String?, range: LSPRange?) {
        self.signature = signature
        self.documentation = documentation
        self.range = range
    }

    /// A `textDocument/hover` result; nil for `null` or a hover that says nothing.
    public static func parse(_ result: JSONValue) -> HoverInfo? {
        guard let contents = result["contents"] else { return nil }
        let (signature, documentation) = split(markdown: markdown(of: contents))
        guard signature != nil || documentation != nil else { return nil }
        return HoverInfo(signature: signature, documentation: documentation, range: LSPRange(result["range"]))
    }

    /// `MarkupContent`, `MarkedString` or `MarkedString[]` as one markdown string; plain text is
    /// escaped so it isn't read as markdown.
    static func markdown(of contents: JSONValue) -> String {
        switch contents {
        case .string(let s):
            return s
        case .array(let items):
            return items.map(markdown(of:)).filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .object:
            let value = contents["value"]?.string ?? ""
            if let language = contents["language"]?.string { return "```\(language)\n\(value)\n```" }
            if contents["kind"]?.string == "plaintext" { return MarkdownText.escaped(value) }
            return value
        default:
            return ""
        }
    }

    /// Splits hover markdown into its first fenced code block and the rest as plain text.
    public static func split(markdown: String) -> (signature: String?, documentation: String?) {
        let lines = markdown.components(separatedBy: .newlines)
        var signature: String?
        var rest: [String] = []
        var i = 0
        while i < lines.count {
            if signature == nil, let fence = MarkdownText.fence(lines[i]) {
                var body: [String] = []
                i += 1
                while i < lines.count && !MarkdownText.closes(lines[i], fence) {
                    body.append(lines[i])
                    i += 1
                }
                i += 1 // the closing fence
                let code = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !code.isEmpty { signature = code } // an empty block is dropped
                continue
            }
            rest.append(lines[i])
            i += 1
        }
        let documentation = MarkdownText.plain(rest.joined(separator: "\n"))
        return (signature, documentation.isEmpty ? nil : documentation)
    }
}

/// Markdown to plain text, for hover documentation.
public enum MarkdownText {
    /// The fence that opens a code block on this line (```` ``` ```` or `~~~`, possibly longer), if any.
    static func fence(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for mark: Character in ["`", "~"] {
            let run = trimmed.prefix { $0 == mark }
            if run.count >= 3 { return String(run) }
        }
        return nil
    }

    static func closes(_ line: String, _ fence: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(fence) && trimmed.drop { $0 == fence.first }.allSatisfy(\.isWhitespace)
    }

    /// Plain text with markdown's punctuation escaped, so `plain` gives it back unchanged.
    static func escaped(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\`*_[]<>#~|".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// The text a reader sees: links and images become their text, emphasis, inline code marks,
    /// heading marks, block quotes and rules go, escapes and common HTML entities are decoded.
    /// Code blocks keep their lines (without the fences). Blank runs collapse to one blank line.
    public static func plain(_ markdown: String) -> String {
        var out: [String] = []
        var fence: String?
        for line in markdown.components(separatedBy: .newlines) {
            if let open = fence {
                if closes(line, open) { fence = nil } else { out.append(line) }
                continue
            }
            if let open = self.fence(line) {
                fence = open
                continue
            }
            if isRule(line) {
                out.append("")
                continue
            }
            var text = Substring(line)
            let indent = text.prefix { $0 == " " }
            text = text.dropFirst(indent.count)
            if text.hasPrefix(">") { text = text.dropFirst().drop { $0 == " " } }
            if text.hasPrefix("#") {
                let hashes = text.prefix { $0 == "#" }
                if hashes.count <= 6, text.dropFirst(hashes.count).first?.isWhitespace ?? true {
                    text = text.dropFirst(hashes.count).drop { $0 == " " }
                }
            }
            out.append(String(indent) + inline(String(text)))
        }
        // Trailing spaces off, blank runs to one, no blank lines at either end.
        var lines: [String] = []
        for line in out.map({ $0.replacing(/\s+$/, with: "") }) {
            if line.isEmpty && (lines.last?.isEmpty ?? true) { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func isRule(_ line: String) -> Bool {
        let chars = line.filter { !$0.isWhitespace }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    /// One line's inline markup. Code spans and backslash escapes are set aside first so
    /// emphasis rules don't touch what they contain.
    static func inline(_ line: String) -> String {
        var kept: [String] = []
        func keep(_ s: String) -> String {
            kept.append(s)
            return "\u{1}\(kept.count - 1)\u{2}"
        }
        var text = line
        text = text.replacing(/(`+)(.+?)\1/) { keep(String($0.output.2).trimmingCharacters(in: .whitespaces)) }
        text = text.replacing(/\\([!-\/:-@\[-`{-~])/) { keep(String($0.output.1)) }
        text = text.replacing(/<br\s*\/?>/.ignoresCase()) { _ in "\n" }
        text = text.replacing(/!\[([^\]]*)\]\([^)]*\)/) { String($0.output.1) }
        text = text.replacing(/\[([^\]]+)\]\([^)]*\)/) { String($0.output.1) }
        text = text.replacing(/\[([^\]]+)\]\[[^\]]*\]/) { String($0.output.1) }
        text = text.replacing(/<((?:https?|file|mailto):[^>\s]+)>/) { String($0.output.1) }
        text = text.replacing(/\*\*(\S(?:.*?\S)?)\*\*/) { String($0.output.1) }
        text = text.replacing(/(^|[^\p{L}\p{N}])__(\S(?:.*?\S)?)__(?![\p{L}\p{N}])/) { String($0.output.1) + String($0.output.2) }
        text = text.replacing(/\*(\S(?:.*?\S)?)\*/) { String($0.output.1) }
        text = text.replacing(/(^|[^\p{L}\p{N}_])_(\S(?:.*?\S)?)_(?![\p{L}\p{N}_])/) { String($0.output.1) + String($0.output.2) }
        text = text.replacing(/~~(\S(?:.*?\S)?)~~/) { String($0.output.1) }
        text = decodeEntities(text)
        text = text.replacing(/\x{1}(\d+)\x{2}/) { kept[Int($0.output.1)!] }
        return text
    }

    private static let entities: [String: String] = [
        "nbsp": " ", "lt": "<", "gt": ">", "amp": "&", "quot": "\"", "apos": "'", "#39": "'",
        "mdash": "—", "ndash": "–", "hellip": "…",
    ]

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacing(/&(#?[A-Za-z0-9]+);/) { match in
            let name = String(match.output.1)
            if let known = entities[name] { return known }
            if name.hasPrefix("#"), let code = name.dropFirst().hasPrefix("x")
                ? UInt32(name.dropFirst(2), radix: 16) : UInt32(name.dropFirst()),
               let scalar = Unicode.Scalar(code) {
                return String(Character(scalar))
            }
            return String(match.output.0)
        }
    }
}

// MARK: Semantic tokens

/// The token types and modifiers a server announced in `initialize`
/// (`semanticTokensProvider.legend`); tokens refer to them by index and bit.
public struct SemanticTokenLegend: Sendable, Equatable, Hashable {
    public let tokenTypes: [String]
    public let tokenModifiers: [String]

    public init(tokenTypes: [String], tokenModifiers: [String]) {
        self.tokenTypes = tokenTypes
        self.tokenModifiers = tokenModifiers
    }

    public init?(_ json: JSONValue?) {
        guard let types = json?["tokenTypes"]?.array else { return nil }
        self.init(tokenTypes: types.map { $0.string ?? "" },
                  tokenModifiers: (json?["tokenModifiers"]?.array ?? []).map { $0.string ?? "" })
    }
}

public struct SemanticToken: Sendable, Equatable, Hashable {
    public let line: Int
    public let character: Int // UTF-16 units
    public let length: Int // UTF-16 units
    public let type: String
    public let modifiers: Set<String>

    public init(line: Int, character: Int, length: Int, type: String, modifiers: Set<String>) {
        self.line = line
        self.character = character
        self.length = length
        self.type = type
        self.modifiers = modifiers
    }

    /// Decodes `SemanticTokens.data`: five integers per token (line delta, start delta — from the
    /// previous token's start on the same line, else from column 0 —, length, type index,
    /// modifier bits). A type outside the legend drops that token but still moves the position.
    public static func decode(_ data: [Int], legend: SemanticTokenLegend) -> [SemanticToken] {
        var tokens: [SemanticToken] = []
        tokens.reserveCapacity(data.count / 5)
        var line = 0, character = 0
        var i = 0
        while i + 4 < data.count {
            let deltaLine = data[i], deltaStart = data[i + 1], length = data[i + 2]
            let typeIndex = data[i + 3], bits = data[i + 4]
            i += 5
            if deltaLine > 0 {
                line += deltaLine
                character = deltaStart
            } else {
                character += deltaStart
            }
            guard legend.tokenTypes.indices.contains(typeIndex), length > 0 else { continue }
            var modifiers = Set<String>()
            if bits != 0 {
                for (bit, name) in legend.tokenModifiers.enumerated() where bit < Int.bitWidth - 1 && bits & (1 << bit) != 0 {
                    modifiers.insert(name)
                }
            }
            tokens.append(SemanticToken(line: line, character: character, length: length,
                                        type: legend.tokenTypes[typeIndex], modifiers: modifiers))
        }
        return tokens
    }

    /// A `textDocument/semanticTokens/full` (or `/range`) result.
    public static func list(from result: JSONValue, legend: SemanticTokenLegend) -> [SemanticToken] {
        decode((result["data"]?.array ?? []).compactMap(\.int), legend: legend)
    }
}

// MARK: Inlay hints

public struct InlayHint: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Hashable { case type, parameter, other }
    public let line: Int
    public let character: Int // UTF-16 units
    public let label: String // e.g. ": number" or "name:"
    public let kind: Kind
    public let paddingLeft: Bool
    public let paddingRight: Bool

    public init(line: Int, character: Int, label: String, kind: Kind, paddingLeft: Bool, paddingRight: Bool) {
        self.line = line
        self.character = character
        self.label = label
        self.kind = kind
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
    }

    /// A `textDocument/inlayHint` result, in position order. A label given as parts is joined.
    public static func list(from result: JSONValue) -> [InlayHint] {
        let hints = (result.array ?? []).compactMap { item -> InlayHint? in
            guard let position = LSPPosition(item["position"]) else { return nil }
            let label: String = switch item["label"] {
            case .string(let s)?: s
            case .array(let parts)?: parts.compactMap { $0["value"]?.string ?? $0.string }.joined()
            default: ""
            }
            guard !label.isEmpty else { return nil }
            let kind: Kind = switch item["kind"]?.int {
            case 1: .type
            case 2: .parameter
            default: .other
            }
            return InlayHint(line: position.line, character: position.character, label: label, kind: kind,
                             paddingLeft: item["paddingLeft"] == .bool(true),
                             paddingRight: item["paddingRight"] == .bool(true))
        }
        return hints.enumerated().sorted {
            ($0.element.line, $0.element.character, $0.offset) < ($1.element.line, $1.element.character, $1.offset)
        }.map(\.element)
    }
}

// MARK: Code lenses

public struct CodeLensInfo: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Hashable { case references, implementations, other }
    public let line: Int
    public let character: Int
    public let title: String // e.g. "3 references", "2 implementations"
    public let kind: Kind

    public init(line: Int, character: Int, title: String, kind: Kind) {
        self.line = line
        self.character = character
        self.title = title
        self.kind = kind
    }

    /// A resolved `CodeLens`; nil while it has no command title (unresolved, or a resolve the
    /// server cancelled).
    public init?(resolved lens: JSONValue) {
        guard let start = LSPPosition(lens["range"]?["start"]),
              let title = lens["command"]?["title"]?.string?.trimmingCharacters(in: .whitespaces),
              !title.isEmpty, !title.hasPrefix("Could not determine") else { return nil } // tsserver's error title
        self.init(line: start.line, character: start.character, title: title, kind: Self.kind(of: title))
    }

    /// The lens's kind from its title ("1 implementation", "4 references", "2 usages").
    public static func kind(of title: String) -> Kind {
        let lower = title.lowercased()
        if lower.contains("implementation") { return .implementations }
        if lower.contains("reference") || lower.contains("usage") { return .references }
        return .other
    }

    /// The locations a resolved lens's command carries, as typescript-language-server sends them
    /// for `editor.action.showReferences` (`[uri, position, Location[]]`); nil when it carries none.
    public static func locations(inResolved lens: JSONValue) -> [LSPLocation]? {
        guard let arguments = lens["command"]?["arguments"]?.array, arguments.count >= 3,
              case .array = arguments[2] else { return nil }
        return LSPLocation.list(from: arguments[2])
    }
}

// MARK: Symbols

public struct DocumentSymbol: Sendable, Equatable, Hashable {
    public let name: String
    public let detail: String?
    public let kind: Int // LSP SymbolKind: 5 class, 6 method, 11 interface, 12 function…
    public let range: LSPRange // the whole declaration
    public let selectionRange: LSPRange // its name
    public let children: [DocumentSymbol]

    public init(name: String, detail: String?, kind: Int, range: LSPRange, selectionRange: LSPRange, children: [DocumentSymbol]) {
        self.name = name
        self.detail = detail
        self.kind = kind
        self.range = range
        self.selectionRange = selectionRange
        self.children = children
    }

    /// A `textDocument/documentSymbol` result: `DocumentSymbol[]` as is, or flat
    /// `SymbolInformation[]` nested by range (a symbol inside another's range is its child).
    public static func list(from result: JSONValue) -> [DocumentSymbol] {
        let items = result.array ?? []
        if items.contains(where: { $0["location"] != nil && $0["selectionRange"] == nil }) {
            return tree(fromFlat: items)
        }
        return items.compactMap(hierarchical)
    }

    private static func hierarchical(_ item: JSONValue) -> DocumentSymbol? {
        guard let name = item["name"]?.string, let range = LSPRange(item["range"]) else { return nil }
        let detail = item["detail"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        return DocumentSymbol(name: name, detail: detail, kind: item["kind"]?.int ?? 0, range: range,
                              selectionRange: LSPRange(item["selectionRange"]) ?? range,
                              children: (item["children"]?.array ?? []).compactMap(hierarchical))
    }

    private final class Node {
        let name: String, detail: String?, kind: Int, range: LSPRange
        var children: [Node] = []
        init(name: String, detail: String?, kind: Int, range: LSPRange) {
            self.name = name; self.detail = detail; self.kind = kind; self.range = range
        }
        var symbol: DocumentSymbol {
            DocumentSymbol(name: name, detail: detail, kind: kind, range: range, selectionRange: range,
                           children: children.map(\.symbol))
        }
    }

    private static func tree(fromFlat items: [JSONValue]) -> [DocumentSymbol] {
        let nodes = items.compactMap { item -> Node? in
            guard let name = item["name"]?.string, let range = LSPRange(item["location"]?["range"]) else { return nil }
            let container = item["containerName"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            return Node(name: name, detail: container, kind: item["kind"]?.int ?? 0, range: range)
        }
        // Outer before inner: by start, the longer range first; the server's order breaks ties.
        let ordered = nodes.enumerated().sorted { a, b in
            if a.element.range.start != b.element.range.start { return a.element.range.start < b.element.range.start }
            if a.element.range.end != b.element.range.end { return a.element.range.end > b.element.range.end }
            return a.offset < b.offset
        }.map(\.element)
        var roots: [Node] = []
        var stack: [Node] = []
        for node in ordered {
            while let top = stack.last, !(top.range.start <= node.range.start && node.range.end <= top.range.end) {
                stack.removeLast()
            }
            if let parent = stack.last { parent.children.append(node) } else { roots.append(node) }
            stack.append(node)
        }
        return roots.map(\.symbol)
    }

    /// This symbol and every descendant, depth first.
    public var flattened: [DocumentSymbol] { [self] + children.flatMap(\.flattened) }
}

public struct WorkspaceSymbol: Sendable, Equatable, Hashable {
    public let name: String
    public let kind: Int // LSP SymbolKind
    public let containerName: String?
    public let location: LSPLocation

    public init(name: String, kind: Int, containerName: String?, location: LSPLocation) {
        self.name = name
        self.kind = kind
        self.containerName = containerName
        self.location = location
    }

    /// A `workspace/symbol` result: `SymbolInformation[]` or `WorkspaceSymbol[]` (whose location
    /// may be a bare URI; it points at the file's start then).
    public static func list(from result: JSONValue) -> [WorkspaceSymbol] {
        (result.array ?? []).compactMap { item in
            guard let name = item["name"]?.string, let uri = item["location"]?["uri"]?.string else { return nil }
            let zero = LSPPosition(line: 0, character: 0)
            let range = LSPRange(item["location"]?["range"]) ?? LSPRange(start: zero, end: zero)
            let container = item["containerName"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            return WorkspaceSymbol(name: name, kind: item["kind"]?.int ?? 0, containerName: container,
                                   location: LSPLocation(uri: uri, range: range))
        }
    }
}

// MARK: Gutter marks

/// WebStorm's gutter arrows: ↑ "overrides / implements" a base type's member, ↓ "is implemented
/// / overridden" (has implementations).
public struct GutterMark: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Hashable { case overrides, implemented }
    public let line: Int
    public let kind: Kind
    public let targets: [LSPLocation]

    public init(line: Int, kind: Kind, targets: [LSPLocation]) {
        self.line = line
        self.kind = kind
        self.targets = targets
    }
}

/// Finds the base types a class or interface declaration names, by reading its header text.
public enum HeritageClause {
    public struct Name: Sendable, Equatable, Hashable {
        public let name: String
        public let line: Int
        public let character: Int // UTF-16 units, the name's first character
    }

    /// Base type names in the header of `symbol` (a class or interface), with their positions, so
    /// a definition request on each finds the base: `extends A implements B, C` (TS/JS),
    /// `(A, B)` (Python), `: A(), B` (Kotlin). For a dotted name the last part is given.
    public static func names(in text: String, declaration symbol: DocumentSymbol, language: LSPLanguage) -> [Name] {
        let utf16 = Array(text.utf16)
        let lines = LineOffsets(utf16)
        // A flat SymbolInformation has no name range: start at the declaration, after its name.
        let flat = symbol.selectionRange == symbol.range
        guard let from = lines.offset(of: flat ? symbol.range.start : symbol.selectionRange.end), from <= utf16.count else { return [] }
        let limit = min(utf16.count, (lines.offset(of: symbol.range.end) ?? utf16.count), from + 4000)
        var scanner = Scanner(utf16: utf16, at: from, limit: limit)
        if flat {
            while true {
                let token = scanner.next()
                if token == .end { return [] }
                if case .identifier(let name, _) = token, name == symbol.name { break }
            }
        }
        let found: [(String, Int)] = switch language {
        case .typescript: scanner.typescript()
        case .python: scanner.python()
        case .kotlin: scanner.kotlin()
        }
        return found.map { name, offset in
            let position = lines.position(of: offset)
            return Name(name: name, line: position.line, character: position.character)
        }
    }

    /// The words in front of a declaration's name (`abstract`, `open`, `override`, `interface`…),
    /// comments and strings skipped.
    public static func modifiers(in text: String, declaration symbol: DocumentSymbol) -> Set<String> {
        let utf16 = Array(text.utf16)
        let lines = LineOffsets(utf16)
        guard let from = lines.offset(of: symbol.range.start), let to = lines.offset(of: symbol.selectionRange.start),
              from < to else { return [] }
        var scanner = Scanner(utf16: utf16, at: from, limit: min(to, utf16.count))
        var words = Set<String>()
        while true {
            switch scanner.next() {
            case .end: return words
            case .identifier(let word, _): words.insert(word)
            case .punct: continue
            }
        }
    }

    /// Line starts, for converting between LSP positions and UTF-16 offsets.
    struct LineOffsets {
        private var starts: [Int] = [0]
        let count: Int

        init(_ utf16: [UInt16]) {
            count = utf16.count
            var i = 0
            while i < utf16.count {
                let u = utf16[i]
                if u == 13 { // \r or \r\n
                    if i + 1 < utf16.count && utf16[i + 1] == 10 { i += 1 }
                    starts.append(i + 1)
                } else if u == 10 {
                    starts.append(i + 1)
                }
                i += 1
            }
        }

        func offset(of position: LSPPosition) -> Int? {
            guard starts.indices.contains(position.line) else { return nil }
            return min(starts[position.line] + position.character, count)
        }

        func position(of offset: Int) -> LSPPosition {
            var lo = 0, hi = starts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            return LSPPosition(line: lo, character: offset - starts[lo])
        }
    }

    /// A small tokenizer over the declaration header. Comments and strings are skipped.
    struct Scanner {
        let utf16: [UInt16]
        var i: Int
        let limit: Int

        init(utf16: [UInt16], at start: Int, limit: Int) {
            self.utf16 = utf16
            self.i = start
            self.limit = limit
        }

        enum Token: Equatable {
            case identifier(String, Int) // name, offset
            case punct(Character)
            case end
        }

        private func isIdentifierStart(_ u: UInt16) -> Bool {
            (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95 || u == 36 || u > 127
        }

        private func isIdentifierPart(_ u: UInt16) -> Bool { isIdentifierStart(u) || (u >= 48 && u <= 57) }

        mutating func next() -> Token {
            while i < limit {
                let u = utf16[i]
                if u == 32 || u == 9 || u == 10 || u == 13 { i += 1; continue }
                if u == 47, i + 1 < limit, utf16[i + 1] == 47 { // //
                    while i < limit && utf16[i] != 10 { i += 1 }
                    continue
                }
                if u == 35 { // # comment (Python); TS private names start with # too, but not in a header
                    while i < limit && utf16[i] != 10 { i += 1 }
                    continue
                }
                if u == 47, i + 1 < limit, utf16[i + 1] == 42 { // /* */
                    i += 2
                    while i + 1 < limit && !(utf16[i] == 42 && utf16[i + 1] == 47) { i += 1 }
                    i += 2
                    continue
                }
                if u == 34 || u == 39 || u == 96 { // a string: skip it
                    let quote = u
                    i += 1
                    while i < limit && utf16[i] != quote {
                        if utf16[i] == 92 { i += 1 }
                        i += 1
                    }
                    i += 1
                    continue
                }
                if isIdentifierStart(u) {
                    let start = i
                    while i < limit && isIdentifierPart(utf16[i]) { i += 1 }
                    return .identifier(String(decoding: utf16[start..<i], as: UTF16.self), start)
                }
                i += 1
                return .punct(Character(Unicode.Scalar(u) ?? " "))
            }
            return .end
        }

        /// Skips to the bracket that closes `open` (already consumed).
        mutating func skipGroup(_ open: Character) {
            let close: Character = switch open { case "(": ")"; case "[": "]"; case "{": "}"; default: ">" }
            var depth = 1
            while depth > 0 {
                switch next() {
                case .end: return
                case .punct(let c) where c == open: depth += 1
                case .punct(let c) where c == close: depth -= 1
                case .punct("=") where open == "<":
                    // `=>` inside a type argument isn't a closing bracket.
                    if i < limit && utf16[i] == 62 { i += 1 }
                default: break
                }
            }
        }

        /// A possibly dotted, possibly generic type name; the last part is what a definition finds.
        mutating func typeName(startingWith first: (String, Int), separators: Set<Character> = ["."]) -> ((String, Int), Token) {
            var name = first
            while true {
                let token = next()
                switch token {
                case .punct(let c) where separators.contains(c):
                    if case .identifier(let part, let at) = next() { name = (part, at) } else { return (name, .end) }
                case .punct("<"):
                    skipGroup("<")
                default:
                    return (name, token)
                }
            }
        }

        mutating func typescript() -> [(String, Int)] {
            var found: [(String, Int)] = []
            var listing = false // after extends/implements, until `{`
            var token = next()
            while true {
                switch token {
                case .end, .punct("{"), .punct(";"):
                    return found
                case .punct("<") where !listing:
                    skipGroup("<") // the declaration's own type parameters
                    token = next()
                case .punct("("):
                    skipGroup("(") // `extends mixin(Base)` names the call, not its arguments
                    token = next()
                case .identifier("extends", _), .identifier("implements", _):
                    listing = true
                    token = next()
                case .identifier(let name, let at) where listing:
                    let (type, after) = typeName(startingWith: (name, at))
                    found.append(type)
                    token = after
                default:
                    token = next()
                }
            }
        }

        mutating func python() -> [(String, Int)] {
            var found: [(String, Int)] = []
            var token = next()
            if case .punct("[") = token { skipGroup("["); token = next() } // PEP 695 `class A[T](B)`
            guard token == .punct("(") else { return [] }
            token = next()
            while true {
                switch token {
                case .end, .punct(")"), .punct(":"):
                    return found
                case .identifier(let name, let at):
                    let (type, after) = typeName(startingWith: (name, at))
                    if case .punct("=") = after { // keyword argument: metaclass=ABCMeta
                        token = skipArgument()
                    } else {
                        found.append(type)
                        token = after
                        if case .punct("[") = token { skipGroup("["); token = next() }
                    }
                case .punct("*"):
                    token = skipArgument()
                default:
                    token = next()
                }
            }
        }

        /// Skips the rest of one call argument, returning the `,` or `)` after it.
        private mutating func skipArgument() -> Token {
            while true {
                let token = next()
                switch token {
                case .end, .punct(","), .punct(")"): return token
                case .punct(let c) where "([{".contains(c): skipGroup(c)
                default: continue
                }
            }
        }

        mutating func kotlin() -> [(String, Int)] {
            var found: [(String, Int)] = []
            var token = next()
            // Header up to the supertype list: type parameters, a primary constructor, modifiers.
            header: while true {
                switch token {
                case .end, .punct("{"), .punct("="): return []
                case .punct(":"): break header
                case .punct(let c) where c == "<" || c == "(": skipGroup(c)
                default: break
                }
                token = next()
            }
            token = next()
            while true {
                switch token {
                case .end, .punct("{"):
                    return found
                case .identifier("where", _):
                    return found
                case .identifier("by", _):
                    // Delegation: `I by impl`; skip the expression up to the next supertype.
                    while true {
                        token = next()
                        if case .punct(",") = token { break }
                        if case .punct("{") = token { return found }
                        if token == .end { return found }
                        if case .punct(let c) = token, "([".contains(c) { skipGroup(c) }
                    }
                case .identifier(let name, let at):
                    let (type, after) = typeName(startingWith: (name, at))
                    found.append(type)
                    token = after
                    if case .punct("(") = token { skipGroup("("); token = next() }
                    // A supertype is followed by `,`, `{`, `by`, `where`, or the declaration ends.
                    if case .identifier(let word, _) = token, word != "by" && word != "where" { return found }
                case .punct(","):
                    token = next()
                default:
                    return found
                }
            }
        }
    }
}

extension LSPPosition: Comparable {
    public static func < (a: LSPPosition, b: LSPPosition) -> Bool {
        (a.line, a.character) < (b.line, b.character)
    }
}

extension LSPRange {
    public func contains(_ position: LSPPosition) -> Bool { start <= position && position <= end }
}
