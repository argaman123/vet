import CryptoKit
import Foundation

/// What you've reviewed, kept by Vet itself (git's index is never touched): per file, the
/// fingerprints of the sections you marked. A section's fingerprint is its content, so a mark
/// stays through edits elsewhere and lapses when that section changes.
/// Saved in the project's .vet folder (which git ignores).
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
        file = ProjectFolder.url(root, "reviews.json")
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

/// Each changed file's sections as last computed, with the key they were computed for (see
/// GitRepo.unitKeys), kept in the project's .vet folder: opening Vet shows your review marks at
/// once, and only files that changed since are diffed again.
@MainActor
final class UnitsCache {
    private struct Entry: Codable { var key: String; var units: [String] }
    private var entries: [String: Entry] = [:]
    private let file: URL

    init(root: URL) {
        file = ProjectFolder.url(root, "units.json")
        if let raw = try? Foundation.Data(contentsOf: file), let decoded = try? JSONDecoder().decode([String: Entry].self, from: raw) { entries = decoded }
    }

    func units(_ path: String, key: String) -> [String]? { entries[path].flatMap { $0.key == key ? $0.units : nil } }
    func set(_ path: String, key: String, units: [String]) { entries[path] = Entry(key: key, units: units) }

    /// Writes the cache, keeping only the files still changed.
    func save(keeping paths: Set<String>) {
        entries = entries.filter { paths.contains($0.key) }
        if let raw = try? JSONEncoder().encode(entries) { try? raw.write(to: file, options: .atomic) }
    }
}
