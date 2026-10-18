import Foundation

/// One Search Everywhere result.
public struct SearchItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case file, symbol, action, text }

    /// Where choosing the item goes. Lines and characters are 0-based, as in LSP and
    /// `FilesModel.show(_:line:character:)`; characters are UTF-16 offsets.
    public enum Target: Hashable, Sendable {
        /// A project file (path relative to the root); `line` is set when the query ended in `:N`.
        case file(path: String, line: Int?)
        case location(url: URL, line: Int, character: Int)
        case action(id: String)
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String
    /// UTF-16 offsets in `title` to highlight.
    public let matched: [Int]
    public let target: Target

    public init(id: String, kind: Kind, title: String, detail: String, matched: [Int], target: Target) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.matched = matched
        self.target = target
    }
}

/// Search Everywhere: files, classes and symbols, actions and text for one query, each group
/// shown as soon as it's ready. The providers are injected so the engine can be tested; the app's
/// `SearchEverywhere` wires them to the project, the language servers and `TextSearch`.
@MainActor
public final class SearchEverywhereEngine {
    public typealias Symbol = (name: String, container: String?, url: URL, line: Int, character: Int, kind: Int)
    public typealias Action = (id: String, title: String)

    public nonisolated static let fileLimit = 8, symbolLimit = 8, actionLimit = 5, textLimit = 8
    /// Text search starts at this many characters (fewer match nearly every line).
    public nonisolated static let textMinimum = 3

    let root: URL
    let debounce: Duration
    let files: @MainActor () -> [String]
    let symbols: @MainActor (String) async -> [Symbol]
    let actions: @MainActor () -> [Action]
    let text: @Sendable (String) -> AsyncThrowingStream<[FindMatch], Error>
    private var current: Task<Void, Never>?

    public init(root: URL, debounce: Duration = .milliseconds(120),
                files: @escaping @MainActor () -> [String],
                symbols: @escaping @MainActor (String) async -> [Symbol],
                actions: @escaping @MainActor () -> [Action],
                text: @escaping @Sendable (String) -> AsyncThrowingStream<[FindMatch], Error>) {
        self.root = root
        self.debounce = debounce
        self.files = files
        self.symbols = symbols
        self.actions = actions
        self.text = text
    }

    /// Debounced; each new call cancels the previous query's work. Every element is the whole
    /// list so far, grouped Files, Classes & Symbols, Actions, Text, whichever finished first.
    /// An empty query yields `[]` at once. The stream finishes when every group is in.
    public func results(for query: String) -> AsyncStream<[SearchItem]> {
        current?.cancel()
        let (stream, continuation) = AsyncStream.makeStream(of: [SearchItem].self, bufferingPolicy: .bufferingNewest(1))
        let task = Task { // holds the engine only until this query is done
            await self.run(query, continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        current = task
        return stream
    }

    private func run(_ raw: String, _ continuation: AsyncStream<[SearchItem]>.Continuation) async {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { continuation.yield([]); return }
        do { try await Task.sleep(for: debounce) } catch { return }
        let (fileQuery, line) = Self.splitLine(query)
        let paths = files(), actionList = actions()
        let root = root, symbols = symbols, text = text
        var groups: [SearchItem.Kind: [SearchItem]] = [:]
        var shown: [SearchItem]? = nil
        await withTaskGroup(of: (SearchItem.Kind, [SearchItem]).self) { group in
            group.addTask { (.file, Self.fileItems(fileQuery, line: line, paths: paths)) }
            group.addTask { (.action, Self.actionItems(query, actionList)) }
            group.addTask { (.symbol, Self.symbolItems(query, await symbols(query), root: root)) }
            if query.count >= Self.textMinimum {
                group.addTask { (.text, await Self.textItems(text(query), root: root)) }
            }
            for await (kind, items) in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                groups[kind] = items
                let all = [SearchItem.Kind.file, .symbol, .action, .text].flatMap { groups[$0] ?? [] }
                if all != shown { // an empty group changes nothing; the first answer always shows
                    continuation.yield(all)
                    shown = all
                }
            }
        }
    }

    /// "loop-layer.ts:42" → ("loop-layer.ts", 41).
    nonisolated static func splitLine(_ query: String) -> (String, Int?) {
        guard let colon = query.lastIndex(of: ":") else { return (query, nil) }
        let digits = query[query.index(after: colon)...]
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let n = Int(digits), n > 0, colon != query.startIndex else { return (query, nil) }
        return (String(query[..<colon]), n - 1)
    }

    nonisolated static func fileItems(_ query: String, line: Int?, paths: [String]) -> [SearchItem] {
        FileRanking.rank(query, paths: paths, limit: fileLimit).map { path, score in
            let slash = path.lastIndex(of: "/")
            let name = slash.map { String(path[path.index(after: $0)...]) } ?? path
            let folder = slash.map { String(path[..<$0]) } ?? ""
            let nameStart = path.utf16.count - name.utf16.count
            return SearchItem(id: "file:\(path)", kind: .file, title: name, detail: folder,
                              matched: score.matched.filter { $0 >= nameStart }.map { $0 - nameStart },
                              target: .file(path: path, line: line))
        }
    }

    nonisolated static func actionItems(_ query: String, _ actions: [Action]) -> [SearchItem] {
        let pattern = FuzzyPattern(query)
        var scored: [(action: Action, score: FuzzyScore)] = []
        for a in actions {
            if let s = pattern.score(a.title) { scored.append((a, s)) }
        }
        scored.sort { x, y in x.score.value != y.score.value ? x.score.value > y.score.value : x.action.title < y.action.title }
        return scored.prefix(actionLimit).map { a, score in
            SearchItem(id: "action:\(a.id)", kind: .action, title: a.title, detail: "", matched: score.matched, target: .action(id: a.id))
        }
    }

    private struct RankedSymbol {
        let symbol: Symbol
        let score: FuzzyScore?
        let order: Int
        let id: String
        let isType: Bool

        /// Better first: matched by score (types first on a tie), then the unmatched in server order.
        static func before(_ a: RankedSymbol, _ b: RankedSymbol) -> Bool {
            switch (a.score, b.score) {
            case let (x?, y?):
                if x.value != y.value { return x.value > y.value }
                if a.isType != b.isType { return a.isType }
                return a.order < b.order
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.order < b.order
            }
        }
    }

    /// Ranked by our matcher on the name (types first on a tie); symbols the server found but our
    /// matcher doesn't follow in the server's order.
    nonisolated static func symbolItems(_ query: String, _ symbols: [Symbol], root: URL) -> [SearchItem] {
        let pattern = FuzzyPattern(query)
        let typeKinds: Set<Int> = [5, 10, 11, 23] // LSP SymbolKind: class, enum, interface, struct
        var seen = Set<String>()
        var ranked: [RankedSymbol] = []
        for (i, s) in symbols.enumerated() {
            let id = "symbol:\(s.url.absoluteString)#\(s.line):\(s.character):\(s.name)"
            guard seen.insert(id).inserted else { continue }
            ranked.append(RankedSymbol(symbol: s, score: pattern.score(s.name), order: i, id: id, isType: typeKinds.contains(s.kind)))
        }
        ranked.sort(by: RankedSymbol.before)
        return ranked.prefix(symbolLimit).map { r in
            let s = r.symbol
            var detail = relative(s.url, root)
            if let container = s.container, !container.isEmpty { detail = "\(container) · \(detail)" }
            return SearchItem(id: r.id, kind: .symbol, title: s.name, detail: detail, matched: r.score?.matched ?? [],
                              target: .location(url: s.url, line: s.line, character: s.character))
        }
    }

    nonisolated static func textItems(_ stream: AsyncThrowingStream<[FindMatch], Error>, root: URL) async -> [SearchItem] {
        var found: [FindMatch] = []
        do {
            for try await batch in stream {
                found += batch
                if found.count >= textLimit { break }
            }
        } catch {} // a failed text search just shows no text results
        return found.prefix(textLimit).map { m in
            // Drop the indentation, keeping the highlight on the match.
            let units = Array(m.preview.utf16)
            let indent = units.prefix { $0 == 0x20 || $0 == 0x09 }.count
            let title = String(decoding: units[indent...], as: UTF16.self)
            let matched = m.ranges.flatMap { $0 }.filter { $0 >= indent }.map { $0 - indent }
            return SearchItem(id: "text:\(m.path):\(m.line)", kind: .text, title: title, detail: "\(m.path):\(m.line)", matched: matched,
                              target: .location(url: root.appendingPathComponent(m.path), line: m.line - 1, character: m.column))
        }
    }

    nonisolated static func relative(_ url: URL, _ root: URL) -> String {
        let r = root.standardizedFileURL.path, p = url.standardizedFileURL.path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : url.lastPathComponent
    }
}
