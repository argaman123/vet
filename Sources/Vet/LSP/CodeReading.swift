import Foundation
import VetCore
import os

// Reading aids from the language servers: hover, semantic tokens, inlay hints, code lenses,
// document and workspace symbols, and WebStorm-style gutter marks. They run every time a file
// is shown, so each result is cached per (file, text) and concurrent askers of the same thing
// share one request. Like navigation, every failure (no server, a timeout, a crash) comes
// back as no result, and cancelling the calling task cancels the server requests once nobody
// else is waiting for them.

extension CodeNavigator {
    func hover(of url: URL, text: String, line: Int, character: Int) async -> HoverInfo? {
        let key = ReadingKey(url, text, "\(line):\(character)")
        let found = await reading.hovers.value(key, "hover", url) { [self] in
            let server = try await requireServer(for: url)
            let result = try await server.documentRequest(
                "textDocument/hover", provider: "hoverProvider", url: url, text: text,
                params: ["position": LSPPosition(line: line, character: character).json])
            return (result.flatMap(HoverInfo.parse), true)
        }
        return found ?? nil
    }

    func semanticTokens(of url: URL, text: String) async -> [SemanticToken] {
        await reading.tokens.value(ReadingKey(url, text), "semanticTokens", url) { [self] in
            let server = try await requireServer(for: url)
            try await server.start()
            guard let provider = await server.capability("semanticTokensProvider"),
                  let legend = SemanticTokenLegend(provider["legend"]) else { return ([], true) } // pyright
            let result: JSONValue?
            if let full = provider["full"], full != .bool(false) {
                result = try await server.documentRequest("textDocument/semanticTokens/full",
                                                          provider: "semanticTokensProvider", url: url, text: text)
            } else {
                let lines = text.reduce(into: 1) { n, c in if c.isNewline { n += 1 } }
                result = try await server.documentRequest(
                    "textDocument/semanticTokens/range", provider: "semanticTokensProvider", url: url, text: text,
                    params: ["range": Self.range(lines: 0..<lines)])
            }
            return (result.map { SemanticToken.list(from: $0, legend: legend) } ?? [], true)
        } ?? []
    }

    /// Hints for the lines in `lines` (0-based, end exclusive).
    func inlayHints(of url: URL, text: String, lines: Range<Int>) async -> [InlayHint] {
        let key = ReadingKey(url, text, "\(lines.lowerBound)-\(lines.upperBound)")
        return await reading.hints.value(key, "inlayHints", url) { [self] in
            let server = try await requireServer(for: url)
            let result = try await server.documentRequest(
                "textDocument/inlayHint", provider: "inlayHintProvider", url: url, text: text,
                params: ["range": Self.range(lines: lines)])
            return (result.map(InlayHint.list) ?? [], true)
        } ?? []
    }

    /// Resolved lenses ("3 references", "1 implementation"), in line order.
    func codeLenses(of url: URL, text: String) async -> [CodeLensInfo] {
        await resolvedLenses(of: url, text: text)?.map(\.info) ?? []
    }

    func documentSymbols(of url: URL, text: String) async -> [DocumentSymbol] {
        await symbols(of: url, text: text, side: false) ?? []
    }

    /// Classes and symbols named like `query` (Search Everywhere), from every running server and
    /// `language`'s, which is started if it isn't running; its results come first.
    func workspaceSymbols(matching query: String, preferring language: LSPLanguage?) async -> [WorkspaceSymbol] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var languages = await runningLanguages()
        if let language {
            languages.removeAll { $0 == language }
            languages.insert(language, at: 0)
        }
        let root = self.root
        let found = await withTaskGroup(of: (Int, [WorkspaceSymbol]).self) { group in
            for (order, language) in languages.enumerated() {
                group.addTask { [self] in
                    guard let server = await server(for: language) else { return (order, []) }
                    do {
                        let anchor: @Sendable () -> (URL, String)? = { language == .typescript ? Self.anchorFile(in: root) : nil }
                        let result = try await server.workspaceSymbols(query, anchor: anchor)
                        return (order, Self.projectFirst(WorkspaceSymbol.list(from: result ?? .null), root: root))
                    } catch {
                        Self.logFailure("workspaceSymbols", language.rawValue, error)
                        return (order, [])
                    }
                }
            }
            var all: [(Int, [WorkspaceSymbol])] = []
            for await part in group { all.append(part) }
            return all
        }
        return found.sorted { $0.0 < $1.0 }.flatMap(\.1)
    }

    /// ↓ for a declaration that has implementations (an implementations lens with any; the
    /// members of such an interface too), ↑ for a class member whose base type (named in
    /// `extends`/`implements`) has a member of the same name.
    func gutterMarks(of url: URL, text: String) async -> [GutterMark] {
        await reading.gutters.value(ReadingKey(url, text), "gutterMarks", url) { [self] in
            guard let language = LSPLanguage(fileExtension: url.pathExtension) else { return ([], true) }
            let server = try await requireServer(for: url)
            try await server.start() // its capabilities are read next
            async let down = implementedMarks(of: url, text: text, language: language, server: server)
            async let up = overrideMarks(of: url, text: text, language: language, server: server)
            let (implemented, overrides) = try await (down, up)
            return (Self.merge(implemented.marks + overrides.marks), implemented.complete && overrides.complete)
        } ?? []
    }

    /// Drops every cached reading result, e.g. after files changed on disk (lens counts and
    /// gutter marks depend on other files; they also expire on their own after a while).
    func invalidateReadingCaches() {
        reading.removeAll()
    }

    // MARK: Private

    nonisolated private static let maxWorkspaceSymbols = 300
    private static let maxLenses = 300
    private static let maxImplementationQueries = 40
    private static let maxBaseTypes = 16
    private static let maxBaseFileSize = 2_000_000 // bytes; lib.dom.d.ts and the like are skipped

    private struct NoServer: Error {}

    /// Errors that end the whole computation: cancellation, and a document replaced meanwhile
    /// (the computation runs again then).
    nonisolated static func isRetried(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case LanguageServer.Failure.documentChanged? = error as? LanguageServer.Failure { return true }
        return false
    }

    /// The project's own symbols before library ones (kotlin-lsp searches the stdlib too), each
    /// once (it reports some twice), in the server's order otherwise.
    nonisolated private static func projectFirst(_ symbols: [WorkspaceSymbol], root: URL) -> [WorkspaceSymbol] {
        var seen = Set<WorkspaceSymbol>()
        let unique = symbols.filter { seen.insert($0).inserted }
        let prefix = root.standardizedFileURL.path + "/"
        let inProject = unique.filter { LSPURI.url(for: $0.location.uri)?.path.hasPrefix(prefix) == true }
        let elsewhere = unique.filter { LSPURI.url(for: $0.location.uri)?.path.hasPrefix(prefix) != true }
        return Array((inProject + elsewhere).prefix(maxWorkspaceSymbols))
    }

    private func requireServer(for url: URL) async throws -> LanguageServer {
        guard let language = LSPLanguage(fileExtension: url.pathExtension),
              let server = await server(for: language) else { throw NoServer() }
        return server
    }

    private static func range(lines: Range<Int>) -> JSONValue {
        ["start": LSPPosition(line: lines.lowerBound, character: 0).json,
         "end": LSPPosition(line: lines.upperBound, character: 0).json]
    }

    nonisolated static func logFailure(_ feature: String, _ what: String, _ error: Error) {
        guard !(error is CancellationError), !(error is NoServer) else { return }
        Logger(subsystem: "Vet", category: "CodeNavigator")
            .error("\(feature, privacy: .public) in \(what, privacy: .public): \(String(describing: error), privacy: .public)")
    }

    /// `url`'s symbols. `side` asks without replacing the open document (for a base type's file).
    private func symbols(of url: URL, text: String, side: Bool) async -> [DocumentSymbol]? {
        await reading.symbols.value(ReadingKey(url, text), "documentSymbols", url) { [self] in
            let server = try await requireServer(for: url)
            let result = side
                ? try await server.sideDocumentRequest("textDocument/documentSymbol", provider: "documentSymbolProvider",
                                                       url: url, text: text)
                : try await server.documentRequest("textDocument/documentSymbol", provider: "documentSymbolProvider",
                                                   url: url, text: text)
            return (result.map(DocumentSymbol.list) ?? [], true)
        }
    }

    private func resolvedLenses(of url: URL, text: String) async -> [ResolvedLens]? {
        await reading.lenses.value(ReadingKey(url, text), "codeLenses", url) { [self] in
            let server = try await requireServer(for: url)
            guard let result = try await server.documentRequest("textDocument/codeLens", provider: "codeLensProvider",
                                                                url: url, text: text) else { return ([], true) }
            let lenses = Array((result.array ?? []).prefix(Self.maxLenses))
            let canResolve = await server.capability("codeLensProvider")?["resolveProvider"] == .bool(true)
            // All at once: typescript-language-server queues resolves as low priority, so a ⌘-click
            // made meanwhile goes ahead of them.
            let resolved = try await withThrowingTaskGroup(of: (Int, JSONValue?).self) { group in
                for (i, lens) in lenses.enumerated() {
                    group.addTask {
                        guard lens["command"] == nil, canResolve else { return (i, lens) }
                        do {
                            return (i, try await server.resolveCodeLens(lens, url: url, text: text))
                        } catch where Self.isRetried(error) {
                            throw error
                        } catch {
                            Self.logFailure("codeLens/resolve", url.lastPathComponent, error)
                            return (i, nil)
                        }
                    }
                }
                var all = [JSONValue?](repeating: nil, count: lenses.count)
                for try await (i, lens) in group { all[i] = lens }
                return all
            }
            try Task.checkCancellation()
            var complete = true
            var found: [ResolvedLens] = []
            let lines = LSPLanguage(fileExtension: url.pathExtension) == .typescript
                ? text.split(separator: "\n", omittingEmptySubsequences: false) : nil
            for lens in resolved {
                guard let lens, let info = CodeLensInfo(resolved: lens) else {
                    complete = false // failed, or tsserver cancelled it (an empty title)
                    continue
                }
                // typescript-language-server also puts a lens on every anonymous callback (with
                // showOnAllFunctions), at its `(`; VS Code only on functions with a name.
                if let lines, !Self.startsAtName(info, lines) { continue }
                found.append(ResolvedLens(info: info, targets: CodeLensInfo.locations(inResolved: lens)))
            }
            found.sort { ($0.info.line, $0.info.character) < ($1.info.line, $1.info.character) }
            return (found, complete)
        }
    }

    private static func startsAtName(_ lens: CodeLensInfo, _ lines: [Substring]) -> Bool {
        guard lines.indices.contains(lens.line) else { return false }
        let line = lines[lens.line].utf16
        guard lens.character < line.count,
              let scalar = Unicode.Scalar(line[line.index(line.startIndex, offsetBy: lens.character)]) else { return true }
        return scalar.properties.isAlphabetic || scalar == "_" || scalar == "$" || scalar == "#" || scalar == "\""
            || scalar == "'" || scalar == "["
    }

    private struct Marks: Sendable {
        var marks: [GutterMark] = []
        var complete = true
    }

    private func implementedMarks(of url: URL, text: String, language: LSPLanguage, server: LanguageServer) async throws -> Marks {
        guard await server.capability("implementationProvider") != nil else { return Marks() } // pyright
        guard let lenses = await resolvedLenses(of: url, text: text) else { return Marks(complete: false) }
        var marks = Marks()
        var implementedLines = Set<Int>()
        for lens in lenses where lens.info.kind == .implementations {
            var targets = lens.targets
            if targets == nil {
                targets = try await implementations(of: url, text: text, at: LSPPosition(line: lens.info.line, character: lens.info.character),
                                                    server: server, marks: &marks)
            }
            guard let targets, !targets.isEmpty else { continue }
            marks.marks.append(GutterMark(line: lens.info.line, kind: .implemented, targets: targets))
            implementedLines.insert(lens.info.line)
        }
        guard let symbols = await symbols(of: url, text: text, side: false) else {
            marks.complete = false
            return marks
        }
        let declarations: [DocumentSymbol]
        if language == .typescript || lenses.contains(where: { $0.info.kind == .implementations }) {
            // An interface with implementations: which of its members are implemented (WebStorm marks
            // those too; tsserver gives them no lens).
            declarations = symbols.flatMap(\.flattened)
                .filter { $0.kind == Self.interfaceKind && implementedLines.contains($0.selectionRange.start.line) }
                .flatMap(\.children)
                .filter { Self.memberKinds.contains($0.kind) && !implementedLines.contains($0.selectionRange.start.line) }
        } else {
            // No implementation lenses (kotlin-lsp): ask about each declaration that can have any.
            declarations = Self.overridable(symbols, in: text)
        }
        let found = try await withThrowingTaskGroup(of: (DocumentSymbol, [LSPLocation]?).self) { group in
            for member in declarations.prefix(Self.maxImplementationQueries) {
                group.addTask { [self] in
                    var scratch = Marks()
                    let targets = try await implementations(of: url, text: text, at: member.selectionRange.start,
                                                            server: server, marks: &scratch)
                    return (member, scratch.complete ? targets : nil)
                }
            }
            var all: [(DocumentSymbol, [LSPLocation]?)] = []
            for try await item in group { all.append(item) }
            return all
        }
        for (member, targets) in found {
            guard let targets else { marks.complete = false; continue }
            if !targets.isEmpty {
                marks.marks.append(GutterMark(line: member.selectionRange.start.line, kind: .implemented, targets: targets))
            }
        }
        return marks
    }

    /// Interfaces and their members; abstract, open and sealed classes and their abstract, open
    /// and (not final) override members — what a subclass can implement or override.
    private static func overridable(_ symbols: [DocumentSymbol], in text: String) -> [DocumentSymbol] {
        var found: [DocumentSymbol] = []
        for type in symbols.flatMap(\.flattened) where type.kind == 5 || type.kind == interfaceKind {
            let words = HeritageClause.modifiers(in: text, declaration: type)
            let isInterface = type.kind == interfaceKind || words.contains("interface")
            guard isInterface || !words.isDisjoint(with: ["abstract", "open", "sealed"]) else { continue }
            found.append(type)
            for member in type.children where member.kind != constructorKind && (memberKinds.contains(member.kind) || member.kind == 13) {
                let modifiers = HeritageClause.modifiers(in: text, declaration: member)
                if isInterface || (!modifiers.isDisjoint(with: ["abstract", "open", "override"]) && !modifiers.contains("final")) {
                    found.append(member)
                }
            }
        }
        return found
    }

    /// `textDocument/implementation` at a declaration, without the declaration itself.
    private func implementations(of url: URL, text: String, at position: LSPPosition, server: LanguageServer,
                                 marks: inout Marks) async throws -> [LSPLocation] {
        do {
            let uri = LSPURI.string(for: url)
            return try await server.locations("textDocument/implementation", url: url, text: text,
                                              line: position.line, character: position.character, navigation: false)
                .filter { !($0.uri == uri && $0.range.start.line == position.line) }
        } catch where Self.isRetried(error) {
            throw error
        } catch {
            Self.logFailure("gutter implementation", url.lastPathComponent, error)
            marks.complete = false
            return []
        }
    }

    private func overrideMarks(of url: URL, text: String, language: LSPLanguage, server: LanguageServer) async throws -> Marks {
        guard let symbols = await symbols(of: url, text: text, side: false) else { return Marks(complete: false) }
        var bases: [(type: DocumentSymbol, name: HeritageClause.Name)] = []
        for type in symbols.flatMap(\.flattened) where Self.typeKinds.contains(type.kind) && !type.children.isEmpty {
            for name in HeritageClause.names(in: text, declaration: type, language: language) {
                bases.append((type, name))
            }
        }
        let found = try await withThrowingTaskGroup(of: (DocumentSymbol, [String: [LSPLocation]]?).self) { group in
            for (type, name) in bases.prefix(Self.maxBaseTypes) {
                group.addTask { [self] in
                    (type, try await baseMembers(named: name, in: url, text: text, symbols: symbols, server: server))
                }
            }
            var all: [(DocumentSymbol, [String: [LSPLocation]]?)] = []
            for try await item in group { all.append(item) }
            return all
        }
        var marks = Marks()
        for (type, members) in found {
            guard let members else { marks.complete = false; continue }
            for member in type.children where member.kind != Self.constructorKind {
                if let targets = members[member.name] {
                    marks.marks.append(GutterMark(line: member.selectionRange.start.line, kind: .overrides, targets: targets))
                }
            }
        }
        return marks
    }

    /// The members of the type a heritage name refers to, by name: its definition, then the
    /// symbols of the file that holds it (read from disk, opened beside the shown document).
    /// Nil when a request failed; empty when the base isn't found or its file is too big.
    private func baseMembers(named name: HeritageClause.Name, in url: URL, text: String, symbols: [DocumentSymbol],
                             server: LanguageServer) async throws -> [String: [LSPLocation]]? {
        let definitions: [LSPLocation]
        do {
            definitions = try await server.locations("textDocument/definition", url: url, text: text,
                                                     line: name.line, character: name.character, navigation: false)
        } catch where Self.isRetried(error) {
            throw error
        } catch {
            Self.logFailure("gutter definition", url.lastPathComponent, error)
            return nil
        }
        guard let definition = definitions.first, let baseURL = LSPURI.url(for: definition.uri),
              LSPLanguage(fileExtension: baseURL.pathExtension) == LSPLanguage(fileExtension: url.pathExtension)
        else { return [:] }
        let baseSymbols: [DocumentSymbol]
        if baseURL == url.standardizedFileURL {
            baseSymbols = symbols
        } else {
            let size = (try? baseURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.maxBaseFileSize, let baseText = try? String(contentsOf: baseURL, encoding: .utf8) else { return [:] }
            guard let found = await self.symbols(of: baseURL, text: baseText, side: true) else { return nil }
            baseSymbols = found
        }
        // The type whose name the definition points at (or, failing that, the innermost type around it).
        let types = baseSymbols.flatMap(\.flattened).filter { Self.typeKinds.contains($0.kind) }
        guard let base = types.last(where: { $0.selectionRange.contains(definition.range.start) })
            ?? types.last(where: { $0.range.contains(definition.range.start) }) else { return [:] }
        var members: [String: [LSPLocation]] = [:]
        for member in base.children where member.kind != Self.constructorKind {
            members[member.name, default: []].append(LSPLocation(uri: definition.uri, range: member.selectionRange))
        }
        return members
    }

    /// One mark per line and kind, targets merged.
    private static func merge(_ marks: [GutterMark]) -> [GutterMark] {
        var order: [(line: Int, kind: GutterMark.Kind)] = []
        var targets: [Int: [GutterMark.Kind: [LSPLocation]]] = [:]
        for mark in marks {
            if targets[mark.line]?[mark.kind] == nil { order.append((mark.line, mark.kind)) }
            var list = targets[mark.line]?[mark.kind] ?? []
            for target in mark.targets where !list.contains(target) { list.append(target) }
            targets[mark.line, default: [:]][mark.kind] = list
        }
        return order.sorted { ($0.line, $0.kind == .overrides ? 0 : 1) < ($1.line, $1.kind == .overrides ? 0 : 1) }
            .map { GutterMark(line: $0.line, kind: $0.kind, targets: targets[$0.line]![$0.kind]!) }
    }

    // LSP SymbolKind values.
    private static let interfaceKind = 11
    private static let constructorKind = 9
    private static let typeKinds: Set<Int> = [5, 10, 11, 19, 23] // class, enum, interface, object, struct
    private static let memberKinds: Set<Int> = [6, 7, 8, 12] // method, property, field, function

    /// A TypeScript or JavaScript file of the project, for tsserver to load the project from
    /// when no document is open (workspace/symbol searches an open file's project).
    nonisolated static func anchorFile(in root: URL) -> (URL, String)? {
        let skipped: Set<String> = ["node_modules", "dist", "build", "out", "coverage", "vendor"]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var seen = 0
        var fallback: URL?
        for case let url as URL in walker {
            seen += 1
            if seen > 5000 { break }
            if skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            switch url.pathExtension {
            case "ts", "tsx", "mts", "cts":
                if !url.lastPathComponent.hasSuffix(".d.ts"), let text = try? String(contentsOf: url, encoding: .utf8) {
                    return (url, text)
                }
            case "js", "jsx", "mjs", "cjs":
                if fallback == nil { fallback = url }
            default:
                break
            }
        }
        guard let fallback, let text = try? String(contentsOf: fallback, encoding: .utf8) else { return nil }
        return (fallback, text)
    }
}

struct ResolvedLens: Sendable {
    let info: CodeLensInfo
    /// Where the lens's command points (implementations, references), when the server says.
    let targets: [LSPLocation]?
}

// MARK: Caches

/// A file's text, as cache keys see it.
struct ReadingKey: Hashable, Sendable {
    let url: URL
    let textHash: Int
    let textLength: Int
    let extra: String

    init(_ url: URL, _ text: String, _ extra: String = "") {
        self.url = url.standardizedFileURL
        var hasher = Hasher()
        hasher.combine(text)
        self.textHash = hasher.finalize()
        self.textLength = text.utf8.count
        self.extra = extra
    }
}

@MainActor final class ReadingCaches {
    let hovers = ReadingCache<HoverInfo?>(capacity: 128)
    let tokens = ReadingCache<[SemanticToken]>(capacity: 24)
    let hints = ReadingCache<[InlayHint]>(capacity: 64)
    // Counts and marks depend on other files too, so these go stale after a while.
    let lenses = ReadingCache<[ResolvedLens]>(capacity: 32, maxAge: .seconds(30))
    let symbols = ReadingCache<[DocumentSymbol]>(capacity: 64)
    let gutters = ReadingCache<[GutterMark]>(capacity: 32, maxAge: .seconds(30))

    func removeAll() {
        hovers.removeAll()
        tokens.removeAll()
        hints.removeAll()
        lenses.removeAll()
        symbols.removeAll()
        gutters.removeAll()
    }
}

/// Results by key, least recently used dropped first, with the requests in flight shared: a
/// second asker of the same key waits for the first one's answer instead of asking again.
@MainActor final class ReadingCache<Value: Sendable> {
    /// What a computation found, and whether it may be kept (not when part of it failed).
    typealias Computed = (value: Value, cacheable: Bool)

    private var entries: [ReadingKey: (value: Value, stored: ContinuousClock.Instant)] = [:]
    private var order: [ReadingKey] = [] // least recently used first
    private var flights: [ReadingKey: Flight<Value>] = [:]
    private var generation = 0
    private let capacity: Int
    private let maxAge: Duration?

    init(capacity: Int, maxAge: Duration? = nil) {
        self.capacity = capacity
        self.maxAge = maxAge
    }

    func removeAll() {
        entries = [:]
        order = []
        flights = [:] // still running; they finish for their askers but aren't kept
        generation += 1
    }

    /// The value for `key`: cached, joined from a request in flight, or computed. Nil when the
    /// computation threw (logged, not kept) or the calling task was cancelled.
    func value(_ key: ReadingKey, _ feature: String, _ url: URL,
               compute: @escaping @MainActor () async throws -> Computed) async -> Value? {
        if let entry = entries[key] {
            if let maxAge, entry.stored.duration(to: .now) > maxAge {
                entries[key] = nil
                order.removeAll { $0 == key }
            } else {
                order.removeAll { $0 == key }
                order.append(key)
                return entry.value
            }
        }
        let flight = flights[key] ?? start(key, feature, url, compute)
        return await flight.wait()
    }

    private func start(_ key: ReadingKey, _ feature: String, _ url: URL,
                       _ compute: @escaping @MainActor () async throws -> Computed) -> Flight<Value> {
        let flight = Flight<Value>()
        let generation = self.generation
        flights[key] = flight
        flight.onAbandon = { [weak self, weak flight] in
            if let self, let flight, self.flights[key] === flight { self.flights[key] = nil }
        }
        flight.task = Task { @MainActor [weak self] in
            var computed: Computed?
            for attempt in 1...3 {
                do {
                    computed = try await compute()
                } catch LanguageServer.Failure.documentChanged where attempt < 3 {
                    continue // navigation replaced the document meanwhile: ask again
                } catch {
                    CodeNavigator.logFailure(feature, url.lastPathComponent, error)
                }
                break
            }
            if let self {
                if self.flights[key] === flight { self.flights[key] = nil }
                if let computed, computed.cacheable, !Task.isCancelled, self.generation == generation {
                    self.store(computed.value, for: key)
                }
            }
            flight.finish(computed?.value)
        }
        return flight
    }

    private func store(_ value: Value, for key: ReadingKey) {
        entries[key] = (value, .now)
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity {
            entries[order.removeFirst()] = nil
        }
    }
}

/// One computation and the callers waiting for it. It's cancelled when the last of them is.
@MainActor final class Flight<Value: Sendable> {
    var task: Task<Void, Never>?
    var onAbandon: (() -> Void)?
    private var waiters: [Int: CheckedContinuation<Value?, Never>] = [:]
    private var nextWaiter = 0
    private var result: Value??

    func wait() async -> Value? {
        if let result { return result }
        let id = nextWaiter
        nextWaiter += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                if let result {
                    continuation.resume(returning: result)
                } else if Task.isCancelled {
                    continuation.resume(returning: nil)
                    if waiters.isEmpty { abandon() }
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.leave(id) }
        }
    }

    private func leave(_ id: Int) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: nil)
        if waiters.isEmpty { abandon() }
    }

    private func abandon() {
        guard result == nil else { return }
        task?.cancel()
        onAbandon?()
    }

    func finish(_ value: Value?) {
        result = .some(value)
        for continuation in waiters.values { continuation.resume(returning: value) }
        waiters = [:]
    }
}
