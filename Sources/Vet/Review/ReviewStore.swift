import CryptoKit
import Foundation

/// What you've reviewed, kept by Vet itself (git's index is never touched): per file, the
/// fingerprints of the sections you marked. A section's fingerprint is its content, so a mark
/// stays through edits elsewhere and lapses when that section changes.
/// Saved in ~/Library/Application Support/Vet/reviews/, never in the repository.
@MainActor
final class ReviewStore {
    private struct Data: Codable {
        var version = 1
        var files: [String: Set<String>] = [:]
    }

    private var data = Data()
    private let file: URL
    /// No store existed for this project yet (the first open seeds it from git's staging).
    let isNew: Bool
    private var pendingSave: DispatchWorkItem?

    init(root: URL) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vet/reviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Foundation.Data(root.standardizedFileURL.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        file = dir.appendingPathComponent("\(key).json")
        if let raw = try? Foundation.Data(contentsOf: file), let decoded = try? JSONDecoder().decode(Data.self, from: raw) {
            data = decoded
            isNew = false
        } else {
            isNew = true
        }
    }

    func isReviewed(_ path: String, _ unit: String) -> Bool { data.files[path]?.contains(unit) ?? false }

    /// How many of `units` (a file's current sections) are reviewed.
    func reviewedCount(_ path: String, of units: [String]) -> Int {
        guard let marked = data.files[path], !marked.isEmpty else { return 0 }
        return units.reduce(0) { $0 + (marked.contains($1) ? 1 : 0) }
    }

    func set(_ path: String, _ units: [String], reviewed: Bool) {
        var marked = data.files[path] ?? []
        if reviewed { marked.formUnion(units) } else { marked.subtract(units) }
        data.files[path] = marked.isEmpty ? nil : marked
        scheduleSave()
    }

    /// Forgets marks on sections a file no longer has (they can't come back unchanged anyway,
    /// and the file stays small).
    func prune(_ path: String, keeping units: [String]) {
        guard let marked = data.files[path] else { return }
        let kept = marked.intersection(units)
        if kept.count != marked.count { data.files[path] = kept.isEmpty ? nil : kept; scheduleSave() }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        if let raw = try? JSONEncoder().encode(data) { try? raw.write(to: file, options: .atomic) }
    }
}
