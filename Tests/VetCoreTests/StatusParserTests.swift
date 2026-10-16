import Foundation
import Testing
@testable import VetCore

private func z(_ parts: String...) -> Data { Data(parts.joined(separator: "\0").utf8 + [0]) }

@Test func parsesOrdinaryAndRename() {
    let out = StatusParser.parse(z(
        "1 .M N... 100644 100644 100644 aaa bbb src/a file.ts",
        "2 R. N... 100644 100644 100644 aaa bbb R100 src/new.ts", "src/old.ts",
        "? notes.md"))
    #expect(out == [
        FileChange(path: "src/a file.ts", kind: .modified, stage: .unstaged),
        FileChange(path: "src/new.ts", origPath: "src/old.ts", kind: .renamed, stage: .staged),
        FileChange(path: "notes.md", kind: .untracked, stage: .unstaged),
    ])
}

@Test func partialWhenBothColumns() {
    #expect(StatusParser.parse(z("1 MM N... 100644 100644 100644 a b x.ts")).first?.stage == .partial)
    #expect(StatusParser.parse(z("1 AM N... 000000 100644 100644 a b y.ts")).first?.kind == .added)
}

@Test func deletionsAndConflicts() {
    let out = StatusParser.parse(z(
        "1 .D N... 100644 100644 000000 a b gone.ts",
        "1 D. N... 100644 000000 000000 a b staged-gone.ts",
        "u UU N... 100644 100644 100644 100644 a b c clash.ts"))
    #expect(out.map(\.kind) == [.deleted, .deleted, .conflicted])
    #expect(out.map(\.stage) == [.unstaged, .staged, .unstaged])
    #expect(out[1].modeIndex == "100644") // falls back to HEAD mode when gone from the index
}
