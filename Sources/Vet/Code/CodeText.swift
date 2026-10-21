import AppKit
import SwiftUI
import VetCore

/// Builds the attributed text shown in code panes: syntax colors, word highlights, fold rows.
@MainActor
enum CodeText {
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: DiffTheme.font, .foregroundColor: DiffTheme.text, .paragraphStyle: CodeTextView.paragraph]
    }

    /// One pane's text: `display` picks which file lines show (and where folds go).
    static func attributed(_ lines: TextLines, _ display: [DiffLayout.DisplayLine], _ language: CodeLanguage,
                           words: [Int: [Range<Int>]] = [:], color: NSColor = DiffTheme.added,
                           wordColor: [Int: NSColor] = [:], foldStarts: [Int: Int] = [:]) -> NSAttributedString {
        let full = lines.joinedString()
        let tokens = Highlighter.tokens(full, language: language)
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        var offset = 0
        for l in lines.lines {
            starts.append(offset)
            offset += l.text.utf16.count + l.terminator.utf16.count
        }
        let base = baseAttributes
        let out = NSMutableAttributedString()
        out.beginEditing()
        for (index, d) in display.enumerated() {
            let at = out.length
            let newline = index == display.count - 1 ? "" : "\n"
            switch d {
            case .code(let l):
                let line = String(lines.lines[l].text)
                out.append(NSAttributedString(string: line + newline, attributes: base))
                let start = starts[l], length = line.utf16.count
                var k = firstToken(tokens, endingAfter: start)
                while k < tokens.count, tokens[k].range.location < start + length {
                    let t = tokens[k]
                    let lo = max(t.range.location, start), hi = min(t.range.location + t.range.length, start + length)
                    if hi > lo { out.addAttribute(.foregroundColor, value: DiffTheme.token(t.kind), range: NSRange(location: at + lo - start, length: hi - lo)) }
                    k += 1
                }
                // Drawn by the pane as row-high marks (a text background would hug the glyphs, off-center).
                for r in words[l] ?? [] where r.upperBound <= length {
                    out.addAttribute(.vetWordHighlight, value: wordColor[l] ?? color, range: NSRange(location: at + r.lowerBound, length: r.count))
                }
            case .note(let id, _):
                // Blank space that the note card covers; not part of the file and not editable.
                var attrs = base
                attrs[.vetNote] = id
                out.append(NSAttributedString(string: " " + newline, attributes: attrs))
            case .fold(let id, let hidden):
                // The row keeps its label as text (so it has a width and reads back), but the pane
                // draws it: chevron and label centered in the row like a button.
                var attrs = base
                attrs[.foregroundColor] = NSColor.clear
                attrs[.vetFold] = id
                let scope = foldStarts[id].map { ScopeLabel.chain(lines, at: $0) } ?? ""
                let label = id < 0 ? "Reviewed  ·  \(hidden) line\(hidden == 1 ? "" : "s")"
                    : scope.isEmpty ? "\(hidden) unchanged lines" : "\(scope)  ·  \(hidden) lines"
                attrs[.vetFoldLabel] = label
                attrs[.font] = NSFont.systemFont(ofSize: 11)
                out.append(NSAttributedString(string: "      " + label + newline, attributes: attrs))
            }
        }
        out.endEditing()
        return out
    }

    /// Re-colors text that's being edited (whole-file pass; milliseconds for thousands of lines).
    static func rehighlight(_ storage: NSTextStorage, language: CodeLanguage) {
        let text = storage.string
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: DiffTheme.text, range: all)
        for t in Highlighter.tokens(text, language: language) where NSMaxRange(t.range) <= storage.length {
            if storage.attribute(.vetFold, at: t.range.location, effectiveRange: nil) == nil {
                storage.addAttribute(.foregroundColor, value: DiffTheme.token(t.kind), range: t.range)
            }
        }
        storage.enumerateAttribute(.vetFold, in: all) { value, range, _ in
            if value != nil { storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range) }
        }
        storage.endEditing()
    }

    static func firstToken(_ tokens: [Highlighter.Token], endingAfter offset: Int) -> Int {
        var lo = 0, hi = tokens.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if tokens[mid].range.location + tokens[mid].range.length <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

/// Where a line sits: the enclosing class and function names, outermost first ("LightningLayer › hover()").
/// Indentation-based, so it works for any brace or indent language without a language server.
enum ScopeLabel {
    static func chain(_ lines: TextLines, at index: Int) -> String {
        guard index < lines.count else { return "" }
        func indent(_ s: Substring) -> Int { s.prefix { $0 == " " || $0 == "\t" }.count }
        var limit = Int.max, names: [String] = []
        var i = index
        // The first non-blank line at or after the fold gives the starting depth.
        while i < lines.count, lines.lines[i].text.trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
        if i < lines.count { limit = indent(lines.lines[i].text) }
        var j = min(index, lines.count) - 1
        while j >= 0, limit > 0, names.count < 4 {
            let t = lines.lines[j].text
            if !t.trimmingCharacters(in: .whitespaces).isEmpty, indent(t) < limit {
                limit = indent(t)
                if let name = declaredName(String(t)) { names.append(name) }
            }
            j -= 1
        }
        return names.reversed().joined(separator: " › ")
    }

    private static let keywords: Set<String> = ["if", "for", "while", "switch", "catch", "return", "else", "do", "try", "when", "with"]

    static func declaredName(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        if let m = t.firstMatch(of: /(?:class|interface|enum|object|struct|protocol|extension|trait|impl)\s+([A-Za-z_][\w]*)/) { return String(m.1) }
        if let m = t.firstMatch(of: /(?:def|fun|func|function)\s+([A-Za-z_][\w]*)/) { return String(m.1) + "()" }
        if let m = t.firstMatch(of: /^(?:(?:public|private|protected|static|readonly|override|async|abstract|export|get|set)\s+)*([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\(/),
           !keywords.contains(String(m.1)) { return String(m.1) + "()" }
        return nil
    }
}

extension NSAttributedString.Key {
    /// Marks a fold row ("⋯ N unchanged lines"); its value is the fold id. Fold rows can't be edited.
    static let vetFold = NSAttributedString.Key("VetFold")
    /// Marks the rows reserved for a review note card; their value is the note id.
    static let vetNote = NSAttributedString.Key("VetNote")
    /// Marks a HEAD line shown in the unified diff: read-only and not part of the file.
    static let vetRemoved = NSAttributedString.Key("VetRemoved")
    /// A fold row's label (the pane draws it centered in the row).
    static let vetFoldLabel = NSAttributedString.Key("VetFoldLabel")
    /// A changed word's mark color (the pane draws it the full height of the row).
    static let vetWordHighlight = NSAttributedString.Key("VetWordHighlight")
}

extension CodeText {
    /// One line of code for SwiftUI lists (usages, Find in Files, Search Everywhere): the editor's
    /// syntax colors, with `matches` (UTF-16 ranges) on IntelliJ's search highlight. Text before
    /// `from` is left out (indentation, or a long line's head, then marked with "…").
    static func line(_ text: String, language: CodeLanguage, matches: [Range<Int>] = [], from: Int = 0, ellipsis: Bool = false) -> AttributedString {
        let ns = text as NSString
        let start = min(max(0, from), ns.length)
        var colors = [NSColor?](repeating: nil, count: ns.length)
        for t in Highlighter.tokens(text, language: language) {
            for i in t.range.location..<min(NSMaxRange(t.range), ns.length) { colors[i] = DiffTheme.token(t.kind) }
        }
        var hit = [Bool](repeating: false, count: ns.length)
        for r in matches { for i in max(0, r.lowerBound)..<min(r.upperBound, ns.length) { hit[i] = true } }
        var out = AttributedString()
        if ellipsis {
            var dots = AttributedString("…")
            dots.foregroundColor = Color(nsColor: DiffTheme.foldLabel)
            out += dots
        }
        var i = start
        while i < ns.length {
            var j = i + 1
            while j < ns.length, colors[j] == colors[i], hit[j] == hit[i] { j += 1 }
            // Don't split a surrogate pair.
            if j < ns.length, UTF16.isTrailSurrogate(ns.character(at: j)) { j += 1 }
            var piece = AttributedString(ns.substring(with: NSRange(location: i, length: j - i)))
            piece.foregroundColor = Color(nsColor: colors[i] ?? DiffTheme.text)
            if hit[i] {
                piece.backgroundColor = Color(nsColor: DiffTheme.searchMatch)
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            out += piece
            i = j
        }
        return out
    }

    /// Several lines in the editor's syntax colors, highlighted as one block (so a comment or a
    /// string that spans lines keeps its color), one AttributedString per line. `semantic` adds
    /// the language server's name colors (tokens of the whole file, whose line `firstLine` is the
    /// block's first), as the editor shows them.
    static func lines(_ lines: [String], language: CodeLanguage, semantic: [SemanticToken] = [], firstLine: Int = 0) -> [AttributedString] {
        let block = lines.joined(separator: "\n")
        let tokens = Highlighter.tokens(block, language: language)
        var out: [AttributedString] = []
        var start = 0, k = 0
        for line in lines {
            let length = line.utf16.count
            let ns = line as NSString
            var colors = [NSColor?](repeating: nil, count: length)
            while k < tokens.count, NSMaxRange(tokens[k].range) <= start { k += 1 }
            var j = k
            while j < tokens.count, tokens[j].range.location < start + length {
                let t = tokens[j]
                for i in max(t.range.location, start)..<min(NSMaxRange(t.range), start + length) { colors[i - start] = DiffTheme.token(t.kind) }
                j += 1
            }
            let fileLine = firstLine + out.count
            for t in semantic where t.line == fileLine && t.character + t.length <= length {
                guard let color = DiffTheme.semantic(t.type, modifiers: t.modifiers) else { continue }
                for i in t.character..<(t.character + t.length) { colors[i] = color }
            }
            var row = AttributedString()
            var i = 0
            while i < length {
                var e = i + 1
                while e < length, colors[e] == colors[i] { e += 1 }
                if e < length, UTF16.isTrailSurrogate(ns.character(at: e)) { e += 1 }
                var piece = AttributedString(ns.substring(with: NSRange(location: i, length: e - i)))
                piece.foregroundColor = Color(nsColor: colors[i] ?? DiffTheme.text)
                row += piece
                i = e
            }
            out.append(row)
            start += length + 1
        }
        return out
    }
}
