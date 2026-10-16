import Testing
@testable import VetCore

// Fixtures from VS Code (microsoft/vscode, src/vs/editor/test/node/diffing/fixtures; MIT License,
// Copyright (c) Microsoft Corporation): file pairs and the changes its DefaultLinesDiffComputer
// reports ("advanced.expected.diff.json"), in VS Code's notation: 1-based line ranges
// [start,end) and inner changes [line,column -> line,column].

struct VSCodeFixture: Sendable, CustomTestStringConvertible {
    struct Change: Sendable {
        let original: String
        let modified: String
        let inner: [(String, String)]
    }

    let name: String
    let original: String
    let modified: String
    let changes: [Change]
    var testDescription: String { name }

    init(_ name: String, _ original: String, _ modified: String, _ changes: [Change]) {
        self.name = name
        self.original = original
        self.modified = modified
        self.changes = changes
    }
}

private func Change(_ original: String, _ modified: String, _ inner: [(String, String)]) -> VSCodeFixture.Change {
    VSCodeFixture.Change(original: original, modified: modified, inner: inner)
}

/// "[3,5)" → 2..<4.
private func lineRange(_ s: String) -> Range<Int> {
    let n = s.split(whereSeparator: { !$0.isNumber }).map { Int($0)! }
    return (n[0] - 1)..<(n[1] - 1)
}

/// Adds "[l1,c1 -> l2,c2]" as UTF-16 column ranges per 0-based line, limited to `lines`.
private func addColumns(_ s: String, _ text: String, _ lines: Range<Int>, _ out: inout [Int: [Range<Int>]]) {
    let n = s.split(whereSeparator: { !$0.isNumber }).map { Int($0)! }
    let textLines = text.split(separator: "\n", omittingEmptySubsequences: false)
    for l in n[0]...n[2] where lines.contains(l - 1) {
        let lo = l == n[0] ? n[1] - 1 : 0, hi = l == n[2] ? n[3] - 1 : textLines[l - 1].utf16.count
        if hi > lo { out[l - 1, default: []].append(lo..<hi) }
    }
}

/// Sorted, with overlapping or touching ranges merged.
private func merged(_ cols: [Int: [Range<Int>]]) -> [Int: [Range<Int>]] {
    cols.mapValues { ranges in
        ranges.sorted { $0.lowerBound < $1.lowerBound }.reduce(into: []) { out, r in
            if let l = out.last, r.lowerBound <= l.upperBound { out[out.count - 1] = l.lowerBound..<max(l.upperBound, r.upperBound) }
            else { out.append(r) }
        }
    }
}

@Test(arguments: vscodeFixtures)
func vscodeFixture(_ f: VSCodeFixture) {
    let head = TextLines(f.original), work = TextLines(f.modified)
    var expected: [String] = []
    var headCols: [Int: [Range<Int>]] = [:], workCols: [Int: [Range<Int>]] = [:]
    for c in f.changes {
        // VS Code has an empty last line after a final newline; Vet has no such line.
        let h = lineRange(c.original).clamped(toCount: head.count), w = lineRange(c.modified).clamped(toCount: work.count)
        if h.isEmpty && w.isEmpty { continue }
        expected.append("\(h) -> \(w)")
        guard !h.isEmpty && !w.isEmpty else { continue }  // whole-line changes get no columns
        for (o, m) in c.inner {
            addColumns(o, f.original, h, &headCols)
            addColumns(m, f.modified, w, &workCols)
        }
    }
    let hunks = LineDiff.hunks(head: head, work: work)
    // Vet keeps each joined line change as one section (staging stages exactly what's shown),
    // where VS Code splits it further by character changes. Only this fixture tells them apart.
    if f.name == "shifting-twice" {
        #expect(hunks.map { "\($0.head) -> \($0.work)" } == ["12..<17 -> 12..<20"])
        return
    }
    #expect(hunks.map { "\($0.head) -> \($0.work)" } == expected)
    #expect(hunks.reduce(into: [:]) { $0.merge($1.headCols) { a, _ in a } } == merged(headCols))
    #expect(hunks.reduce(into: [:]) { $0.merge($1.workCols) { a, _ in a } } == merged(workCols))
}

/// VS Code's "subword" fixture, where Vet differs on purpose: the original's last line has no
/// newline and the modified file gives it one, so Vet's byte-exact lines make that line part of
/// the change, where VS Code reports a pure insertion ([6,6) -> [6,7)).
@Test func finalNewlineIsAChange() {
    let head = TextLines("import { A } from 'a';\nlet x: [A];")
    let work = TextLines("import { A } from 'a';\nlet x: [A];\nlet y: B;")
    let hunks = LineDiff.hunks(head: head, work: work)
    #expect(hunks.map { "\($0.head) -> \($0.work)" } == ["1..<2 -> 1..<3"])
    #expect(hunks.first?.headCols == [:])
    #expect(hunks.first?.workCols == [2: [0..<9]])
}

/// Every fixture is small enough for VS Code's dynamic program; past 1,700 lines it uses Myers.
@Test func largeFileTakesMyersPath() {
    var lines: [String] = []
    var k = 0
    while lines.count < 3_000 {
        k += 1
        lines += ["func compute\(k)(value: Int) -> Int {", "    let a\(k) = value * \(k % 7)", "    return a\(k) + \(k)", "}", ""]
    }
    var edited = lines
    for (i, p) in (0..<40).map({ 2_990 - 73 * $0 }).enumerated() {  // last first, so positions hold
        switch i % 3 {
        case 0: edited[p] += " // changed"
        case 1: edited.insert("    print(\"inserted\")", at: p)
        default: edited.remove(at: p)
        }
    }
    let hunks = LineDiff.hunks(head: TextLines(lines.map { $0 + "\n" }.joined()), work: TextLines(edited.map { $0 + "\n" }.joined()))
    #expect(hunks.count == 40)
    #expect(hunks.allSatisfy { $0.head.count <= 1 && $0.work.count <= 1 })
    for h in hunks where h.head.count == 1 && h.work.count == 1 {
        let n = lines[h.head.lowerBound].utf16.count
        #expect(h.headCols == [:] && h.workCols == [h.work.lowerBound: [n..<(n + 11)]])
    }
}

let vscodeFixtures: [VSCodeFixture] = [
    VSCodeFixture("trivial",
            #"""

"""#,
            #"""
x
"""#, [
        Change("[1,2)", "[1,2)", [("[1,1 -> 1,1 EOL]", "[1,1 -> 1,2 EOL]")]),
    ]),
    VSCodeFixture("invalid-ranges",
            #"""

"""#,
            #"""
Tempor duis sunt laborum aliqua id eu irure.
Consequat aliquip excepteur.
Adipisicing incididunt do magn.

"""#, [
        Change("[1,2)", "[1,5)", [("[1,1 -> 1,1 EOL]", "[1,1 -> 4,1 EOL]")]),
    ]),
    VSCodeFixture("deletion",
            #"""
import { Link, List, Separator, Stack } from '@fluentui/react';
import { View } from '../../layout/layout';

export const OtherToolsView = () => {
	return (
		<View title='Other Tools'>
			<Stack grow={true} verticalFill={true}>
				<Stack.Item>
					<List
						items={[
							{ name: 'VS Code Standup (Redomond)', href: 'https://vscode-standup.azurewebsites.net' },
							{ name: 'VS Code Standup (Zurich)', href: 'http://stand.azurewebsites.net/' },
							{},
							{ name: 'VS Code Errors', href: 'https://vscode-errors.azurewebsites.net' },
							{ name: 'VS Code GDPR', href: 'https://github.com/microsoft/vscode-gdpr-tooling' },
						]}
						onRenderCell={(item) => {
							if (!item?.name) {
								return <Separator></Separator>
							}
							return <div style={{ marginBottom: 12 }}><Link href={item!.href} target='_blank'>{item!.name}</Link></div>
						}}
					>
					</List>
				</Stack.Item>
			</Stack>
		</View>
	);
}
"""#,
            #"""

"""#, [
        Change("[1,30)", "[1,2)", [("[1,1 -> 29,2 EOL]", "[1,1 -> 1,1 EOL]")]),
    ]),
    VSCodeFixture("equals",
            #"""
hello
world
"""#,
            #"""
hello
world
"""#, [

    ]),
    VSCodeFixture("just-whitespace",
            #"""
console.log('foo'); 
"""#,
            #"""
console.log('foo');
"""#, [
        Change("[1,2)", "[1,2)", [("[1,20 -> 1,21 EOL]", "[1,20 -> 1,20 EOL]")]),
    ]),
    VSCodeFixture("issue-214049",
            #"""
hello world; 
y
"""#,
            #"""
hello world;
// new line
y
"""#, [
        Change("[1,2)", "[1,3)", [("[1,13 -> 1,14 EOL]", "[1,13 -> 1,13 EOL]"), ("[2,1 -> 2,1]", "[2,1 -> 3,1]")]),
    ]),
    VSCodeFixture("intra-block-align",
            #"""
console.log(1);
console.log(2);
console.log(3);
console.log(4);

"""#,
            #"""
console.log(1)
console.log(2)
console.log(4)

"""#, [
        Change("[1,5)", "[1,4)", [("[1,15 -> 1,16 EOL]", "[1,15 -> 1,15 EOL]"), ("[2,15 -> 3,16 EOL]", "[2,15 -> 2,15 EOL]"), ("[4,15 -> 4,16 EOL]", "[3,15 -> 3,15 EOL]")]),
    ]),
    VSCodeFixture("penalize-fragmentation",
            #"""
import { IChange, IDiffComputationResult } from 'vs/editor/common/diff/diffComputer';
"""#,
            #"""
import { IDocumentDiffProviderOptions } from 'vs/editor/common/diff/documentDiffProvider';
import { IChange } from 'vs/editor/common/diff/smartLinesDiffComputer';
"""#, [
        Change("[1,2)", "[1,3)", [("[1,1 -> 1,1]", "[1,1 -> 2,1]"), ("[1,17 -> 1,41]", "[2,17 -> 2,17]"), ("[1,72 -> 1,84]", "[2,48 -> 2,70]")]),
    ]),
    VSCodeFixture("random-match-1",
            #"""
const sourceActions = notebookKernelService.getSourceActions(notebook, editor.scopedContextKeyService);

"""#,
            #"""
const sourceActions = notebookKernelService.getSourceActions(notebookTextModel, scopedContextKeyService);

"""#, [
        Change("[1,2)", "[1,2)", [("[1,62 -> 1,79]", "[1,62 -> 1,81]")]),
    ]),
    VSCodeFixture("random-match-2",
            #"""
if (!all.length && !sourceActions.length) {
	const activeNotebookModel = getNotebookEditorFromEditorPane(editorService.activeEditorPane)?.textModel;
	if (activeNotebookModel) {
		const language = this.getSuggestedLanguage(activeNotebookModel);
		suggestedExtension = language ? this.getSuggestedKernelFromLanguage(activeNotebookModel.viewType, language) : undefined;
	}
	if (suggestedExtension) {

"""#,
            #"""
if (!all.length && !sourceActions.length) {
	const language = this.getSuggestedLanguage(notebookTextModel);
	suggestedExtension = language ? this.getSuggestedKernelFromLanguage(notebookTextModel.viewType, language) : undefined;
	if (suggestedExtension) {

"""#, [
        Change("[2,7)", "[2,4)", [("[2,1 -> 4,2]", "[2,1 -> 2,1]"), ("[4,46 -> 4,53]", "[2,45 -> 2,46]"), ("[4,60 -> 4,60]", "[2,53 -> 2,57]"), ("[5,1 -> 5,2]", "[3,1 -> 3,1]"), ("[5,71 -> 5,78]", "[3,70 -> 3,71]"), ("[5,85 -> 5,85]", "[3,78 -> 3,82]"), ("[6,1 -> 7,1]", "[4,1 -> 4,1]")]),
    ]),
    VSCodeFixture("random-match-3",
            #"""
const { selected, all, suggestions, hidden } = notebookKernelService.getMatchingKernel(notebook);

"""#,
            #"""
const scopedContextKeyService = editor.scopedContextKeyService;
const matchResult = notebookKernelService.getMatchingKernel(notebook);
const { selected, all } = matchResult;

"""#, [
        Change("[1,2)", "[1,4)", [("[1,6 -> 1,45]", "[1,6 -> 2,18]"), ("[2,1 -> 2,1 EOL]", "[3,1 -> 4,1 EOL]")]),
    ]),
    VSCodeFixture("shifting-parameters",
            #"""
function x(alignments: RangeMapping[]): x[] { }

"""#,
            #"""
function x(alignments: RangeMapping[], originalLines: string[], modifiedLines: string[]): x[] { }

"""#, [
        Change("[1,2)", "[1,2)", [("[1,38 -> 1,38]", "[1,38 -> 1,88]")]),
    ]),
    VSCodeFixture("import-shifting",
            #"""
import { RuntimeMode } from './runtimeMode';
import { PromiseQueue } from './telemetry';
import { TestNotificationSender, TestUrlOpener } from './testHelpers';

"""#,
            #"""
import { RuntimeMode } from './runtimeMode';
import { PromiseQueue, TestPromiseQueue } from './telemetry';
import { TestNotificationSender, TestUrlOpener } from './testHelpers';

"""#, [
        Change("[2,3)", "[2,3)", [("[2,22 -> 2,22]", "[2,22 -> 2,40]")]),
    ]),
    VSCodeFixture("ts-insert",
            #"""
const sequence2 = new SequenceFromIntArray(tgtDocLines);
"""#,
            #"""
const sequence2 = new LineSequence(tgtDocLines, modifiedLines);
"""#, [
        Change("[1,2)", "[1,2)", [("[1,23 -> 1,43]", "[1,23 -> 1,35]"), ("[1,55 -> 1,55]", "[1,47 -> 1,62]")]),
    ]),
    VSCodeFixture("ts-strings",
            #"""
interface Test {
    /**
     * Controls whether the fold actions in the gutter stay always visible or hide unless the mouse is over the gutter.
     * Defaults to 'mouseover'.
     */
    showFoldingControls?: 'always' | 'mouseover';
}

"""#,
            #"""
interface Test {
    /**
     * Controls whether the fold actions in the gutter stay always visible or hide unless the mouse is over the gutter.
     * Defaults to 'mouseover'.
     */
    showFoldingControls?: 'always' | 'never' | 'mouseover';
}

"""#, [
        Change("[6,7)", "[6,7)", [("[6,35 -> 6,35]", "[6,35 -> 6,45]")]),
    ]),
    VSCodeFixture("ts-shifting",
            #"""
[
	{
		"identifier": {
			"id": "pflannery.vscode-versionlens",
			"uuid": "07fc4a0a-11fc-4121-ba9a-f0d534c729d8"
		},
		"preRelease": false,
		"version": "1.0.9",
		"installed": true
	},
	{
		"identifier": {
			"id": "sumneko.lua",
			"uuid": "3a15b5a7-be12-47e3-8445-88ee3eabc8b2"
		},
		"preRelease": false,
		"version": "3.5.6",
		"installed": true
	},
	{
		"identifier": {
			"id": "vscode.bat",
			"uuid": "5ef96c58-076f-4167-8e40-62c9deb00496"
		},
		"preRelease": false,
		"version": "1.0.0"
	}
]
"""#,
            #"""
[
	{
		"identifier": {
			"id": "pflannery.vscode-versionlens",
			"uuid": "07fc4a0a-11fc-4121-ba9a-f0d534c729d8"
		},
		"preRelease": false,
		"version": "1.0.9",
		"installed": true
	},
	{
		"identifier": {
			"id": "vscode.bat",
			"uuid": "5ef96c58-076f-4167-8e40-62c9deb00496"
		},
		"preRelease": false,
		"version": "1.0.0"
	}
]
"""#, [
        Change("[11,20)", "[11,11)", [("[11,1 -> 20,1]", "[11,1 -> 11,1]")]),
    ]),
    VSCodeFixture("ts-shift-to-ws",
            #"""
const childEndsAfterEnd = lengthGreaterThanEqual(nodeOffsetEnd, endOffset);
if (childEndsAfterEnd) {
    // No child after this child in the requested window, don't recurse
    node = child;
    level++;
    continue whileLoop;
}

const shouldContinue = collectBrackets(child, nodeOffsetStart, nodeOffsetEnd, startOffset, endOffset, push, level + 1, levelPerBracketType);
if (!shouldContinue) {
    return false;
}
"""#,
            #"""
const childEndsAfterEnd = lengthGreaterThanEqual(nodeOffsetEnd, endOffset);
if (childEndsAfterEnd) {
    // No child after this child in the requested window, don't recurse
    node = child;
    level++;
    continue whileLoop;
}

const shouldContinue = collectBrackets(child, nodeOffsetStart, nodeOffsetEnd, startOffset, endOffset, push, level + 1, levelPerBracket + 1, levelPerBracketType);
if (!shouldContinue) {
    return false;
}
"""#, [
        Change("[9,10)", "[9,10)", [("[9,119 -> 9,119]", "[9,119 -> 9,140]")]),
    ]),
    VSCodeFixture("shifting-twice",
            #"""
		for (extendToBottom = 0; extendToBottom < linesBelow; extendToBottom++) {
			const origLine = move.original.endLineNumberExclusive + extendToBottom;
			const modLine = move.modified.endLineNumberExclusive + extendToBottom;
			if (origLine > originalLines.length || modLine > modifiedLines.length) {
				break;
			}
			if (modifiedSet.contains(modLine) || originalSet.contains(origLine)) {
				break;
			}
			if (!areLinesSimilar(originalLines[origLine - 1], modifiedLines[modLine - 1], timeout)) {
				break;
			}
		}

		if (extendToBottom > 0) {
			originalSet.addRange(new LineRange(move.original.endLineNumberExclusive, move.original.endLineNumberExclusive + extendToBottom));
			modifiedSet.addRange(new LineRange(move.modified.endLineNumberExclusive, move.modified.endLineNumberExclusive + extendToBottom));
		}
"""#,
            #"""
		for (extendToBottom = 0; extendToBottom < linesBelow; extendToBottom++) {
			const origLine = move.original.endLineNumberExclusive + extendToBottom;
			const modLine = move.modified.endLineNumberExclusive + extendToBottom;
			if (origLine > originalLines.length || modLine > modifiedLines.length) {
				break;
			}
			if (modifiedSet.contains(modLine) || originalSet.contains(origLine)) {
				break;
			}
			if (!areLinesSimilar(originalLines[origLine - 1], modifiedLines[modLine - 1], timeout)) {
				break;
			}
			if (originalLines[origLine - 1].trim().length !== 0) {
				extendToBottomWithoutEmptyLines = extendToBottom + 1;
			}
		}

		if (extendToBottomWithoutEmptyLines > 0) {
			originalSet.addRange(new LineRange(move.original.endLineNumberExclusive, move.original.endLineNumberExclusive + extendToBottomWithoutEmptyLines));
			modifiedSet.addRange(new LineRange(move.modified.endLineNumberExclusive, move.modified.endLineNumberExclusive + extendToBottomWithoutEmptyLines));
		}
"""#, [
        Change("[13,13)", "[13,16)", [("[13,1 -> 13,1]", "[13,1 -> 16,1]")]),
        Change("[15,18)", "[18,21)", [("[15,7 -> 15,21]", "[18,7 -> 18,38]"), ("[16,116 -> 16,130]", "[19,116 -> 19,147]"), ("[17,116 -> 17,130]", "[20,116 -> 20,147]")]),
    ]),
    VSCodeFixture("ts-fragmented-eager-diffing2",
            #"""
import { assertIsDefined } from 'vs/base/common/types';
import { IInstantiationService, ServicesAccessor } from 'vs/platform/instantiation/common/instantiation';
import { MenuId, Action2, IAction2Options, IMenuService, SubmenuItemAction } from 'vs/platform/actions/common/actions';
import { createActionViewItem } from 'vs/platform/actions/browser/menuEntryActionViewItem';
import { parseLinkedText } from 'vs/base/common/linkedText';
import { IOpenerService } from 'vs/platform/opener/common/opener';
"""#,
            #"""
import { assertIsDefined } from 'vs/base/common/types';
import { IInstantiationService, ServicesAccessor } from 'vs/platform/instantiation/common/instantiation';
import { MenuId, Action2, IAction2Options, SubmenuItemAction } from 'vs/platform/actions/common/actions';
import { createActionViewItem } from 'vs/platform/actions/browser/menuEntryActionViewItem';
import { parseLinkedText } from 'vs/base/common/linkedText';
import { IOpenerService } from 'vs/platform/opener/common/opener';
"""#, [
        Change("[3,4)", "[3,4)", [("[3,43 -> 3,57]", "[3,43 -> 3,43]")]),
    ]),
    VSCodeFixture("ts-diff-word-split",
            #"""
import { findLast } from 'vs/base/common/arrays';
import { Disposable } from 'vs/base/common/lifecycle';
import { ITransaction, observableValue, transaction } from 'vs/base/common/observable';
import { Range } from 'vs/editor/common/core/range';
import { ScrollType } from 'vs/editor/common/editorCommon';
import { IFooBar, IFoo } from 'foo';

console.log(observableValue);

console.log(observableValue);

"""#,
            #"""
import { findLast } from 'vs/base/common/arrays';
import { Disposable } from 'vs/base/common/lifecycle';
import { ITransaction, observableFromEvent, observableValue, transaction } from 'vs/base/common/observable';
import { Range } from 'vs/editor/common/core/range';
import { ScrollType } from 'vs/editor/common/editorCommon';
import { IFooBar, IBar, IFoo } from 'foo';

console.log(observableFromEvent, observableValue);

console.log(observableValue, observableFromEvent);

"""#, [
        Change("[3,4)", "[3,4)", [("[3,23 -> 3,23]", "[3,23 -> 3,44]")]),
        Change("[6,7)", "[6,7)", [("[6,18 -> 6,18]", "[6,18 -> 6,24]")]),
        Change("[8,9)", "[8,9)", [("[8,13 -> 8,13]", "[8,13 -> 8,34]")]),
        Change("[10,11)", "[10,11)", [("[10,28 -> 10,28]", "[10,28 -> 10,49]")]),
    ]),
    VSCodeFixture("word-shared-letters",
            #"""
// test case 1:
{
	const abc = 1;
}

// test case 2:
{
	const private = 1;
}

// test case 3:
{
	const abc1 = 1;
}

// test case 4:
{
	const index = 1;
}

// test case 5:
{
	const InlineDecoration = 1;
}

// test case 6:
{
	const _getDecorationsInRange = 1;
}

// test case 7:
{
	const lord = 1;
}

// test case 8:
{
	const abc1 = 1;
}

// test case 1:
{
	// hello world
}

// test case 2:
{
	// optimizeSequenceDiffs
}

// test case 3:
{
	const optequffs = 1;
}

// test case 4:
{
	const abc = 1;
}

// test case 5:
{
	const abc = 1;
}

// test case 6:
{
	const abc = 1;
}

// test case 7:
{
	const abc = 1;
}

// test case 8:
{
	const abc = 1;
}

"""#,
            #"""
// test case 1:
{
	const asciiLower = 1;
}

// test case 2:
{
	const protected = 1;
}

// test case 3:
{
	const abc2 = 1;
}

// test case 4:
{
	const undefined = 1;
}

// test case 5:
{
	const IDecorationsViewportData = 1;
}

// test case 6:
{
	const configuration = 1;
}

// test case 7:
{
	const helloWorld = 1;
}

// test case 8:
{
	const abc1 = 1;
}

// test case 1:
{
	// helwor
}

// test case 2:
{
	// optimize Sequence Diffs
}

// test case 3:
{
	const optimize Sequence Diffs = 1;
}

// test case 4:
{
	const abc = 1;
}

// test case 5:
{
	const abc = 1;
}

// test case 6:
{
	const abc = 1;
}

// test case 7:
{
	const abc = 1;
}

// test case 8:
{
	const abc = 1;
}

"""#, [
        Change("[3,4)", "[3,4)", [("[3,8 -> 3,11]", "[3,8 -> 3,18]")]),
        Change("[8,9)", "[8,9)", [("[8,8 -> 8,15]", "[8,8 -> 8,17]")]),
        Change("[13,14)", "[13,14)", [("[13,11 -> 13,12]", "[13,11 -> 13,12]")]),
        Change("[18,19)", "[18,19)", [("[18,8 -> 18,13]", "[18,8 -> 18,17]")]),
        Change("[23,24)", "[23,24)", [("[23,8 -> 23,24]", "[23,8 -> 23,32]")]),
        Change("[28,29)", "[28,29)", [("[28,8 -> 28,30]", "[28,8 -> 28,21]")]),
        Change("[33,34)", "[33,34)", [("[33,8 -> 33,12]", "[33,8 -> 33,18]")]),
        Change("[43,44)", "[43,44)", [("[43,8 -> 43,11]", "[43,8 -> 43,8]"), ("[43,14 -> 43,16 EOL]", "[43,11 -> 43,11 EOL]")]),
        Change("[48,49)", "[48,49)", [("[48,13 -> 48,13]", "[48,13 -> 48,14]"), ("[48,21 -> 48,21]", "[48,22 -> 48,23]")]),
        Change("[53,54)", "[53,54)", [("[53,8 -> 53,17]", "[53,8 -> 53,31]")]),
    ]),
    VSCodeFixture("ts-import-ws-affinity",
            #"""
import { handledConflictMinimapOverViewRulerColor, unhandledConflictMinimapOverViewRulerColor } from 'vs/workbench/contrib/mergeEditor/browser/view/colors';
import { EditorGutter, IGutterItemInfo, IGutterItemView } from '../editorGutter';
import { CodeEditorView } from './codeEditorView';

"""#,
            #"""
import { handledConflictMinimapOverViewRulerColor, unhandledConflictMinimapOverViewRulerColor } from 'vs/workbench/contrib/mergeEditor/browser/view/colors';
import { EditorGutter, IGutterItemInfo, IGutterItemView } from '../editorGutter';
import { CodeEditorView, TitleMenu } from './codeEditorView';

"""#, [
        Change("[3,4)", "[3,4)", [("[3,24 -> 3,24]", "[3,24 -> 3,35]")]),
    ]),
    VSCodeFixture("minimal-diff-character",
            #"""
import * as path from 'path';
import { Command } from 'vscode';
import * as nls from 'vscode-nls';

"()()()()()()()()()()()()()"
"""#,
            #"""
import * as path from 'path';
import { Command, commands } from 'vscode';
import * as nls from 'vscode-nls';

"Gallicum()est()divisa()in()partres()tres()quarum()unam()est()()()()()()()()()()()()"
"""#, [
        Change("[2,3)", "[2,3)", [("[2,17 -> 2,17]", "[2,17 -> 2,27]")]),
        Change("[5,6)", "[5,6)", [("[5,2 -> 5,4]", "[5,2 -> 5,61]")]),
    ]),
]
