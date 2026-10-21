import CryptoKit
import Foundation

/// A review note under a line, like a pull-request comment.
struct ReviewNote: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var path: String
    /// On the HEAD side (left) instead of the working file.
    var left: Bool
    /// 0-based file line; re-found by `lineText` when the file changes.
    var line: Int
    var lineText: String
    var text: String
    var sent = false
    var created = Date()
    /// Claude pointing at a line it thinks you must see (point_at_code); nil for your own notes.
    var fromClaude: Bool?

    var isClaude: Bool { fromClaude == true }
}

/// Notes for one project, kept in its .vet folder (which git ignores).
@MainActor
final class NoteStore {
    private(set) var notes: [ReviewNote] = []
    private let file: URL

    init(root: URL) {
        file = ProjectFolder.url(root, "notes.json")
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode([ReviewNote].self, from: data) { notes = decoded }
    }

    func upsert(_ note: ReviewNote) {
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note } else { notes.append(note) }
        save()
    }

    func delete(_ id: String) {
        notes.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(notes) { try? data.write(to: file, options: .atomic) }
    }
}
