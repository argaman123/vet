import Foundation

/// How well a query matched a candidate. Higher is better.
public struct FuzzyScore: Sendable, Equatable, Comparable {
    /// The match quality, then a small tie-break that prefers shorter candidates.
    public let value: Int
    /// UTF-16 offsets in the candidate of every matched character, ascending (for highlighting).
    public let matched: [Int]

    public init(value: Int, matched: [Int]) {
        self.value = value
        self.matched = matched
    }

    public static func < (a: FuzzyScore, b: FuzzyScore) -> Bool {
        a.value != b.value ? a.value < b.value : a.matched.lexicographicallyPrecedes(b.matched)
    }
}

/// Fuzzy matching as IntelliJ's Go to File / Search Everywhere does it (MinusculeMatcher):
/// - The first fragment of the query can start anywhere; every later fragment starts at a word
///   start: after a separator, a camel hump ("LoLa" → LoopLayer, loop-layer), or a digit.
/// - Case-insensitive, but an uppercase query letter must land on an uppercase letter or a word
///   start, and in a mixed-case query ("LoLa") lowercase letters only continue a fragment.
/// - A fragment that starts mid-word needs at least 3 characters before the query may skip ahead.
/// - A space in the query means "a new word starts here"; `*` means "anything"; `-` and `_` match
///   any of `- _ space` or a camel hump; when the query has a dot, a skip can't jump over a dot.
/// - Ranking: a match at the start of the candidate beats one at a word start, which beats one
///   mid-word; then a contiguous prefix of the whole query, uppercase letters that match uppercase,
///   fewer fragments and fewer skipped words; shorter candidates break ties.
public enum FuzzyMatcher {
    /// Nil when the query doesn't match (an empty query matches nothing).
    public static func score(_ query: String, _ candidate: String) -> FuzzyScore? {
        FuzzyPattern(query).score(candidate)
    }
}

/// A compiled query; reuse it to score many candidates.
public struct FuzzyPattern: Sendable {
    struct Token: Sendable {
        var unit: UInt16
        var lower: UInt16
        var isUpper = false
        var isLower = false
        var isAlnum = false
        /// `-` or `_`: matches any of `- _ space`, or nothing at a word boundary.
        var optional = false
        /// May start a fragment anywhere (the first token, or after `*`).
        var anywhere = false
        /// Must land on a word start (after a space or an optional separator).
        var mustWordStart = false
        /// The query character before it is a word separator.
        var afterSeparator = false
        /// The query character before it is a wildcard (space or `*`).
        var afterWildcard = false
        var afterDot = false
    }

    let tokens: [Token]
    let mixedCase: Bool
    let hasDots: Bool
    let requiredCount: Int

    public var isEmpty: Bool { tokens.isEmpty }

    /// - Parameter segmentsAnywhere: every `/`-separated part may start anywhere in its segment
    ///   (used for directory parts: IntelliJ turns `a/b` into `*a*/*b`).
    public init(_ query: String, segmentsAnywhere: Bool = false) {
        let units = Array(query.trimmingCharacters(in: .whitespacesAndNewlines).utf16)
        var tokens: [Token] = []
        var seenLower = false, seenUpperAfterFirst = false, hasDots = false
        var pendingWordStart = false, pendingAnywhere = false
        var prev: UInt16? = nil
        for u in units {
            defer { prev = u }
            if u == 0x20 || u == 0x09 { pendingWordStart = true; continue } // space: a word starts next
            if u == 0x2A { pendingAnywhere = true; continue } // *
            let c = CharClass(u)
            var t = Token(unit: u, lower: c.lower)
            t.isUpper = c.isUpper
            t.isLower = c.isLower
            t.isAlnum = c.isAlnum
            t.anywhere = tokens.isEmpty || pendingAnywhere || (segmentsAnywhere && prev == 0x2F)
            t.mustWordStart = pendingWordStart || (tokens.last?.optional ?? false)
            t.afterWildcard = prev == 0x20 || prev == 0x09 || prev == 0x2A
            t.afterSeparator = prev.map(Self.isWordSeparator) ?? false
            t.afterDot = prev == 0x2E
            t.optional = (u == 0x2D || u == 0x5F) && !tokens.isEmpty // a leading `_` or `-` is literal
            if c.isLower { seenLower = true }
            if c.isUpper && !tokens.isEmpty && !t.afterWildcard { seenUpperAfterFirst = true }
            if u == 0x2E { hasDots = true }
            tokens.append(t)
            pendingWordStart = false
            pendingAnywhere = false
        }
        self.tokens = tokens
        mixedCase = seenLower && seenUpperAfterFirst
        self.hasDots = hasDots
        requiredCount = tokens.count { !$0.optional }
    }

    static func isWordSeparator(_ u: UInt16) -> Bool {
        u == 0x20 || u == 0x09 || u == 0x5F || u == 0x2D || u == 0x3A || u == 0x2B || u == 0x2E // space tab _ - : + .
    }

    static func isLooseSeparator(_ u: UInt16) -> Bool { u == 0x2D || u == 0x5F || u == 0x20 } // - _ space

    public func score(_ candidate: String) -> FuzzyScore? {
        guard let m = match(Array(candidate.utf16)) else { return nil }
        return FuzzyScore(value: Self.value(degree: m.degree, length: candidate.utf16.count), matched: m.matched)
    }

    /// Folds the length tie-break into a score value: degree always dominates.
    static func value(degree: Int, length: Int) -> Int { degree * 128 - min(length, 127) }

    // MARK: Matching

    static let impossible = Int.min / 4

    /// The best alignment of the query in `c` (UTF-16 units), as a raw degree and matched offsets.
    /// - Parameter endAtOrAfter: the last matched character must be at or after this offset.
    func match(_ c: [UInt16], endAtOrAfter: Int = 0) -> (degree: Int, matched: [Int])? {
        let n = tokens.count, m = c.count
        guard n > 0, m >= requiredCount, m > endAtOrAfter || endAtOrAfter == 0 else { return nil }
        // Quick reject: every required character must appear in order.
        var k = 0
        for u in c where k < n {
            while k < n && tokens[k].optional { k += 1 }
            guard k < n else { break }
            if Self.equals(tokens[k], u) { k += 1 }
        }
        while k < n && tokens[k].optional { k += 1 }
        guard k == n else { return nil }

        // Per-character facts about the candidate.
        var lower = [UInt16](repeating: 0, count: m)
        var flags = [UInt8](repeating: 0, count: m) // 1 upper, 2 lower, 4 alnum, 8 digit, 16 ideograph
        for j in 0..<m {
            let cc = CharClass(c[j])
            lower[j] = cc.lower
            flags[j] = (cc.isUpper ? 1 : 0) | (cc.isLower ? 2 : 0) | (cc.isAlnum ? 4 : 0) | (cc.isDigit ? 8 : 0) | (cc.isIdeograph ? 16 : 0)
        }
        var ws = [Bool](repeating: false, count: m) // word starts (IntelliJ's NameUtilCore.isWordStart)
        for j in 0..<m {
            let f = flags[j]
            if f & 1 != 0 {
                if j > 0 && flags[j - 1] & 1 != 0 { ws[j] = j + 1 < m && flags[j + 1] & 2 != 0 } else { ws[j] = true }
            } else if f & 8 != 0 {
                ws[j] = true
            } else if f & 4 == 0 {
                ws[j] = false
            } else if f & 16 != 0 {
                ws[j] = true
            } else {
                ws[j] = j == 0 || flags[j - 1] & 4 == 0
            }
        }
        var humps = [Int](repeating: 0, count: m + 1) // humps[k] = word starts in 0..<k
        for j in 0..<m { humps[j + 1] = humps[j] + (ws[j] ? 1 : 0) }

        // DP over (token, position, state). State 0: free; 1, 2: inside a fragment that started
        // mid-word with 1 or 2 characters so far (it can't be left for a skip yet).
        let width = m * 3
        var prevL = [Int](repeating: Self.impossible, count: width)
        var curM = [Int](repeating: Self.impossible, count: width)
        var curL = [Int](repeating: Self.impossible, count: width)
        var back = [Int32](repeating: -1, count: n * width) // (prevJ + 1) * 3 + prevState
        var skipped = [Bool](repeating: false, count: n * width)

        for i in 0..<n {
            let t = tokens[i]
            for x in 0..<width { curM[x] = Self.impossible }
            let dotRule = hasDots && !t.afterDot && !t.afterWildcard
            // Best `prevL[pj][free] + 10 * humps[pj + 1]` over pj <= j - 2 (a skip from pj to j).
            var runBest = Self.impossible, runArg = -1
            for j in 0..<m {
                if i > 0 && j >= 2 {
                    if dotRule && c[j - 1] == 0x2E {
                        runBest = Self.impossible; runArg = -1 // a skip can't jump over this dot
                    } else {
                        let pj = j - 2
                        let v = prevL[pj * 3]
                        if v > Self.impossible {
                            let cand = v + 10 * humps[pj + 1]
                            if cand > runBest { runBest = cand; runArg = pj }
                        }
                    }
                }
                guard lower[j] == t.lower || (t.optional && Self.isLooseSeparator(c[j])) else { continue }
                let hump = ws[j]
                let isMiddle = flags[j] & 4 != 0 && !hump
                let exact = c[j] == t.unit
                let wordOK = hump || !t.isAlnum
                if t.mustWordStart && !wordOK { continue }
                let upperOK = !t.isUpper || !mixedCase || flags[j] & 1 != 0 || hump
                func charScore(afterGap: Bool) -> Int {
                    if afterGap && hump && t.isLower { return -10 } // a hump the query didn't ask for
                    if exact { return t.isUpper ? 50 : (hump ? 1 : 0) }
                    return hump || t.optional ? -1 : 0
                }
                let base = j * 3
                if i == 0 {
                    guard upperOK else { continue }
                    var v = charScore(afterGap: false) - 1
                    if j == 0 { v += 10_001 }
                    if j == 0 || (hump && !ws[j - 1]) { v += 1000 }
                    let s = isMiddle ? 1 : 0
                    curM[base + s] = v
                    back[base + s] = 0
                    continue
                }
                // Continue the fragment from j - 1.
                if j >= 1 {
                    let pb = (j - 1) * 3
                    for s in 0..<3 where prevL[pb + s] > Self.impossible {
                        let ns = s == 1 ? 2 : 0
                        let v = prevL[pb + s] + charScore(afterGap: false)
                        if v > curM[base + ns] {
                            curM[base + ns] = v
                            back[i * width + base + ns] = Int32(j * 3 + s) // (pj + 1) * 3 + s with pj = j - 1
                        }
                    }
                }
                // Start a new fragment after a skip.
                if runArg >= 0 && upperOK {
                    let lowerStartOK = !(mixedCase && t.isLower && !t.afterSeparator)
                    if t.anywhere || (wordOK && lowerStartOK) {
                        let ns = t.anywhere && isMiddle ? 1 : 0
                        let v = runBest - 10 * humps[j] + charScore(afterGap: true) - 1
                        if v > curM[base + ns] {
                            curM[base + ns] = v
                            back[i * width + base + ns] = Int32((runArg + 1) * 3)
                        }
                    }
                }
            }
            // A `-` or `_` may also match nothing: carry the previous layer over.
            for x in 0..<width {
                curL[x] = curM[x]
                if t.optional, i > 0, prevL[x] > Self.impossible, prevL[x] - 2 > curL[x] {
                    curL[x] = prevL[x] - 2
                    skipped[i * width + x] = true
                }
            }
            swap(&prevL, &curL)
        }

        // Best end.
        var best = Self.impossible, bestX = -1
        for j in max(0, endAtOrAfter)..<m {
            for s in 0..<3 {
                let v = prevL[j * 3 + s]
                guard v > Self.impossible else { continue }
                let total = v + (j == m - 1 ? 1 : 0)
                if total > best { best = total; bestX = j * 3 + s }
            }
        }
        guard bestX >= 0 else { return nil }

        // Walk back.
        var matched: [Int] = []
        matched.reserveCapacity(n)
        var x = bestX, i = n - 1, anySkipped = false
        while i >= 0 {
            if skipped[i * width + x] { anySkipped = true; i -= 1; continue }
            matched.append(x / 3)
            let code = Int(back[i * width + x])
            let pj = code / 3 - 1, ps = code % 3
            i -= 1
            if pj < 0 { break }
            x = pj * 3 + ps
        }
        matched.reverse()
        var degree = best
        // A contiguous case-insensitive prefix of the whole query is its own tier (IntelliJ ranks
        // exact prefixes first).
        if !anySkipped, matched.count == n, matched.first == 0, matched.last == n - 1 { degree += 5000 }
        return (degree, matched)
    }

    @inline(__always) static func equals(_ t: Token, _ u: UInt16) -> Bool {
        if t.optional && isLooseSeparator(u) { return true }
        if u == t.unit { return true }
        return CharClass(u).lower == t.lower
    }
}

/// Case and kind of one UTF-16 unit (ASCII fast path; surrogates count as letters).
struct CharClass {
    var lower: UInt16
    var isUpper = false
    var isLower = false
    var isAlnum = false
    var isDigit = false
    var isIdeograph = false

    @inline(__always) init(_ u: UInt16) {
        if u < 0x80 {
            switch u {
            case 0x41...0x5A: lower = u + 32; isUpper = true; isAlnum = true
            case 0x61...0x7A: lower = u; isLower = true; isAlnum = true
            case 0x30...0x39: lower = u; isDigit = true; isAlnum = true
            default: lower = u
            }
            return
        }
        lower = u
        guard let scalar = Unicode.Scalar(u) else { isAlnum = true; return } // half of a surrogate pair
        let p = scalar.properties
        isUpper = p.isUppercase
        isLower = p.isLowercase
        isDigit = p.numericType == .decimal
        isAlnum = p.isAlphabetic || isDigit
        isIdeograph = p.isIdeographic
        if isUpper {
            let l = p.lowercaseMapping.utf16
            if l.count == 1, let first = l.first { lower = first }
        }
    }
}
