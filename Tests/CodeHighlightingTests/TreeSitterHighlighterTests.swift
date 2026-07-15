//
//  TreeSitterHighlighterTests.swift
//  Tests for the tree-sitter path of SwiftCodeHighlighting.
//
//  These run HEADLESS: the grammar language pointers load fine under
//  `swift test`, but the highlights.scm resource bundles (Bundle.main) do not —
//  so instead of the bundled queries these tests compile their own small
//  queries (via the internal `tsLanguage(for:)` + `applyQuery` seams) and
//  exercise the internal math directly:
//
//   1. the UTF-16×2 byte-offset rule (tree-sitter byte offset = UTF-16 index
//      × 2, NOT `utf8.count`) — proven with CJK / emoji / combining characters,
//      each of which breaks a different wrong implementation:
//        - CJK      (UTF-8: 3 bytes, UTF-16LE: 2 bytes) → catches utf8.count
//        - emoji    (UTF-16 length 2 → 4 bytes)         → catches a missing ×2
//        - combining marks                              → catch grapheme-based math
//   2. capture precedence — later query patternIndex wins,
//   3. range clamping at document/clip edges.
//

import XCTest
import AppKit
import CodeLanguage
import SwiftTreeSitter
@testable import CodeHighlighting

/// Covers every TokenKind so capture→color mapping can be asserted exactly.
private struct AllKindMockColors: TokenColorProviding {
    func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .comment:   return .red
        case .string:    return .green
        case .keyword:   return .blue
        case .type:      return .purple
        case .number:    return .orange
        case .function:  return .brown
        case .attribute: return .magenta
        case .variable:  return .cyan
        case .property:  return .yellow
        }
    }
    var foreground: NSColor { .black }
}

final class TreeSitterHighlighterTests: XCTestCase {

    /// A prefix that shifts UTF-8, UTF-16, and grapheme counts apart:
    /// - "日本語" — 3 CJK chars (UTF-8 9 bytes vs UTF-16LE 6 bytes),
    /// - "🙂"    — 1 emoji (UTF-16 length 2),
    /// - "cafe\u{0301}" — a combining acute (1 grapheme, 2 UTF-16 units).
    private static let unicodePrefix = "note = \"日本語 🙂 cafe\u{0301}\"\n"

    override func setUp() {
        super.setUp()
        HighlightTheme.colors = AllKindMockColors()
    }

    override func tearDown() {
        HighlightTheme.colors = DefaultTokenColors()
        super.tearDown()
    }

    private func colorAt(_ storage: NSTextStorage, _ index: Int) -> NSColor? {
        storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    // MARK: - 1. UTF-16 ×2 byte-offset rule (selection/offset → tree-sitter bytes)

    func testEnclosingNodeRangeAfterUnicodePrefixJSON() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.json), "JSON grammar failed to load")
        // CJK keys BEFORE the token under test: any utf8-based or un-doubled
        // offset math would land the descendant lookup on the wrong node.
        let text = "{\"名前\": \"テスト🙂\", \"count\": 42}"
        let ns = text as NSString
        let selection = ns.range(of: "42")
        // "42" is exactly the number node, so expansion must climb to the pair.
        let expanded = TreeSitterHighlighter.enclosingNodeRange(selection: selection, text: text, language: .json)
        XCTAssertEqual(expanded, ns.range(of: "\"count\": 42"),
                       "expanding from the value must select the enclosing pair, at the correct UTF-16 range")
    }

    func testEnclosingNodeRangeAfterUnicodePrefixPython() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        let text = Self.unicodePrefix + "def f(x):\n    return x + 1\n"
        let ns = text as NSString
        let selection = ns.range(of: "x + 1")
        let expanded = TreeSitterHighlighter.enclosingNodeRange(selection: selection, text: text, language: .python)
        XCTAssertEqual(expanded, ns.range(of: "return x + 1"),
                       "the binary expression expands to the return statement despite CJK/emoji earlier in the buffer")
    }

    func testEnclosingNodeRangeBeforeUnicodeSuffix() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        // Unicode AFTER the token: the node's end byte must also convert cleanly.
        let text = "def f(x):\n    return x + 1\n" + Self.unicodePrefix
        let ns = text as NSString
        let expanded = TreeSitterHighlighter.enclosingNodeRange(
            selection: ns.range(of: "x + 1"), text: text, language: .python)
        XCTAssertEqual(expanded, ns.range(of: "return x + 1"))
    }

    func testSiblingRangeAcrossCJKPairs() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.json), "JSON grammar failed to load")
        let text = "{\"キー\": 1, \"値\": 2}"
        let ns = text as NSString
        let first = ns.range(of: "\"キー\": 1")
        let next = TreeSitterHighlighter.siblingRange(of: first, text: text, language: .json, forward: true)
        XCTAssertEqual(next, ns.range(of: "\"値\": 2"), "next named sibling of the first pair")
        let prev = TreeSitterHighlighter.siblingRange(of: ns.range(of: "\"値\": 2"),
                                                      text: text, language: .json, forward: false)
        XCTAssertEqual(prev, first, "previous named sibling walks back to the first pair")
    }

    func testBreadcrumbsAfterUnicodeComment() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        let text = "# コメント 🙂 cafe\u{0301}\nclass Greeter:\n    def hello(self):\n        pass\n"
        let ns = text as NSString
        let crumbs = TreeSitterHighlighter.breadcrumbs(at: ns.range(of: "pass").location,
                                                       text: text, language: .python)
        // Both the offset→byte conversion (×2) and the name-node byte→NSRange
        // conversion must be exact or the names come back garbled/empty.
        XCTAssertEqual(crumbs, ["Greeter", "hello"])
    }

    func testSymbolRangesWithUnicodeBeforeAndBetweenDefinitions() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        let text = Self.unicodePrefix
            + "def alpha():\n    pass\n"
            + "tag = \"中文 🚀\"\n"
            + "def beta():\n    pass\n"
        let ns = text as NSString
        let syms = TreeSitterHighlighter.symbols(in: text, language: .python)
        XCTAssertEqual(syms.map(\.name), ["alpha", "beta"], "ordered by position")
        XCTAssertEqual(syms[0].range, ns.range(of: "alpha"), "range correct after the unicode prefix")
        XCTAssertEqual(syms[1].range, ns.range(of: "beta"), "range correct after a second unicode run")
        XCTAssertEqual(syms[0].line, 2, "1-based line after the prefix line")
        XCTAssertEqual(syms[1].line, 5)
        // The name is substring'd from the buffer with the converted range —
        // a mis-converted range would slice mid-character or the wrong text.
        XCTAssertEqual(ns.substring(with: syms[1].range), "beta")
    }

    // MARK: - Out-of-bounds selections/offsets at document edges

    func testEnclosingNodeRangeOutOfBoundsReturnsNil() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        let text = "x = 1\n"
        let len = (text as NSString).length
        XCTAssertNil(TreeSitterHighlighter.enclosingNodeRange(
            selection: NSRange(location: len, length: 5), text: text, language: .python))
        XCTAssertNil(TreeSitterHighlighter.enclosingNodeRange(
            selection: NSRange(location: len + 10, length: 1), text: text, language: .python))
    }

    func testBreadcrumbsBeyondEndReturnsEmpty() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        let text = "def f():\n    pass\n"
        let len = (text as NSString).length
        XCTAssertEqual(TreeSitterHighlighter.breadcrumbs(at: len + 3, text: text, language: .python), [])
    }

    // MARK: - 2. Capture precedence: later patternIndex wins

    /// Compiles `queryText` against a bundled grammar, parses `text`, and runs
    /// the real applyQuery over a fresh storage. Colors come from the mock theme.
    private func runQuery(_ queryText: String, on text: String,
                          language: CodeLanguage.Language = .python,
                          offset: Int = 0, clip: NSRange? = nil,
                          storageText: String? = nil) throws -> NSTextStorage {
        let lang = try XCTUnwrap(TreeSitterHighlighter.tsLanguage(for: language), "grammar not loaded")
        let query = try Query(language: lang, data: Data(queryText.utf8))
        let parser = Parser()
        try parser.setLanguage(lang)
        let tree = try XCTUnwrap(parser.parse(text))
        let storage = NSTextStorage(string: storageText ?? text)
        let clipRange = clip ?? NSRange(location: 0, length: storage.length)
        MainActor.assumeIsolated {
            TreeSitterHighlighter.applyQuery(query, tree: tree, source: text as NSString,
                                             offset: offset, clip: clipRange, into: storage)
        }
        return storage
    }

    func testLaterPatternWinsOverEarlierCatchAll() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        let text = "print(value)"
        let ns = text as NSString
        // Pattern 0 captures every identifier as @variable; pattern 1 recaptures
        // them as @function. Later patternIndex must win everywhere.
        let s = try runQuery("((identifier) @variable)\n((identifier) @function)", on: text)
        XCTAssertEqual(colorAt(s, 0), .brown, "`print`: the later @function pattern wins")
        XCTAssertEqual(colorAt(s, ns.range(of: "value").location), .brown, "`value`: later pattern wins too")
    }

    func testEarlierPatternLosesRegardlessOfCaptureName() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        let text = "print(value)"
        // Same query with the pattern order swapped: now @variable is later.
        let s = try runQuery("((identifier) @function)\n((identifier) @variable)", on: text)
        XCTAssertEqual(colorAt(s, 0), .cyan, "swapping pattern order flips the winner — order, not name, decides")
    }

    func testPredicateResolvedPatternWinsOnlyWhereItMatches() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        let text = "print(value)"
        let ns = text as NSString
        // Later pattern is #eq?-restricted to "print": it must beat the
        // catch-all on `print` but leave `value` to the earlier pattern.
        let s = try runQuery("""
            ((identifier) @variable)
            ((identifier) @function (#eq? @function "print"))
            """, on: text)
        XCTAssertEqual(colorAt(s, 0), .brown, "`print` matches the later #eq? pattern")
        XCTAssertEqual(colorAt(s, ns.range(of: "value").location), .cyan,
                       "`value` fails the predicate, so the earlier catch-all keeps it")
    }

    func testApplyHitsSortsByPatternIndexNotArrayOrder() {
        // Precomputed-hit seam: hits supplied out of order must still resolve
        // by patternIndex (ascending application → the highest index paints last).
        let storage = NSTextStorage(string: "abcdef")
        let full = NSRange(location: 0, length: storage.length)
        TreeSitterHighlighter.apply(hits: [
            (range: NSRange(location: 0, length: 6), pattern: 7, color: .brown),
            (range: NSRange(location: 0, length: 6), pattern: 2, color: .cyan),
            (range: NSRange(location: 2, length: 2), pattern: 5, color: .orange),
        ], clip: full, into: storage)
        XCTAssertEqual(colorAt(storage, 0), .brown, "pattern 7 beats pattern 2")
        XCTAssertEqual(colorAt(storage, 2), .brown, "pattern 7 also beats the narrower pattern 5")
        XCTAssertEqual(colorAt(storage, 5), .brown)
    }

    func testInjectionOffsetShiftsHitsIntoHostDocument() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        // The injection path parses an embedded substring and applies it at
        // `offset` in the host storage (host doc has a 10-unit preamble here).
        let sub = "x = 1"
        let host = "#héllo 🙂 " + sub   // preamble is 10 UTF-16 units
        let preamble = (host as NSString).length - (sub as NSString).length
        let s = try runQuery("((identifier) @variable)", on: sub,
                             offset: preamble,
                             clip: NSRange(location: 0, length: (host as NSString).length),
                             storageText: host)
        XCTAssertEqual(colorAt(s, preamble), .cyan, "identifier colored at its shifted host position")
        XCTAssertNil(colorAt(s, 0), "nothing painted inside the preamble")
    }

    // MARK: - 3. Range clamping at document/clip edges

    func testApplyHitsClampsPartialOverlapToClip() {
        let storage = NSTextStorage(string: "hello world")   // length 11
        TreeSitterHighlighter.apply(hits: [
            (range: NSRange(location: 3, length: 6), pattern: 0, color: .red),
        ], clip: NSRange(location: 0, length: 5), into: storage)
        XCTAssertEqual(colorAt(storage, 3), .red)
        XCTAssertEqual(colorAt(storage, 4), .red)
        XCTAssertNil(colorAt(storage, 5), "the part of the hit outside the clip must not be painted")
    }

    func testApplyHitsDropsHitEntirelyOutsideClip() {
        let storage = NSTextStorage(string: "hello world")
        TreeSitterHighlighter.apply(hits: [
            (range: NSRange(location: 6, length: 5), pattern: 0, color: .red),
        ], clip: NSRange(location: 0, length: 5), into: storage)
        for i in 0..<storage.length {
            XCTAssertNil(colorAt(storage, i), "no attribute anywhere for a fully-clipped hit (index \(i))")
        }
    }

    func testApplyHitsOverrunningDocumentEndIsTrimmedNotCrashing() {
        // A hit whose range runs past the end of the storage must be trimmed by
        // the clip intersection — NSTextStorage would throw on an OOB range.
        let storage = NSTextStorage(string: "hello world")   // length 11
        let full = NSRange(location: 0, length: storage.length)
        TreeSitterHighlighter.apply(hits: [
            (range: NSRange(location: 8, length: 10), pattern: 0, color: .green),
        ], clip: full, into: storage)
        XCTAssertEqual(colorAt(storage, 8), .green)
        XCTAssertEqual(colorAt(storage, 10), .green, "painted up to the last character")
    }

    func testApplyHitsZeroLengthAndEmptyStorageAreNoOps() {
        let empty = NSTextStorage(string: "")
        TreeSitterHighlighter.apply(hits: [
            (range: NSRange(location: 0, length: 5), pattern: 0, color: .red),
        ], clip: NSRange(location: 0, length: 0), into: empty)   // must not throw
        let storage = NSTextStorage(string: "abc")
        TreeSitterHighlighter.apply(hits: [
            (range: NSRange(location: 1, length: 0), pattern: 0, color: .red),
        ], clip: NSRange(location: 0, length: 3), into: storage)
        XCTAssertNil(colorAt(storage, 1), "zero-length hit paints nothing")
    }

    func testHighlightClampsEditedRangeBeyondDocumentEnd() throws {
        let hl = try XCTUnwrap(TreeSitterHighlighter(language: .python), "grammar not loaded")
        let storage = NSTextStorage(string: "x = 1\ny = 2")
        // Both the location and the max of the edited range overrun the document.
        hl.highlight(storage, in: NSRange(location: 50, length: 25))       // fully past the end
        hl.highlight(storage, in: NSRange(location: 8, length: 100))      // max overruns
        hl.highlight(storage, in: NSRange(location: 0, length: storage.length))
        XCTAssertNotNil(colorAt(storage, storage.length - 1), "foreground reset reached the last character")
    }

    func testHighlightEmptyStorageIsNoOp() throws {
        let hl = try XCTUnwrap(TreeSitterHighlighter(language: .python), "grammar not loaded")
        let storage = NSTextStorage(string: "")
        hl.highlight(storage, in: NSRange(location: 0, length: 0))   // must not crash
        XCTAssertEqual(storage.length, 0)
    }

    func testQueryHitsOnUnicodeContentLandOnTokensNotInsideGlyphs() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        // End-to-end: capture ranges over a unicode-laden buffer come back as
        // exact UTF-16 NSRanges (SwiftTreeSitter byte→UTF-16 must divide by 2).
        let text = Self.unicodePrefix + "result = compute(data)\n"
        let ns = text as NSString
        let s = try runQuery("((identifier) @variable)", on: text)
        for word in ["note", "result", "compute", "data"] {
            let r = ns.range(of: word)
            XCTAssertEqual(colorAt(s, r.location), .cyan, "`\(word)` starts colored")
            XCTAssertEqual(colorAt(s, NSMaxRange(r) - 1), .cyan, "`\(word)` ends colored")
        }
        let stringStart = ns.range(of: "\"日本語").location
        XCTAssertNil(colorAt(s, stringStart), "the string literal is not an identifier — nothing bleeds into it")
    }
}
