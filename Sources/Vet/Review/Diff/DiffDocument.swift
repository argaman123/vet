import Foundation
import VetCore

/// Everything the ribbon diff shows for one file.
struct DiffDocument: Sendable {
    let change: FileChange
    let staging: SectionStaging?
    /// Shown instead of a diff (binary, too large, not UTF-8, conflict, symlink).
    let message: String?
    let language: CodeLanguage

    static let maxBytes = 5_000_000
    static let maxLines = 30_000

    static func message(_ change: FileChange, _ text: String) -> DiffDocument {
        DiffDocument(change: change, staging: nil, message: text, language: CodeLanguage(path: change.path))
    }
}
