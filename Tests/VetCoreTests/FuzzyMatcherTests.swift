import Testing
@testable import VetCore

// Paths from a sample web project (plus a few Swift ones for camel humps).
let samplePaths = [
    ".vscode/settings.json",
    "docs/layers.md",
    "public/fixtures/observations/temperature.json",
    "src/app/dev/fixture-backend/synthetic-lightning.ts",
    "src/app/engine/base/animated-layer.ts",
    "src/app/engine/base/look.ts",
    "src/app/engine/looks/wind-barbs.ts",
    "src/app/engine/looks/wind-particles.ts",
    "src/app/engine/map-service.ts",
    "src/app/layers/base/layer-group.ts",
    "src/app/layers/base/layer.ts",
    "src/app/layers/base/loop-layer.ts",
    "src/app/layers/birds/filtered-birds-layer.ts",
    "src/app/layers/layers-service.ts",
    "src/app/layers/lightning/lightning-layer.ts",
    "src/app/layers/model/model-layer.ts",
    "src/app/layers/model/temperature.ts",
    "src/app/layers/model/wind.ts",
    "src/app/layers/observations/temperature.ts",
    "src/app/layers/observations/wind.ts",
    "src/app/layers/radar/radar-layer.ts",
    "src/app/layers/radar/rain-radar.ts",
    "src/app/layers/registry.ts",
    "src/app/pages/home/layer-bar/control/control.ts",
    "src/app/pages/home/layer-bar/layer-bar.html",
    "src/app/pages/home/layer-bar/layer-bar.ts",
    "src/app/pages/home/forecast/temperature-chart/temperature-chart.ts",
    "src/app/pages/home/forecast/wind-chart/wind-chart.ts",
    "src/app/pages/home/settings-panel/settings-panel.ts",
    "src/app/utils/settings.ts",
    "src/app/utils/wind.ts",
    "src/spartan/button/src/index.ts",
    "Sources/Vet/Files/FileListTreeView.swift",
    "Sources/Vet/Files/FilesModel.swift",
    "Sources/Vet/Review/Diff/RibbonDiffView.swift",
]

private func ranked(_ query: String, limit: Int = 50) -> [String] {
    FileRanking.rank(query, paths: samplePaths, limit: limit).map(\.path)
}

// MARK: Matcher

@Test func camelHumpsMatchWordStarts() {
    #expect(FuzzyMatcher.score("LoLa", "LoopLayer")?.matched == [0, 1, 4, 5])
    #expect(FuzzyMatcher.score("LoLa", "loop-layer.ts")?.matched == [0, 1, 5, 6])
    #expect(FuzzyMatcher.score("lola", "LoopLayer") != nil) // lowercase humps work too
    #expect(FuzzyMatcher.score("FiMo", "FilesModel.swift")?.matched == [0, 1, 5, 6])
    #expect(FuzzyMatcher.score("fm", "FilesModel.swift")?.matched == [0, 5])
    #expect(FuzzyMatcher.score("RDV", "RibbonDiffView.swift")?.matched == [0, 6, 10])
}

@Test func laterFragmentsStartAtWordStartsOnly() {
    #expect(FuzzyMatcher.score("lyr", "layer.ts") == nil) // y and r are mid-word
    #expect(FuzzyMatcher.score("lay", "player.ts") != nil) // one fragment may start mid-word
    #expect(FuzzyMatcher.score("ayL", "playxLoop") == nil) // ...but needs 3 letters before skipping
    #expect(FuzzyMatcher.score("layL", "playxLoop")?.matched == [1, 2, 3, 5])
}

@Test func mixedCaseQueryKeepsItsCase() {
    // An uppercase letter in a mixed-case query must land on a hump.
    #expect(FuzzyMatcher.score("fooBar", "foo_xbar") == nil)
    #expect(FuzzyMatcher.score("fooBar", "foo_bar") != nil)
    #expect(FuzzyMatcher.score("LoL", "hellolol") == nil)
    // An all-caps query may match lowercase.
    #expect(FuzzyMatcher.score("LL", "loop-layer")?.matched == [0, 5])
}

@Test func separatorsInTheQuery() {
    #expect(FuzzyMatcher.score("loop-lay", "loop-layer.ts")?.matched == [0, 1, 2, 3, 4, 5, 6, 7])
    #expect(FuzzyMatcher.score("loop_lay", "loop-layer.ts")?.matched == [0, 1, 2, 3, 4, 5, 6, 7])
    #expect(FuzzyMatcher.score("loop-lay", "LoopLayer.swift")?.matched == [0, 1, 2, 3, 4, 5, 6])
    #expect(FuzzyMatcher.score("loop lay", "loop-layer.ts")?.matched == [0, 1, 2, 3, 5, 6, 7])
    #expect(FuzzyMatcher.score("loop lay", "LoopLayer.swift") != nil)
    #expect(FuzzyMatcher.score("loop-lay", "loopxlay") == nil) // the letter after `-` starts a word
    #expect(FuzzyMatcher.score("loop-layer", "loop-layer.ts")! > FuzzyMatcher.score("loop-layer", "LoopLayer.ts")!)
}

@Test func dotsAreNotSkippedOver() {
    #expect(FuzzyMatcher.score("a.ts", "abc.min.ts")?.matched == [0, 3, 8, 9])
    #expect(FuzzyMatcher.score("ab.ts", "a.b.c.ts") == nil) // IntelliJ: a typed dot keeps humps within dots
    #expect(FuzzyMatcher.score(".git", ".gitignore")?.matched == [0, 1, 2, 3])
}

@Test func scoreOrdering() {
    let s = { (q: String, c: String) in FuzzyMatcher.score(q, c)! }
    #expect(s("lay", "layer.ts") > s("lay", "loop-layer.ts")) // start of name
    #expect(s("lay", "loop-layer.ts") > s("lay", "player.ts")) // word start beats mid-word
    #expect(s("lay", "layer.ts") > s("lay", "layers.ts")) // shorter wins a tie
    #expect(s("layer", "layer-bar.ts") > s("layer", "lazy-yarn-eraser.ts")) // contiguous beats scattered
    #expect(s("Layer", "Layer.swift") > s("Layer", "layer.swift")) // shift was pressed
    #expect(s("layer", "layer.swift") > s("layer", "Layer.swift"))
    #expect(s("lay", "load-all-yaml.ts") < s("lay", "layer.ts"))
}

@Test func unicodeOffsetsAreUTF16() {
    #expect(FuzzyMatcher.score("über", "Übersicht.swift")?.matched == [0, 1, 2, 3])
    #expect(FuzzyMatcher.score("layer", "😀-layer.ts")?.matched == [3, 4, 5, 6, 7])
    #expect(FuzzyMatcher.score("", "anything") == nil)
    #expect(FuzzyMatcher.score("   ", "anything") == nil)
}

// MARK: Ranking

@Test func rankCamelHumps() {
    #expect(ranked("LoLa") == ["src/app/layers/base/loop-layer.ts"])
    #expect(ranked("FiMo").first == "Sources/Vet/Files/FilesModel.swift")
    #expect(ranked("loop-lay").first == "src/app/layers/base/loop-layer.ts")
    #expect(ranked("loop lay").first == "src/app/layers/base/loop-layer.ts")
    #expect(ranked("lightninglayer").first == "src/app/layers/lightning/lightning-layer.ts")
}

@Test func rankPrefixesFirstThenWordStarts() {
    let layer = ranked("layer")
    #expect(Array(layer.prefix(12)) == [
        "src/app/layers/base/layer.ts",
        "docs/layers.md",
        "src/app/pages/home/layer-bar/layer-bar.ts",
        "src/app/layers/base/layer-group.ts",
        "src/app/pages/home/layer-bar/layer-bar.html",
        "src/app/layers/layers-service.ts",
        // word starts, shorter names first
        "src/app/layers/base/loop-layer.ts",
        "src/app/layers/model/model-layer.ts",
        "src/app/layers/radar/radar-layer.ts",
        "src/app/engine/base/animated-layer.ts",
        "src/app/layers/lightning/lightning-layer.ts",
        "src/app/layers/birds/filtered-birds-layer.ts",
    ])
    // Then, as IntelliJ's slashless matching: "laye" in a folder, "r" starting the name.
    #expect(Set(layer.dropFirst(12)) == ["src/app/layers/registry.ts", "src/app/layers/radar/rain-radar.ts"])
}

@Test func rankSameNameByDepthThenPath() {
    #expect(ranked("wind", limit: 3) == ["src/app/utils/wind.ts", "src/app/layers/model/wind.ts", "src/app/layers/observations/wind.ts"])
    #expect(ranked("temp") == [
        "src/app/layers/model/temperature.ts",
        "src/app/layers/observations/temperature.ts",
        "public/fixtures/observations/temperature.json",
        "src/app/pages/home/forecast/temperature-chart/temperature-chart.ts",
    ])
}

@Test func rankPathSegments() {
    let lightning = FileRanking.rank("lightning/layer", paths: samplePaths, limit: 10)
    #expect(lightning.map(\.path) == ["src/app/layers/lightning/lightning-layer.ts"])
    // Offsets point into the whole path: "lightning/" in the folders, then "layer" in the name.
    let path = Array("src/app/layers/lightning/lightning-layer.ts".utf16)
    #expect(String(decoding: lightning[0].score.matched.map { path[$0] }, as: UTF16.self) == "lightning/layer")
    #expect(lightning[0].score.matched.last == 39)

    #expect(ranked("base/layer") == [
        "src/app/layers/base/layer.ts",
        "src/app/layers/base/layer-group.ts",
        "src/app/layers/base/loop-layer.ts",
        "src/app/engine/base/animated-layer.ts",
    ])
    #expect(ranked("model/temp") == ["src/app/layers/model/temperature.ts"])
    #expect(ranked("button/index") == ["src/spartan/button/src/index.ts"])
    #expect(ranked(".vscode/settings") == [".vscode/settings.json"])
    #expect(ranked("layer-bar/").count == 3) // a folder alone lists what's in it
    // Same name: the folder match closest to the file wins, even when deeper...
    let near = FileRanking.rank("lightning/q", paths: ["src/lightning/a/q.ts", "x/y/z/w/lightning/q.ts"], limit: 5)
    #expect(near.map(\.path) == ["x/y/z/w/lightning/q.ts", "src/lightning/a/q.ts"])
    // ...unless the folder match is at the very start of the path (IntelliJ prefers start matches).
    let start = FileRanking.rank("lightning/q", paths: ["lightning/a/q.ts", "x/y/z/w/lightning/q.ts"], limit: 5)
    #expect(start.map(\.path) == ["lightning/a/q.ts", "x/y/z/w/lightning/q.ts"])
}

@Test func rankFallsBackToThePath() {
    // Name doesn't match "layerslightning"; the path does, ending in the name.
    #expect(ranked("layerslightning") == ["src/app/layers/lightning/lightning-layer.ts"])
    // A query that only matches folders finds nothing.
    #expect(ranked("spartan") == [])
}

@Test func rankNothing() {
    #expect(ranked("xyzzy") == [])
    #expect(ranked("") == [])
    #expect(ranked("  ") == [])
    #expect(FileRanking.rank("layer", paths: samplePaths, limit: 2).count == 2)
}
