import CryptoKit
import Foundation
import VetCore

/// "Unimportant" marks for one repository: exact file/folder marks, glob rules, and holds.
/// A hold remembers that you unchecked a marked file, so it isn't re-staged until it changes again.
/// Saved in ~/Library/Application Support/Vet/marks/, never in the repository.
@MainActor
final class MarkStore {
    struct Data: Codable {
        var marks: [String] = []
        var rules: [String] = []
        /// path → content hash at the time you unchecked it
        var holds: [String: String] = [:]
    }

    private(set) var data = Data()
    private var rules: [GlobRule] = []
    private let file: URL

    init(root: URL) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vet/marks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Foundation.Data(root.standardizedFileURL.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        file = dir.appendingPathComponent("\(key).json")
        if let raw = try? Foundation.Data(contentsOf: file), let decoded = try? JSONDecoder().decode(Data.self, from: raw) {
            data = decoded
        }
        rules = data.rules.map(GlobRule.init)
    }

    /// Marked directly, through a marked folder above it, or by a rule.
    func isMarked(_ path: String) -> Bool {
        var p = path
        while !p.isEmpty {
            if data.marks.contains(p) { return true }
            p = (p as NSString).deletingLastPathComponent
        }
        return rules.contains { $0.matches(path) }
    }

    func isDirectlyMarked(_ path: String) -> Bool { data.marks.contains(path) }

    func mark(_ path: String) {
        guard !data.marks.contains(path) else { return }
        data.marks.append(path)
        save()
    }

    /// Removes this exact mark; marks on files inside a folder are kept.
    func unmark(_ path: String) {
        data.marks.removeAll { $0 == path }
        save()
    }

    func hold(_ path: String, hash: String) {
        data.holds[path] = hash
        save()
    }

    func releaseHold(_ path: String) {
        guard data.holds.removeValue(forKey: path) != nil else { return }
        save()
    }

    func heldHash(_ path: String) -> String? { data.holds[path] }

    private func save() {
        if let raw = try? JSONEncoder().encode(data) { try? raw.write(to: file, options: .atomic) }
    }

    /// Hash of the working file's bytes ("deleted" when it's gone).
    static func contentHash(root: URL, path: String) -> String {
        guard let bytes = try? Foundation.Data(contentsOf: root.appendingPathComponent(path)) else { return "deleted" }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
