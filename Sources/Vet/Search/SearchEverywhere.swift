import Foundation
import VetCore

/// Search Everywhere for the open project: files (fuzzy, camel humps), classes and symbols (the
/// language servers' workspace/symbol), actions (menu commands) and text (`TextSearch`).
///
/// Ask for `results(for:)` on every keystroke and show the latest element; each new query cancels
/// the last one. Items are `SearchItem`s; `SearchItem.Target` lines are 0-based.
@MainActor
final class SearchEverywhere {
    typealias Symbol = SearchEverywhereEngine.Symbol

    let root: URL
    private let engine: SearchEverywhereEngine

    init(root: URL,
         files: @escaping @MainActor () -> [String],
         symbols: @escaping @MainActor (String) async -> [(name: String, container: String?, url: URL, line: Int, character: Int, kind: Int)],
         actions: @escaping @MainActor () -> [(id: String, title: String)]) {
        self.root = root
        let text = TextSearch(root: root)
        engine = SearchEverywhereEngine(root: root, files: files, symbols: symbols, actions: actions,
                                        text: { query in text.search(FindQuery(text: query), limit: SearchEverywhereEngine.textLimit) })
    }

    /// Debounced (~120 ms); results grouped: Files (top 8), Classes & Symbols (top 8), Actions
    /// (top 5), Text (top 8, only when the query has 3 or more characters). Each group appears as
    /// soon as it is ready.
    func results(for query: String) -> AsyncStream<[SearchItem]> {
        engine.results(for: query)
    }
}
