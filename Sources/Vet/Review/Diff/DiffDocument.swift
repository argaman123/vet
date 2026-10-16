import Foundation
import VetCore

/// Everything the ribbon diff shows for one file.
struct DiffDocument {
    let change: FileChange
    let staging: SectionStaging?
    /// Shown instead of a diff (binary, too large, not UTF-8, conflict).
    let message: String?
    let language: CodeLanguage

    static let maxBytes = 5_000_000

    static func load(_ change: FileChange, repo: GitRepo, root: URL) async -> DiffDocument {
        let language = CodeLanguage(path: change.path)
        func message(_ text: String) -> DiffDocument {
            DiffDocument(change: change, staging: nil, message: text, language: language)
        }
        if change.kind == .conflicted { return message("Merge conflict. Resolve it, then review.") }
        let head = (try? await repo.headText(change)) ?? nil
        let index = (try? await repo.indexText(change.path)) ?? nil
        let work = change.kind == .deleted ? Data() : ((try? Data(contentsOf: root.appendingPathComponent(change.path))) ?? Data())
        let all = [head, index, work].compactMap { $0 }
        if all.contains(where: { $0.count > maxBytes }) { return message("File too large to compare (> 5 MB)") }
        if all.contains(where: { $0.prefix(8000).contains(0) }) { return message("Binary file") }
        if all.contains(where: { String(data: $0, encoding: .utf8) == nil }) { return message("Not UTF-8 text") }
        let staging = SectionStaging(head: TextLines(head ?? Data()), index: TextLines(index ?? Data()), work: TextLines(work))
        return DiffDocument(change: change, staging: staging, message: nil, language: language)
    }
}
