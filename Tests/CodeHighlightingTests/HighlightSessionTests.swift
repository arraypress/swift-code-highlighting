//
//  HighlightSessionTests.swift
//  Tests for the incremental HighlightSession.
//
//  Like TreeSitterHighlighterTests these run HEADLESS: the grammar language
//  pointers link fine under `swift test` but the highlights.scm resource
//  bundles (Bundle.main) may not resolve — so the sessions here are built via
//  the internal seams (`tsLanguage(for:)` + `HighlightSession(grammar:)`) with
//  small hand-compiled queries. What they pin down:
//
//   1. the session parses ONCE and then highlights repeatedly from the cached
//      tree (asserted via the fullParseCount / incrementalParseCount seams) —
//      the whole point of the class vs. the stateless highlighter,
//   2. noteEdit's InputEdit math: an insertion BEFORE existing tokens must
//      shift every capture range (the classic incremental-parsing bug is
//      colors landing at the PRE-edit offsets),
//   3. the UTF-16×2 byte rule through edits containing CJK + emoji (where
//      utf8-based or un-doubled byte math diverges),
//   4. invalidate() recovering from a tree that was desynced deliberately
//      (text swapped under the session without a noteEdit),
//   5. inconsistent noteEdit calls dropping the tree instead of corrupting it.
//

import XCTest
import AppKit
import CodeLanguage
import SwiftTreeSitter
@testable import CodeHighlighting

/// Mirrors the mock in TreeSitterHighlighterTests: one distinct color per kind
/// so capture→color assertions are exact.
private struct SessionMockColors: TokenColorProviding {
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

final class HighlightSessionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HighlightTheme.colors = SessionMockColors()
    }

    override func tearDown() {
        HighlightTheme.colors = DefaultTokenColors()
        super.tearDown()
    }

    private func colorAt(_ storage: NSTextStorage, _ index: Int) -> NSColor? {
        storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    /// Builds a session around a hand-compiled query for `language` — the
    /// bundle-free path (headless `swift test` has no .scm resource bundles).
    private func makeSession(_ queryText: String,
                             language: CodeLanguage.Language = .python) throws -> HighlightSession {
        let lang = try XCTUnwrap(TreeSitterHighlighter.tsLanguage(for: language), "grammar not loaded")
        let query = try Query(language: lang, data: Data(queryText.utf8))
        return HighlightSession(grammar: .init(language: lang, highlights: query, injections: nil))
    }

    /// Highlights `text` into a fresh storage over `clip` (default: the whole
    /// document) and returns the storage.
    private func paint(_ session: HighlightSession, _ text: String, clip: NSRange? = nil) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        session.highlight(in: storage, text: text,
                          clip: clip ?? NSRange(location: 0, length: storage.length))
        return storage
    }

    // MARK: - 1. Parse once, highlight many

    func testSessionParsesOnceAcrossRepeatedHighlights() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        let session = try makeSession("((identifier) @variable)")
        let text = "alpha = 1\nbeta = 2\ngamma = 3\n"
        let ns = text as NSString

        // Simulate scrolling: repeated viewport-clipped highlights of the SAME text.
        let s1 = paint(session, text)
        XCTAssertEqual(session.fullParseCount, 1, "first highlight parses once")

        let betaLine = ns.lineRange(for: ns.range(of: "beta"))
        let s2 = paint(session, text, clip: betaLine)
        let s3 = paint(session, text)
        XCTAssertEqual(session.fullParseCount, 1, "subsequent highlights reuse the cached tree — no re-parse")
        XCTAssertEqual(session.incrementalParseCount, 0, "no edits, no incremental parses")

        // And the cached-tree passes still color correctly.
        XCTAssertEqual(colorAt(s1, ns.range(of: "alpha").location), .cyan)
        XCTAssertEqual(colorAt(s3, ns.range(of: "gamma").location), .cyan)
        // The clipped pass paints only inside its clip.
        XCTAssertEqual(colorAt(s2, ns.range(of: "beta").location), .cyan, "token inside the clip is colored")
        XCTAssertNil(colorAt(s2, ns.range(of: "alpha").location), "nothing painted outside the viewport clip")
    }

    func testNoteEditBeforeFirstHighlightIsNoOp() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        let session = try makeSession("((identifier) @variable)")
        // No tree yet: nothing to edit, nothing to parse.
        session.noteEdit(range: NSRange(location: 0, length: 0), replacementLength: 4, newText: "x = 1\n")
        XCTAssertEqual(session.fullParseCount, 0)
        XCTAssertEqual(session.incrementalParseCount, 0)
        // The first highlight then performs the one full parse and is correct.
        let s = paint(session, "x = 1\n")
        XCTAssertEqual(session.fullParseCount, 1)
        XCTAssertEqual(colorAt(s, 0), .cyan)
    }

    // MARK: - 2. noteEdit: insertion BEFORE existing tokens shifts capture ranges

    func testNoteEditInsertionBeforeTokensShiftsHighlightRanges() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        let session = try makeSession("((identifier) @variable)")
        let old = "alpha = 1\nbeta = 2\n"
        _ = paint(session, old)
        XCTAssertEqual(session.fullParseCount, 1)

        // Insert a whole line at the very top — every existing token shifts.
        let inserted = "# note héllo 🙂\n"
        let new = inserted + old
        session.noteEdit(range: NSRange(location: 0, length: 0),
                         replacementLength: (inserted as NSString).length,
                         newText: new)
        XCTAssertEqual(session.incrementalParseCount, 1, "the edit re-parsed incrementally")
        XCTAssertEqual(session.fullParseCount, 1, "…and did NOT fall back to a full parse")

        let s = paint(session, new)
        XCTAssertEqual(session.fullParseCount, 1, "highlight after the edit still reuses the cached tree")
        let ns = new as NSString
        for word in ["alpha", "beta"] {
            let r = ns.range(of: word)
            XCTAssertEqual(colorAt(s, r.location), .cyan, "`\(word)` colored at its SHIFTED start")
            XCTAssertEqual(colorAt(s, NSMaxRange(r) - 1), .cyan, "`\(word)` colored to its SHIFTED end")
        }
        XCTAssertEqual(colorAt(s, 0), .black,
                       "the inserted comment is no identifier — stale pre-shift ranges would paint it cyan")
    }

    // MARK: - 3. CJK / emoji edits (the UTF-16×2 byte math through InputEdit)

    func testNoteEditWithCJKAndEmojiKeepsByteMathExact() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        let session = try makeSession("((identifier) @variable)")
        let old = "a = \"日本語\"\nbeta = 2\ngamma = 3\n"
        _ = paint(session, old)

        // Replace CJK (3 UTF-16 units, 9 UTF-8 bytes) with emoji (4 UTF-16
        // units, 8 UTF-8 bytes): UTF-16 length grows by 1 while the UTF-8
        // length SHRINKS — utf8-based InputEdit math shifts the wrong way.
        let oldNS = old as NSString
        let replaced = oldNS.range(of: "日本語")
        let new = oldNS.replacingCharacters(in: replaced, with: "🙂🙂")
        session.noteEdit(range: replaced, replacementLength: ("🙂🙂" as NSString).length, newText: new)

        var s = paint(session, new)
        var ns = new as NSString
        XCTAssertEqual(colorAt(s, 0), .cyan, "`a` before the edit site is untouched")
        for word in ["beta", "gamma"] {
            let r = ns.range(of: word)
            XCTAssertEqual(colorAt(s, r.location), .cyan, "`\(word)` colored at its post-edit position")
            XCTAssertEqual(colorAt(s, NSMaxRange(r) - 1), .cyan)
        }

        // Second, sequential edit: delete the whole `beta` line (replacement
        // shorter than the replaced range) — `gamma` shifts back left.
        let betaLine = ns.lineRange(for: ns.range(of: "beta"))
        let newer = ns.replacingCharacters(in: betaLine, with: "")
        session.noteEdit(range: betaLine, replacementLength: 0, newText: newer)

        s = paint(session, newer)
        ns = newer as NSString
        let gamma = ns.range(of: "gamma")
        XCTAssertEqual(colorAt(s, gamma.location), .cyan, "`gamma` colored after shifting LEFT past a deletion")
        XCTAssertEqual(colorAt(s, NSMaxRange(gamma) - 1), .cyan)
        XCTAssertEqual(session.fullParseCount, 1, "both edits stayed on the incremental path")
        XCTAssertEqual(session.incrementalParseCount, 2)
    }

    // MARK: - 4. invalidate() recovers from a desynced tree

    func testInvalidateRecoversFromDesyncedTree() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        let session = try makeSession("((identifier) @variable)")
        let textA = "alpha = 1\n"
        _ = paint(session, textA)

        // Swap the text under the session WITHOUT noteEdit: the cached tree is
        // now stale, so captures land at text-A offsets inside text B.
        let textB = "# just a comment\nalpha = 1\n"
        let stale = paint(session, textB)
        let nsB = textB as NSString
        XCTAssertEqual(colorAt(stale, 0), .cyan,
                       "desynced: the stale tree paints text-A's identifier offsets onto the comment")
        XCTAssertEqual(colorAt(stale, nsB.range(of: "alpha").location), .black,
                       "desynced: the real identifier at its new offset is missed")

        // invalidate() drops the tree; the next highlight re-parses and is correct.
        session.invalidate()
        let fresh = paint(session, textB)
        XCTAssertEqual(session.fullParseCount, 2, "recovery cost exactly one fresh parse")
        XCTAssertEqual(colorAt(fresh, nsB.range(of: "alpha").location), .cyan)
        XCTAssertEqual(colorAt(fresh, 0), .black, "the comment is clean again")
    }

    // MARK: - 5. Inconsistent noteEdit drops the tree instead of corrupting it

    func testInconsistentNoteEditDropsTreeAndNextHighlightReparses() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        let session = try makeSession("((identifier) @variable)")
        let text = "alpha = 1\n"
        _ = paint(session, text)
        XCTAssertEqual(session.fullParseCount, 1)

        // Lengths don't reconcile (claims +5 units but hands back the same text).
        session.noteEdit(range: NSRange(location: 0, length: 0), replacementLength: 5, newText: text)
        XCTAssertEqual(session.incrementalParseCount, 0, "an inconsistent edit must not be applied")

        let s = paint(session, text)
        XCTAssertEqual(session.fullParseCount, 2, "the dropped tree is rebuilt with one full parse")
        XCTAssertEqual(colorAt(s, (text as NSString).range(of: "alpha").location), .cyan)

        // Out-of-bounds replaced range is rejected the same way.
        session.noteEdit(range: NSRange(location: 500, length: 3), replacementLength: 3, newText: text)
        XCTAssertEqual(session.incrementalParseCount, 0)
        _ = paint(session, text)
        XCTAssertEqual(session.fullParseCount, 3)
    }

    // MARK: - API edges

    func testInitReturnsNilForUnsupportedLanguage() {
        // plainText never has a grammar — mirrors supports(_:).
        XCTAssertNil(HighlightSession(language: .plainText))
    }

    func testHighlightEmptyStorageAndOutOfBoundsClipAreSafe() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        let session = try makeSession("((identifier) @variable)")
        // Empty document: nothing to paint, must not crash.
        _ = paint(session, "")
        // The empty doc's tree is now cached; drop it before switching texts
        // (a text swap without noteEdit is the documented desync case).
        session.invalidate()
        // Clip entirely past the end: clamped away, must not throw.
        let storage = NSTextStorage(string: "x = 1\n")
        session.highlight(in: storage, text: "x = 1\n", clip: NSRange(location: 100, length: 50))
        // A partially overlapping clip is trimmed to the storage.
        session.highlight(in: storage, text: "x = 1\n", clip: NSRange(location: 0, length: 999))
        XCTAssertEqual(colorAt(storage, 0), .cyan)
    }
}
