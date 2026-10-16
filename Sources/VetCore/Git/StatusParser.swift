import Foundation

/// Parses `git status --porcelain=v2 -z` output.
public enum StatusParser {
    public static func parse(_ data: Data) -> [FileChange] {
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        var result: [FileChange] = []
        var i = 0
        while i < records.count {
            let r = records[i]
            i += 1
            guard let type = r.first else { continue }
            switch type {
            case "1":
                // 1 XY sub mH mI mW hH hI path
                let f = fields(r, count: 9)
                guard f.count == 9 else { continue }
                result.append(FileChange(path: f[8], kind: kind(xy: f[1]), stage: stage(xy: f[1]),
                                         modeIndex: indexMode(f[4], fallback: f[3]), modeWork: f[5]))
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path \0 origPath
                let f = fields(r, count: 10)
                guard f.count == 10 else { continue }
                let orig = i < records.count ? records[i] : nil
                i += 1
                let xy = f[1]
                let copied = xy.contains("C")
                result.append(FileChange(path: f[9], origPath: copied ? nil : orig,
                                         kind: copied ? .added : .renamed, stage: stage(xy: xy),
                                         modeIndex: indexMode(f[4], fallback: f[3]), modeWork: f[5]))
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let f = fields(r, count: 11)
                guard f.count == 11 else { continue }
                result.append(FileChange(path: f[10], kind: .conflicted, stage: .unstaged,
                                         modeIndex: f[4], modeWork: f[6]))
            case "?":
                result.append(FileChange(path: String(r.dropFirst(2)), kind: .untracked, stage: .unstaged))
            default:
                continue // "!" ignored, "#" headers
            }
        }
        return result
    }

    /// Splits off the first `count - 1` space-separated fields; the last field is the rest (paths may contain spaces).
    private static func fields(_ r: String, count: Int) -> [String] {
        r.split(separator: " ", maxSplits: count - 1, omittingEmptySubsequences: false).map(String.init)
    }

    private static func indexMode(_ mI: String, fallback: String) -> String {
        mI == "000000" ? (fallback == "000000" ? "100644" : fallback) : mI
    }

    static func stage(xy: String) -> StageState {
        let x = xy.first ?? ".", y = xy.dropFirst().first ?? "."
        switch (x == ".", y == ".") {
        case (true, _): return .unstaged
        case (false, true): return .staged
        case (false, false): return .partial
        }
    }

    static func kind(xy: String) -> ChangeKind {
        let x = xy.first ?? ".", y = xy.dropFirst().first ?? "."
        if y == "D" || x == "D" { return x == "A" ? .added : .deleted }
        if x == "A" || y == "A" { return .added }
        return .modified
    }
}
