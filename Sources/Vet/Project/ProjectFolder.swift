import CryptoKit
import Foundation

/// Where Vet keeps what belongs to one project: `<project>/.vet/`. Nothing of a project's is
/// saved anywhere else. The folder ignores itself in git (its own .gitignore), so the project's
/// files are never touched.
enum ProjectFolder {
    static func url(_ root: URL, _ name: String) -> URL {
        let dir = root.appendingPathComponent(".vet", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data("# Vet's own files for this project (review marks, notes, run configurations)\n*\n".utf8)
                .write(to: dir.appendingPathComponent(".gitignore"))
        }
        let file = dir.appendingPathComponent(name)
        migrate(root, to: file)
        return file
    }

    /// Earlier versions kept these files in ~/Library/Application Support/Vet (and Claude's review
    /// order in .git/vet): moved here the first time they're asked for.
    private static func migrate(_ root: URL, to file: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: file.path) else { return }
        let old: URL?
        switch file.lastPathComponent {
        case "reviews.json": old = legacy("reviews", root)
        case "unimportant.json": old = legacy("marks", root)
        case "notes.json": old = legacy("notes", root)
        case "run.json": old = legacy("run", root)
        case "review-plan.json": old = GitRepo.gitDir(of: root).appendingPathComponent("vet/review-plan.json")
        default: old = nil
        }
        guard let old, fm.fileExists(atPath: old.path) else { return }
        if (try? fm.copyItem(at: old, to: file)) != nil { try? fm.removeItem(at: old) }
    }

    private static func legacy(_ kind: String, _ root: URL) -> URL {
        let key = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vet/\(kind)/\(key).json")
    }
}
