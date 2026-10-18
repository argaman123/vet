import Foundation
import Testing
@testable import VetCore

// MARK: Semantic tokens

private let legend = SemanticTokenLegend(tokenTypes: ["class", "function", "variable"],
                                         tokenModifiers: ["declaration", "static", "readonly"])

@Test func semanticTokensDecodeRelativePositionsAndModifierBits() {
    let data = [
        0, 4, 5, 0, 1, // line 0, col 4: class, declaration
        0, 6, 3, 1, 0, // same line, 6 after the last start: col 10, function
        2, 2, 4, 2, 6, // two lines down, col 2 from the line start: variable, static + readonly
        0, 10, 1, 9, 0, // a type outside the legend: dropped, but col 12 still counts
        0, 5, 2, 0, 8, // col 17: class; bit 3 has no modifier in the legend
        1, 0, 3, 1, 4, // next line, col 0: function, readonly
        3, 1, // a cut-off tuple is ignored
    ]
    let tokens = SemanticToken.decode(data, legend: legend)
    #expect(tokens == [
        SemanticToken(line: 0, character: 4, length: 5, type: "class", modifiers: ["declaration"]),
        SemanticToken(line: 0, character: 10, length: 3, type: "function", modifiers: []),
        SemanticToken(line: 2, character: 2, length: 4, type: "variable", modifiers: ["static", "readonly"]),
        SemanticToken(line: 2, character: 17, length: 2, type: "class", modifiers: []),
        SemanticToken(line: 3, character: 0, length: 3, type: "function", modifiers: ["readonly"]),
    ])
}

@Test func semanticTokensComeFromTheResultAndTheAnnouncedLegend() throws {
    // typescript-language-server's legend, as its initialize result has it.
    let capability = try JSONValue.decode(Data(#"""
    {"legend":{"tokenTypes":["class","enum","interface","namespace","typeParameter","type","parameter","variable","enumMember","property","function","member"],
               "tokenModifiers":["declaration","static","async","readonly","defaultLibrary","local"]},"full":true}
    """#.utf8))
    let tsLegend = try #require(SemanticTokenLegend(capability["legend"]))
    let result: JSONValue = ["resultId": "1", "data": [1, 22, 5, 0, 1, 1, 8, 4, 6, 9, 0, 4, 7, 11, 16]]
    #expect(SemanticToken.list(from: result, legend: tsLegend) == [
        SemanticToken(line: 1, character: 22, length: 5, type: "class", modifiers: ["declaration"]),
        SemanticToken(line: 2, character: 8, length: 4, type: "parameter", modifiers: ["declaration", "readonly"]),
        SemanticToken(line: 2, character: 12, length: 7, type: "member", modifiers: ["defaultLibrary"]),
    ])
    #expect(SemanticToken.list(from: .null, legend: tsLegend).isEmpty)
}

// MARK: Hover

@Test func hoverSplitsTheSignatureFromPlainDocumentation() throws {
    // typescript-language-server: a leading newline, a {@link} turned into a markdown link, a tag in emphasis.
    let ts = HoverInfo.split(markdown: """

    ```typescript
    (method) Circle.area(): number
    ```
    The area, in **square** units. See [Shape.describe](file:///p/shape.ts#L11%2C3).

    *@returns* — the area
    """)
    #expect(ts.signature == "(method) Circle.area(): number")
    #expect(ts.documentation == "The area, in square units. See Shape.describe.\n\n@returns — the area")

    // pyright: a rule after the code, and the docstring's own markdown characters escaped.
    let py = HoverInfo.split(markdown: #"""
    ```python
    class Shape(name: str)
    ```
    ---
    A shape that can be measured.

    Use `area` to get the \*\*area\*\*; see [docs](https://example.com).
    """#)
    #expect(py.signature == "class Shape(name: str)")
    #expect(py.documentation == "A shape that can be measured.\n\nUse area to get the **area**; see docs.")

    // kotlin-lsp: a four-backtick fence and nothing else.
    let kt = HoverInfo.split(markdown: "````kotlin\nclass Circle(radius: Double) : Shape()\n````\n")
    #expect(kt.signature == "class Circle(radius: Double) : Shape()")
    #expect(kt.documentation == nil)

    // Only the first block is the signature; a later example keeps its lines, without fences.
    let example = HoverInfo.split(markdown: "```ts\nfoo(): void\n```\nExample:\n```ts\nfoo(a_b * c_d);\n```\n# Notes\n> _quoted_ &lt;T&gt;&nbsp;x")
    #expect(example.signature == "foo(): void")
    #expect(example.documentation == "Example:\nfoo(a_b * c_d);\nNotes\nquoted <T> x")

    // No code block: no signature; identifiers with underscores and stars in code survive.
    let plain = HoverInfo.split(markdown: "Calls `do_it(*args)` on snake_case_name, __twice__.")
    #expect(plain.signature == nil)
    #expect(plain.documentation == "Calls do_it(*args) on snake_case_name, twice.")
}

@Test func hoverParsesEveryContentsShape() throws {
    let markup: JSONValue = [
        "contents": ["kind": "markdown", "value": "```ts\nconst n: number\n```"],
        "range": ["start": ["line": 7, "character": 6], "end": ["line": 7, "character": 7]],
    ]
    #expect(HoverInfo.parse(markup) == HoverInfo(
        signature: "const n: number", documentation: nil,
        range: LSPRange(start: LSPPosition(line: 7, character: 6), end: LSPPosition(line: 7, character: 7))))

    // MarkedString[]: a code part and a markdown part.
    let marked: JSONValue = ["contents": [["language": "kotlin", "value": "fun area(): Double"], "The _area_."]]
    #expect(HoverInfo.parse(marked) == HoverInfo(signature: "fun area(): Double", documentation: "The area.", range: nil))

    // Plain text is taken as it is, markdown-looking characters included.
    let plain: JSONValue = ["contents": ["kind": "plaintext", "value": "int x\n  more *stars* [a](b)"]]
    #expect(HoverInfo.parse(plain) == HoverInfo(signature: nil, documentation: "int x\n  more *stars* [a](b)", range: nil))

    #expect(HoverInfo.parse(.null) == nil)
    #expect(HoverInfo.parse(["contents": []]) == nil)
    #expect(HoverInfo.parse(["contents": ["kind": "markdown", "value": ""]]) == nil)
}
