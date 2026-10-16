import AppKit
import VetCore

/// Builds the attributed text shown in code panes: syntax colors, word highlights, fold rows.
@MainActor
enum CodeText {
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: DiffTheme.font, .foregroundColor: DiffTheme.text, .paragraphStyle: CodeTextView.paragraph, .baselineOffset: 2]
    }

    /// One pane's text: `display` picks which file lines show (and where folds go).
    static func attributed(_ lines: TextLines, _ display: [DiffLayout.DisplayLine], _ language: CodeLanguage,
                           words: [Int: [Range<Int>]] = [:], color: NSColor = DiffTheme.added) -> NSAttributedString {
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
                for r in words[l] ?? [] where r.upperBound <= length {
                    out.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.35), range: NSRange(location: at + r.lowerBound, length: r.count))
                }
            case .fold(let id, let hidden):
                var attrs = base
                attrs[.foregroundColor] = DiffTheme.lineNumber
                attrs[.vetFold] = id
                out.append(NSAttributedString(string: "   ⋯   \(hidden) unchanged lines" + newline, attributes: attrs))
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
            if value != nil { storage.addAttribute(.foregroundColor, value: DiffTheme.lineNumber, range: range) }
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

extension NSAttributedString.Key {
    /// Marks a fold row ("⋯ N unchanged lines"); its value is the fold id. Fold rows can't be edited.
    static let vetFold = NSAttributedString.Key("VetFold")
}
