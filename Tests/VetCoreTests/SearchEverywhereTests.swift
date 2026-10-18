import Foundation
import Synchronization
import Testing
@testable import VetCore

private let root = URL(fileURLWithPath: "/tmp/sample", isDirectory: true)

/// Counts provider calls and remembers their queries.
private final class Calls: Sendable {
    private let log = Mutex<[String]>([])
    func record(_ q: String) { log.withLock { $0.append(q) } }
    var all: [String] { log.withLock { $0 } }
}

private func symbol(_ name: String, kind: Int = 12, container: String? = nil, line: Int = 0) -> SearchEverywhereEngine.Symbol {
    (name: name, container: container, url: root.appendingPathComponent("src/app/\(name).ts"), line: line, character: 2, kind: kind)
}

private func textStream(_ matches: [FindMatch], after delay: Duration = .zero, calls: Calls? = nil, query: String = "") -> AsyncThrowingStream<[FindMatch], Error> {
    calls?.record(query)
    return AsyncThrowingStream { c in
        let task = Task {
            try? await Task.sleep(for: delay)
            for m in matches { c.yield([m]) }
            c.finish()
        }
        c.onTermination = { _ in task.cancel() }
    }
}

@MainActor
private func engine(files: [String] = samplePaths, symbols: [SearchEverywhereEngine.Symbol] = [], symbolDelay: Duration = .zero,
                    actions: [SearchEverywhereEngine.Action] = [], text: [FindMatch] = [], textDelay: Duration = .zero,
                    calls: Calls = Calls(), debounce: Duration = .milliseconds(5)) -> SearchEverywhereEngine {
    SearchEverywhereEngine(root: root, debounce: debounce,
                           files: { calls.record("files"); return files },
                           symbols: { q in
                               calls.record("symbols:\(q)")
                               try? await Task.sleep(for: symbolDelay)
                               return symbols
                           },
                           actions: { actions },
                           text: { q in textStream(text, after: textDelay, calls: calls, query: "text:\(q)") })
}

@MainActor
private func collect(_ stream: AsyncStream<[SearchItem]>) async -> [[SearchItem]] {
    var out: [[SearchItem]] = []
    for await snapshot in stream { out.append(snapshot) }
    return out
}

private let groupOrder: [SearchItem.Kind] = [.file, .symbol, .action, .text]

@MainActor @Test func groupsAppearAsTheyAreReadyInAFixedOrder() async {
    let e = engine(symbols: [symbol("LoopLayer", kind: 5)], symbolDelay: .milliseconds(300),
                   actions: [(id: "layout", title: "Toggle Layout")],
                   text: [FindMatch(path: "src/a.ts", line: 3, preview: "  layer()", ranges: [2..<7])], textDelay: .milliseconds(100))
    let snapshots = await collect(e.results(for: "lay"))
    #expect(snapshots.count >= 3)
    // Files (and actions) show at once; text (100 ms) next; symbols (300 ms) last...
    #expect(snapshots.first?.contains { $0.kind == .symbol || $0.kind == .text } == false)
    let filesFirst = snapshots.firstIndex { $0.contains { $0.kind == .file } }!
    let textFirst = snapshots.firstIndex { $0.contains { $0.kind == .text } }!
    let symbolsFirst = snapshots.firstIndex { $0.contains { $0.kind == .symbol } }!
    #expect(filesFirst < textFirst)
    #expect(textFirst < symbolsFirst)
    // ...but every snapshot keeps the group order.
    for s in snapshots {
        let ranks = s.map { groupOrder.firstIndex(of: $0.kind)! }
        #expect(ranks == ranks.sorted())
    }
    let last = snapshots.last!
    #expect(Set(last.map(\.kind)) == [.file, .symbol, .action, .text])
    #expect(last.first?.title == "layer.ts")
}

@MainActor @Test func groupsAreCapped() async {
    let manyFiles = (1...30).map { "src/layer\($0).ts" }
    let manySymbols = (1...30).map { symbol("Layer\($0)") }
    let manyActions = (1...30).map { (id: "a\($0)", title: "Layer Action \($0)") }
    let manyText = (1...30).map { FindMatch(path: "f\($0).ts", line: $0, preview: "layer", ranges: [0..<5]) }
    let last = await collect(engine(files: manyFiles, symbols: manySymbols, actions: manyActions, text: manyText).results(for: "layer")).last!
    #expect(last.count { $0.kind == .file } == 8)
    #expect(last.count { $0.kind == .symbol } == 8)
    #expect(last.count { $0.kind == .action } == 5)
    #expect(last.count { $0.kind == .text } == 8)
}

@MainActor @Test func shortQueriesSkipText() async {
    let calls = Calls()
    let last = await collect(engine(text: [FindMatch(path: "a", line: 1, preview: "la", ranges: [0..<2])], calls: calls).results(for: "la")).last!
    #expect(!last.contains { $0.kind == .text })
    #expect(!calls.all.contains { $0.hasPrefix("text:") })
}

@MainActor @Test func aNewQueryCancelsTheDebouncedOne() async {
    let calls = Calls()
    let e = engine(calls: calls, debounce: .milliseconds(120))
    let first = e.results(for: "lay")
    let second = e.results(for: "layer")
    let (a, b) = await (collect(first), collect(second))
    #expect(a.isEmpty) // cancelled while debouncing: nothing ran
    #expect(!b.isEmpty)
    #expect(calls.all.filter { $0 == "files" }.count == 1)
    #expect(calls.all.contains("symbols:layer"))
    #expect(!calls.all.contains("symbols:lay"))
}

@MainActor @Test func emptyQueryIsEmpty() async {
    let calls = Calls()
    #expect(await collect(engine(calls: calls).results(for: "  ")) == [[]])
    #expect(calls.all.isEmpty)
}

@MainActor @Test func fileItemsShowNameFolderAndLine() async {
    let last = await collect(engine().results(for: "loop-layer.ts:42")).last!
    let item = last.first { $0.kind == .file }!
    #expect(item.title == "loop-layer.ts")
    #expect(item.detail == "src/app/layers/base")
    #expect(item.matched == Array(0..<13)) // offsets in the title
    #expect(item.target == .file(path: "src/app/layers/base/loop-layer.ts", line: 41)) // 0-based
    #expect(item.id == "file:src/app/layers/base/loop-layer.ts")
}

@MainActor @Test func textItemsDropIndentation() async {
    let m = FindMatch(path: "src/a.ts", line: 7, preview: "    const foo = 1", ranges: [10..<13])
    let item = await collect(engine(files: [], text: [m]).results(for: "foo")).last!.first { $0.kind == .text }!
    #expect(item.title == "const foo = 1")
    #expect(item.matched == [6, 7, 8])
    #expect(item.detail == "src/a.ts:7")
    #expect(item.target == .location(url: root.appendingPathComponent("src/a.ts"), line: 6, character: 10))
}

@MainActor @Test func symbolsRankedByOurMatcherThenTheServers() async {
    let symbols = [
        symbol("unrelatedButServerSaysSo"),
        symbol("layerFor", kind: 12),
        symbol("Layer", kind: 5, container: "layers"),
        symbol("LoopLayer", kind: 5),
    ]
    let items = await collect(engine(files: [], symbols: symbols).results(for: "Layer")).last!.filter { $0.kind == .symbol }
    #expect(items.map(\.title) == ["Layer", "layerFor", "LoopLayer", "unrelatedButServerSaysSo"])
    #expect(items[0].detail == "layers · src/app/Layer.ts")
    #expect(items[0].target == .location(url: root.appendingPathComponent("src/app/Layer.ts"), line: 0, character: 2))
    #expect(items[3].matched.isEmpty)
}

@MainActor @Test func actionsRankedByTitle() async {
    let actions = [(id: "commit", title: "Commit…"), (id: "find", title: "Find in Files"), (id: "files", title: "Show Files")]
    let items = await collect(engine(files: [], actions: actions).results(for: "fi")).last!.filter { $0.kind == .action }
    #expect(items.map(\.id) == ["action:find", "action:files"])
    #expect(items[0].target == .action(id: "find"))
    #expect(items[0].matched == [0, 1])
}
