import Foundation

/// Turns an edited code pane back into file bytes.
///
/// - Lines you didn't change keep their own line ending (a CRLF line stays CRLF in a mixed file).
/// - New or changed lines get the file's most common ending.
/// - A fold row stands for exact original lines and is restored byte for byte.
/// - Note rows aren't part of the file.
/// - The file keeps (or keeps lacking) its final newline.
public enum EditedText {
    public enum Row: Equatable, Sendable {
        /// A line as it now reads in the editor.
        case text(String)
        /// Original lines a fold row stands for, restored exactly.
        case original(Range<Int>)
        /// A note row (or anything else that isn't file content).
        case skip
    }

    public static func rebuild(rows: [Row], original: TextLines) -> Data {
        // Expand rows into lines, remembering which ones are original lines kept exactly.
        var texts: [String] = []
        var fixed: [String?] = [] // the exact terminator for fold-restored lines
        for row in rows {
            switch row {
            case .text(let s):
                texts.append(s)
                fixed.append(nil)
            case .original(let range):
                for i in range where i < original.count {
                    texts.append(String(original.lines[i].text))
                    fixed.append(original.lines[i].terminator)
                }
            case .skip:
                continue
            }
        }
        guard !texts.isEmpty else { return Data() }

        // Match unchanged lines to the original to recover their own terminators.
        let a = original.lines.map { Array($0.text.utf8) }, b = texts.map { Array($0.utf8) }
        let diff = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in diff {
            switch c {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var match = [Int?](repeating: nil, count: texts.count)
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if removed.contains(i) { i += 1; continue }
            if inserted.contains(j) { j += 1; continue }
            match[j] = i
            i += 1
            j += 1
        }

        let dominant = Self.dominantEnding(original)
        let finalNewline = original.lines.last.map { !$0.terminator.isEmpty } ?? true
        var out = ""
        for (k, text) in texts.enumerated() {
            var ending = fixed[k] ?? match[k].map { original.lines[$0].terminator } ?? dominant
            let isLast = k == texts.count - 1
            if isLast {
                ending = finalNewline ? (ending.isEmpty ? dominant : ending) : ""
            } else if ending.isEmpty {
                ending = dominant // a line that used to end the file now has lines after it
            }
            out += text + ending
        }
        return Data(out.utf8)
    }

    public static func dominantEnding(_ lines: TextLines) -> String {
        var crlf = 0, lf = 0
        for l in lines.lines { if l.terminator == "\r\n" { crlf += 1 } else if l.terminator == "\n" { lf += 1 } }
        return crlf > lf ? "\r\n" : "\n"
    }
}
