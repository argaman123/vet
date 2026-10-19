import Foundation

/// The order Claude suggests for reviewing the current changes, with a summary per file and notes
/// on key functions. Set through Vet's MCP tool; kept in `.git/vet/review-plan.json` (never committed).
struct ReviewPlan: Codable, Equatable {
    struct Note: Codable, Equatable { var line: Int?; var symbol: String?; var text: String }
    struct File: Codable, Equatable { var path: String; var summary: String; var notes: [Note]? }
    var overview: String?
    var files: [File]
    var created: Date = Date()

    func file(_ path: String) -> File? { files.first { $0.path == path } }
    func index(of path: String) -> Int? { files.firstIndex { $0.path == path } }

    static func url(gitDir: URL) -> URL { gitDir.appendingPathComponent("vet/review-plan.json") }

    static func load(gitDir: URL) -> ReviewPlan? {
        guard let data = try? Data(contentsOf: url(gitDir: gitDir)) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(ReviewPlan.self, from: data)
    }

    func save(gitDir: URL) {
        let u = Self.url(gitDir: gitDir)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(self).write(to: u, options: .atomic)
    }
}
