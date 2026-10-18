import Foundation

/// Go to File ranking, as IntelliJ does it.
///
/// Without `/`, the query matches the file name; files whose name doesn't match fall back to the
/// whole path ("layerslightning" → layers/lightning/lightning-layer.ts), as long as the match
/// ends inside the file name, and rank after every name match.
///
/// With `/`, the part after the last `/` matches the file name and the part before it matches
/// the folders, each segment anywhere in a folder name ("lightning/layer" →
/// src/app/layers/lightning/lightning-layer.ts). The name match ranks first, then the folder
/// match, which is better the closer it is to the file.
///
/// Ties go to the shorter name, then the shallower path, then the path in order.
/// `score.matched` holds UTF-16 offsets into the whole `path` (folder and name parts alike).
/// `score.value` follows the returned order but combines name and folder scores for a `/`
/// query, so compare values only among the results of one call.
public enum FileRanking {
    public static func rank(_ query: String, paths: [String], limit: Int) -> [(path: String, score: FuzzyScore)] {
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        if q.hasPrefix("./") { q.removeFirst(2) }
        while q.hasPrefix("/") { q.removeFirst() }
        guard !q.isEmpty, limit > 0 else { return [] }

        var found: [Entry] = []
        if let slash = q.lastIndex(of: "/") {
            let dirQuery = String(q[...slash]) // keeps the trailing `/`, so it can match the file's own folder
            let nameQuery = String(q[q.index(after: slash)...])
            let dirPattern = FuzzyPattern(dirQuery, segmentsAnywhere: true)
            let namePattern = FuzzyPattern(nameQuery)
            for path in paths {
                let units = Array(path.utf16)
                let nameStart = nameOffset(units)
                let dirUnits = Array(units[..<nameStart]) // "src/app/" (with the `/`), or empty
                guard !dirUnits.isEmpty, let dir = dirPattern.match(dirUnits) else { continue }
                var nameDegree = 0, nameMatched: [Int] = []
                if !namePattern.isEmpty {
                    guard let n = namePattern.match(Array(units[nameStart...])) else { continue }
                    nameDegree = n.degree
                    nameMatched = n.matched.map { $0 + nameStart }
                }
                // IntelliJ: a folder match is worth less the further it is from the file.
                let dirDegree = dir.degree - (dirUnits.count - 1 - (dir.matched.last ?? 0))
                let nameValue = FuzzyPattern.value(degree: nameDegree, length: units.count - nameStart)
                let value = nameValue * (1 << 24) + min(max(dirDegree + (1 << 23), 0), (1 << 24) - 1)
                found.append(Entry(path: path, score: FuzzyScore(value: value, matched: dir.matched + nameMatched), units: units.count, depth: depth(units)))
            }
        } else {
            let pattern = FuzzyPattern(q)
            for path in paths {
                let units = Array(path.utf16)
                let nameStart = nameOffset(units)
                let nameLength = units.count - nameStart
                if let n = pattern.match(nameStart == 0 ? units : Array(units[nameStart...])) {
                    found.append(Entry(path: path, score: FuzzyScore(value: FuzzyPattern.value(degree: n.degree, length: nameLength),
                                                                     matched: n.matched.map { $0 + nameStart }),
                                       units: units.count, depth: depth(units)))
                } else if nameStart > 0, let p = pattern.match(units, endAtOrAfter: nameStart) {
                    let value = FuzzyPattern.value(degree: p.degree, length: nameLength) - (1 << 40)
                    found.append(Entry(path: path, score: FuzzyScore(value: value, matched: p.matched), units: units.count, depth: depth(units)))
                }
            }
        }
        found.sort()
        return found.prefix(limit).map { ($0.path, $0.score) }
    }

    struct Entry: Comparable {
        let path: String
        let score: FuzzyScore
        let units: Int
        let depth: Int

        static func < (a: Entry, b: Entry) -> Bool { // best first
            if a.score.value != b.score.value { return a.score.value > b.score.value }
            if a.depth != b.depth { return a.depth < b.depth }
            if a.units != b.units { return a.units < b.units }
            return a.path < b.path
        }
        static func == (a: Entry, b: Entry) -> Bool { a.path == b.path && a.score == b.score }
    }

    /// UTF-16 offset of the file name (just after the last `/`).
    static func nameOffset(_ units: [UInt16]) -> Int {
        (units.lastIndex(of: 0x2F) ?? -1) + 1
    }

    static func depth(_ units: [UInt16]) -> Int { units.count { $0 == 0x2F } }
}
