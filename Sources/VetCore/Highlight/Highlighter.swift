import Foundation

public enum TokenKind: Sendable, Hashable {
    case keyword, string, comment, number, type, decorator, tag, attribute
}

public enum CodeLanguage: Sendable, Hashable {
    case typescript, javascript, html, css, json, python, kotlin, swift, markdown, yaml, plain

    public init(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "ts", "tsx", "mts", "cts": self = .typescript
        case "js", "jsx", "mjs", "cjs": self = .javascript
        case "html", "htm": self = .html
        case "css", "scss", "less": self = .css
        case "json", "jsonc": self = .json
        case "py": self = .python
        case "kt", "kts": self = .kotlin
        case "swift": self = .swift
        case "md", "markdown": self = .markdown
        case "yml", "yaml": self = .yaml
        default: self = .plain
        }
    }
}

/// A small, fast tokenizer for syntax colors. Runs over the whole file once (UTF-16 offsets),
/// so comments and strings that span many lines color correctly.
public enum Highlighter {
    public struct Token: Sendable, Hashable {
        public let range: NSRange
        public let kind: TokenKind
    }

    public static func tokens(_ text: String, language: CodeLanguage) -> [Token] {
        switch language {
        case .plain, .markdown: return []
        case .html: return html(Array(text.utf16))
        default: return code(Array(text.utf16), language)
        }
    }

    // MARK: C-like, Python, Kotlin, YAML, JSON, CSS

    private static func code(_ s: [UInt16], _ lang: CodeLanguage) -> [Token] {
        let keywords = Self.keywords[lang] ?? []
        let slashComments = [.typescript, .javascript, .kotlin, .swift, .css, .json].contains(lang)
        let hashComments = [.python, .yaml].contains(lang)
        let backticks = [.typescript, .javascript].contains(lang)
        let tripleQuotes = [.python, .kotlin, .swift].contains(lang)
        var out: [Token] = []
        var i = 0
        let n = s.count
        func at(_ k: Int) -> UInt16 { k < n ? s[k] : 0 }
        while i < n {
            let c = s[i]
            if slashComments && c == 0x2F && at(i + 1) == 0x2F && lang != .css { // //
                let start = i
                while i < n && s[i] != 0x0A { i += 1 }
                out.append(Token(range: NSRange(location: start, length: i - start), kind: .comment))
            } else if slashComments && c == 0x2F && at(i + 1) == 0x2A { // /* */
                let start = i
                i += 2
                while i < n && !(s[i] == 0x2A && at(i + 1) == 0x2F) { i += 1 }
                i = min(n, i + 2)
                out.append(Token(range: NSRange(location: start, length: i - start), kind: .comment))
            } else if hashComments && c == 0x23 { // #
                let start = i
                while i < n && s[i] != 0x0A { i += 1 }
                out.append(Token(range: NSRange(location: start, length: i - start), kind: .comment))
            } else if c == 0x22 || c == 0x27 || (backticks && c == 0x60) { // " ' `
                let start = i
                let triple = tripleQuotes && at(i + 1) == c && at(i + 2) == c
                i += triple ? 3 : 1
                while i < n {
                    if s[i] == 0x5C { i += 2; continue } // backslash escape
                    if triple {
                        if s[i] == c && at(i + 1) == c && at(i + 2) == c { i += 3; break }
                    } else if s[i] == c { i += 1; break }
                    else if s[i] == 0x0A && c != 0x60 { break } // single-line strings end at newline
                    i += 1
                }
                out.append(Token(range: NSRange(location: start, length: min(i, n) - start), kind: .string))
            } else if c == 0x40, lang != .css, isIdentStart(at(i + 1)) { // @Decorator
                let start = i
                i += 1
                while i < n && isIdent(s[i]) { i += 1 }
                out.append(Token(range: NSRange(location: start, length: i - start), kind: .decorator))
            } else if isDigit(c), i == 0 || !isIdent(s[i - 1]) {
                let start = i
                while i < n && (isIdent(s[i]) || s[i] == 0x2E) { i += 1 }
                out.append(Token(range: NSRange(location: start, length: i - start), kind: .number))
            } else if isIdentStart(c) {
                let start = i
                while i < n && isIdent(s[i]) { i += 1 }
                let word = String(decoding: s[start..<i], as: UTF16.self)
                if keywords.contains(word) {
                    out.append(Token(range: NSRange(location: start, length: i - start), kind: .keyword))
                } else if let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first), word.count > 1 {
                    out.append(Token(range: NSRange(location: start, length: i - start), kind: .type))
                }
            } else {
                i += 1
            }
        }
        return out
    }

    // MARK: HTML (Angular templates included)

    private static func html(_ s: [UInt16]) -> [Token] {
        var out: [Token] = []
        var i = 0
        let n = s.count
        func at(_ k: Int) -> UInt16 { k < n ? s[k] : 0 }
        while i < n {
            if s[i] == 0x3C && at(i + 1) == 0x21 && at(i + 2) == 0x2D && at(i + 3) == 0x2D { // <!--
                let start = i
                i += 4
                while i < n && !(s[i] == 0x2D && at(i + 1) == 0x2D && at(i + 2) == 0x3E) { i += 1 }
                i = min(n, i + 3)
                out.append(Token(range: NSRange(location: start, length: i - start), kind: .comment))
            } else if s[i] == 0x3C, isIdentStart(at(i + 1)) || at(i + 1) == 0x2F { // <tag or </tag
                i += 1
                if s[i] == 0x2F { i += 1 }
                let start = i
                while i < n && (isIdent(s[i]) || s[i] == 0x2D) { i += 1 }
                out.append(Token(range: NSRange(location: start, length: i - start), kind: .tag))
                while i < n && s[i] != 0x3E { // attributes until >
                    if s[i] == 0x22 || s[i] == 0x27 {
                        let q = s[i], st = i
                        i += 1
                        while i < n && s[i] != q { i += 1 }
                        i = min(n, i + 1)
                        out.append(Token(range: NSRange(location: st, length: i - st), kind: .string))
                    } else if isIdentStart(s[i]) || s[i] == 0x5B || s[i] == 0x28 || s[i] == 0x2A || s[i] == 0x23 || s[i] == 0x40 {
                        let st = i
                        while i < n && s[i] != 0x3D && s[i] != 0x20 && s[i] != 0x3E && s[i] != 0x0A && s[i] != 0x2F { i += 1 }
                        out.append(Token(range: NSRange(location: st, length: i - st), kind: .attribute))
                    } else { i += 1 }
                }
            } else { i += 1 }
        }
        return out
    }

    private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isIdentStart(_ c: UInt16) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24 || c > 0x7F }
    private static func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) }

    private static let jsKeywords: Set<String> = ["abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "constructor", "continue", "debugger", "declare", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "get", "if", "implements", "import", "in", "instanceof", "interface", "keyof", "let", "new", "null", "of", "private", "protected", "public", "readonly", "return", "satisfies", "set", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "with", "yield"]
    private static let keywords: [CodeLanguage: Set<String>] = [
        .typescript: jsKeywords, .javascript: jsKeywords,
        .python: ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "self", "True", "try", "while", "with", "yield"],
        .kotlin: ["abstract", "annotation", "as", "break", "by", "catch", "class", "companion", "const", "constructor", "continue", "data", "do", "else", "enum", "false", "final", "finally", "for", "fun", "if", "import", "in", "init", "inline", "interface", "internal", "is", "lateinit", "null", "object", "open", "operator", "override", "package", "private", "protected", "public", "return", "sealed", "super", "suspend", "this", "throw", "true", "try", "typealias", "val", "var", "when", "while"],
        .swift: ["actor", "as", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "do", "else", "enum", "extension", "false", "fileprivate", "final", "for", "func", "guard", "if", "import", "in", "init", "internal", "is", "let", "nil", "override", "private", "protocol", "public", "return", "self", "Self", "static", "struct", "super", "switch", "throw", "throws", "true", "try", "var", "where", "while"],
        .json: ["true", "false", "null"],
        .yaml: ["true", "false", "null", "yes", "no"],
        .css: ["important"],
    ]
}
