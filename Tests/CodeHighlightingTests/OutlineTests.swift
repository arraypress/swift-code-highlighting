//
//  OutlineTests.swift
//  Tests for OutlineTree (flat Symbol list → containment tree) and MarkdownOutline
//  (ATX heading extraction with fenced-code skipping + level nesting). Pure, headless.
//

import XCTest
@testable import CodeHighlighting

final class OutlineTests: XCTestCase {

    // MARK: - Helpers

    /// A symbol whose name occupies `[loc, loc+len)`; `scope` (if given) is the region
    /// that can hold children.
    private func sym(_ name: String, kind: SymbolKind = .function,
                     loc: Int, len: Int = 1, line: Int = 1, scope: NSRange? = nil) -> Symbol {
        Symbol(name: name, kind: kind, range: NSRange(location: loc, length: len),
               line: line, scopeRange: scope)
    }

    // MARK: - OutlineTree.build

    func testFlatSymbolsAllBecomeRoots() {
        let symbols = [sym("a", loc: 0), sym("b", loc: 10), sym("c", loc: 20)]
        let roots = OutlineTree.build(from: symbols)
        XCTAssertEqual(roots.count, 3)
        XCTAssertTrue(roots.allSatisfy { $0.children.isEmpty })
        XCTAssertEqual(OutlineTree.count(roots), 3)
    }

    func testMethodsNestUnderType() {
        // A type spanning [0,100) with two methods whose ranges fall inside it.
        let type = sym("Widget", kind: .type, loc: 0, len: 6, scope: NSRange(location: 0, length: 100))
        let m1 = sym("draw", kind: .method, loc: 20, len: 4)
        let m2 = sym("hide", kind: .method, loc: 40, len: 4)
        let roots = OutlineTree.build(from: [type, m1, m2])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].symbol.name, "Widget")
        XCTAssertEqual(roots[0].children.map(\.symbol.name), ["draw", "hide"])
        XCTAssertEqual(OutlineTree.count(roots), 3)
    }

    func testSiblingScopesDoNotCaptureEachOther() {
        // Two disjoint types; the second must pop the first off the stack.
        let a = sym("A", kind: .type, loc: 0, len: 1, scope: NSRange(location: 0, length: 10))
        let am = sym("am", kind: .method, loc: 3, len: 1)
        let b = sym("B", kind: .type, loc: 20, len: 1, scope: NSRange(location: 20, length: 10))
        let bm = sym("bm", kind: .method, loc: 23, len: 1)
        let roots = OutlineTree.build(from: [a, am, b, bm])
        XCTAssertEqual(roots.map(\.symbol.name), ["A", "B"])
        XCTAssertEqual(roots[0].children.map(\.symbol.name), ["am"])
        XCTAssertEqual(roots[1].children.map(\.symbol.name), ["bm"])
    }

    func testDeepNesting() {
        // H1 ⊃ H2 ⊃ H3.
        let h1 = sym("H1", kind: .heading, loc: 0, len: 1, scope: NSRange(location: 0, length: 100))
        let h2 = sym("H2", kind: .heading, loc: 10, len: 1, scope: NSRange(location: 10, length: 80))
        let h3 = sym("H3", kind: .heading, loc: 20, len: 1, scope: NSRange(location: 20, length: 60))
        let roots = OutlineTree.build(from: [h1, h2, h3])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].children.count, 1)
        XCTAssertEqual(roots[0].children[0].children.count, 1)
        XCTAssertEqual(roots[0].children[0].children[0].symbol.name, "H3")
        XCTAssertEqual(OutlineTree.count(roots), 3)
    }

    func testEmptyInputYieldsNoRoots() {
        XCTAssertTrue(OutlineTree.build(from: []).isEmpty)
        XCTAssertEqual(OutlineTree.count([]), 0)
    }

    // MARK: - MarkdownOutline.headings

    func testExtractsAtxHeadingsWithLevels() {
        let md = "# Title\n\nintro\n\n## Section\n\ntext\n\n### Sub\n"
        let heads = MarkdownOutline.headings(in: md)
        XCTAssertEqual(heads.map(\.name), ["Title", "Section", "Sub"])
        XCTAssertTrue(heads.allSatisfy { $0.kind == .heading })
        XCTAssertEqual(heads.map(\.line), [1, 5, 9])
    }

    func testHeadingsNestByLevelViaTree() {
        let md = "# Top\n## A\n### A1\n## B\n"
        let roots = OutlineTree.build(from: MarkdownOutline.headings(in: md))
        XCTAssertEqual(roots.count, 1)                       // one H1 root
        XCTAssertEqual(roots[0].symbol.name, "Top")
        XCTAssertEqual(roots[0].children.map(\.symbol.name), ["A", "B"])
        XCTAssertEqual(roots[0].children[0].children.map(\.symbol.name), ["A1"])
    }

    func testSkipsHeadingsInsideFencedCode() {
        let md = "# Real\n\n```\n# not a heading\n## also not\n```\n\n## After\n"
        let heads = MarkdownOutline.headings(in: md)
        XCTAssertEqual(heads.map(\.name), ["Real", "After"])
    }

    func testSkipsTildeFencedCode() {
        let md = "# Real\n~~~\n# nope\n~~~\n## After\n"
        XCTAssertEqual(MarkdownOutline.headings(in: md).map(\.name), ["Real", "After"])
    }

    func testRequiresSpaceAfterHashes() {
        // "#hashtag" is not a heading; "####### too deep" (7) is not either.
        let md = "#hashtag\n####### too deep\n# Ok\n"
        XCTAssertEqual(MarkdownOutline.headings(in: md).map(\.name), ["Ok"])
    }

    func testIgnoresEmptyHeadingText() {
        let md = "#\n##   \n# Content\n"
        XCTAssertEqual(MarkdownOutline.headings(in: md).map(\.name), ["Content"])
    }

    func testNoHeadingsYieldsEmpty() {
        XCTAssertTrue(MarkdownOutline.headings(in: "just prose\nmore prose\n").isEmpty)
    }
}
