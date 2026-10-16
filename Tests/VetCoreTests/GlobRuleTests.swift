import Testing
@testable import VetCore

@Test func nameOnlyMatchesAnyDepth() {
    let r = GlobRule("*.html")
    #expect(r.matches("index.html"))
    #expect(r.matches("src/app/view.html"))
    #expect(!r.matches("src/app/view.ts"))
}

@Test func folderAndDescendants() {
    let r = GlobRule("src/generated/**")
    #expect(r.matches("src/generated"))
    #expect(r.matches("src/generated/api/client.ts"))
    #expect(!r.matches("src/generatedish/x.ts"))
    #expect(!r.matches("lib/src/generated/x.ts"))
}

@Test func anyDepthFolder() {
    let r = GlobRule("**/generated/**")
    #expect(r.matches("generated/a.ts"))
    #expect(r.matches("a/b/generated/c/d.ts"))
    #expect(!r.matches("a/generatedx/d.ts"))
}

@Test func starStaysInSegmentAndQuestionMark() {
    #expect(!GlobRule("src/*.ts").matches("src/app/a.ts"))
    #expect(GlobRule("src/*.ts").matches("src/a.ts"))
    #expect(GlobRule("file?.md").matches("docs/file1.md"))
    #expect(!GlobRule("file?.md").matches("docs/file10.md"))
}

@Test func caseSensitiveAndFolderName() {
    #expect(!GlobRule("*.HTML").matches("a.html"))
    #expect(GlobRule("node_modules").matches("node_modules/x/y.js")) // a folder name rule covers its contents
    #expect(GlobRule("/docs/**").matches("docs/plan.md"))
}
