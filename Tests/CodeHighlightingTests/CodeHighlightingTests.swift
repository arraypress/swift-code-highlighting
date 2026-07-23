//
//  CodeHighlightingTests.swift
//  Tests for SwiftCodeHighlighting
//
//  Created by David Sherlock on 7/9/26.
//

import XCTest
import AppKit
import CodeLanguage
@testable import CodeHighlighting

/// Distinct color per role so tests can assert which role a range received.
private struct MockColors: TokenColorProviding {
    static let map: [TokenKind: NSColor] = [
        .comment: .red, .string: .green, .keyword: .blue, .type: .purple,
        .number: .orange, .function: .brown, .attribute: .magenta,
        .property: .systemPink, .added: .cyan, .removed: .yellow,
    ]
    func color(for kind: TokenKind) -> NSColor { MockColors.map[kind]! }
    var foreground: NSColor { .black }
}

final class CodeHighlightingTests: XCTestCase {

    private func colorAt(_ storage: NSTextStorage, _ index: Int) -> NSColor? {
        storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    private func highlighted(_ text: String, _ language: Language) -> NSTextStorage {
        let hl = SyntaxHighlighter(language: language, colors: MockColors())
        let storage = NSTextStorage(string: text)
        hl.highlight(storage, in: NSRange(location: 0, length: storage.length))
        return storage
    }

    func testDiffPatchRoles() {
        let text = """
        commit 1234abcd
        Author: Dev <d@example.com>
        diff --git a/x.swift b/x.swift
        index 1111111..2222222 100644
        --- a/x.swift
        +++ b/x.swift
        @@ -1,2 +1,2 @@ func body
         context line
        -let a = 1
        +let a = 2
        --- deleted sql comment
        +++ added sql comment
        """
        let s = highlighted(text, .diff)
        let ns = text as NSString
        XCTAssertEqual(colorAt(s, ns.range(of: "commit").location), .red, "commit header is chrome")
        XCTAssertEqual(colorAt(s, ns.range(of: "diff --git").location), .red, "diff header is chrome")
        XCTAssertEqual(colorAt(s, ns.range(of: "--- a/x.swift").location), .red, "old-file header is chrome")
        XCTAssertEqual(colorAt(s, ns.range(of: "+++ b/x.swift").location), .red, "new-file header is chrome")
        XCTAssertEqual(colorAt(s, ns.range(of: "@@ -1,2").location), .brown, "hunk header")
        XCTAssertEqual(colorAt(s, ns.range(of: "-let a = 1").location), .yellow, "removed line")
        XCTAssertEqual(colorAt(s, ns.range(of: "+let a = 2").location), .cyan, "added line")
        XCTAssertEqual(colorAt(s, ns.range(of: " context line").location), .black, "context stays plain")
        // A removed/added line whose CONTENT starts with -- / ++ is not a file header.
        XCTAssertEqual(colorAt(s, ns.range(of: "--- deleted sql comment").location), .yellow,
                       "removed `-- …` line is a removal, not a header")
        XCTAssertEqual(colorAt(s, ns.range(of: "+++ added sql comment").location), .cyan,
                       "added `++ …` line is an addition, not a header")
    }

    func testSwiftKeywordCommentAndNumber() {
        let text = "let x = 5 // note"
        let s = highlighted(text, .swift)
        let ns = text as NSString
        XCTAssertEqual(colorAt(s, 0), .blue, "`let` keyword")
        XCTAssertEqual(colorAt(s, ns.range(of: "5").location), .orange, "number")
        XCTAssertEqual(colorAt(s, ns.range(of: "//").location), .red, "comment")
    }

    func testSwiftStringColored() {
        let text = "let s = \"hi\""
        let s = highlighted(text, .swift)
        let idx = (text as NSString).range(of: "\"hi\"").location
        XCTAssertEqual(colorAt(s, idx), .green, "string literal")
    }

    func testSCSSVariablesCommentsAndKeywords() {
        // SCSS routes to the regex tier (the CSS tree-sitter grammar turns
        // `$vars` into ERROR nodes), so the dedicated rule set must cover
        // what the grammar tier can't.
        let text = """
        // tokens
        $primary: #336699;
        .btn { color: $primary; }
        @include flex(column);
        """
        let s = highlighted(text, .scss)
        let ns = text as NSString
        XCTAssertEqual(colorAt(s, ns.range(of: "// tokens").location), .red, "line comment")
        XCTAssertEqual(colorAt(s, ns.range(of: "$primary").location), .systemPink, "declared $variable")
        XCTAssertEqual(colorAt(s, ns.range(of: "#336699").location), .orange, "hex color")
        XCTAssertEqual(colorAt(s, ns.range(of: "@include").location), .blue, "SCSS at-keyword")
        XCTAssertEqual(colorAt(s, ns.range(of: "color").location), .purple, "property name")
        XCTAssertEqual(colorAt(s, ns.range(of: ".btn").location), .brown, "class selector")
    }

    func testLessVariablesKeepAtKeywordsDistinct() {
        let text = "@primary: #336699;\n@media (min-width: 600px) { .a { color: @primary; } }"
        let s = highlighted(text, .less)
        let ns = text as NSString
        XCTAssertEqual(colorAt(s, ns.range(of: "@primary").location), .systemPink, "Less @variable")
        XCTAssertEqual(colorAt(s, ns.range(of: "@media").location), .blue,
                       "a known at-keyword repaints over the generic @var rule")
    }

    func testIndentedSassVariablesColor() {
        let text = "$x: 4px\n.a\n  margin: $x\n"
        let s = highlighted(text, .sass)
        let ns = text as NSString
        XCTAssertEqual(colorAt(s, ns.range(of: "$x").location), .systemPink, "indented-syntax $variable")
        XCTAssertEqual(colorAt(s, ns.range(of: "margin").location), .purple, "property name without braces")
    }

    func testFamilyFallbackColorsCLikeKeyword() {
        // Scala has no dedicated rule set → routed through the cLike family fallback.
        let s = highlighted("class Foo { }", .scala)
        XCTAssertEqual(colorAt(s, 0), .blue, "`class` via cLike family")
    }

    func testFamilyFallbackColorsShellComment() {
        // Fish has no dedicated set → shellLike family (# comments).
        let text = "echo hi # a comment"
        let s = highlighted(text, .fish)
        let idx = (text as NSString).range(of: "#").location
        XCTAssertEqual(colorAt(s, idx), .red, "# comment via shellLike family")
    }

    func testForegroundAppliedToPlainText() {
        let s = highlighted("just some text", .plainText)
        XCTAssertEqual(colorAt(s, 0), .black, "default foreground")
    }

    func testEmptyStorageDoesNotCrash() {
        let hl = SyntaxHighlighter(language: .swift, colors: MockColors())
        let storage = NSTextStorage(string: "")
        hl.highlight(storage, in: NSRange(location: 0, length: 0))   // must be a no-op, not a crash
    }

    func testOutOfBoundsEditedRangeIsClampedLikeTheTreeSitterTier() {
        // The two CodeHighlighter tiers are interchangeable, so a stale range
        // that TreeSitterHighlighter tolerates (clamped) must not raise
        // NSRangeException here either.
        let hl = SyntaxHighlighter(language: .swift, colors: MockColors())
        let storage = NSTextStorage(string: "let x")
        hl.highlight(storage, in: NSRange(location: 999, length: 5))
        XCTAssertEqual(colorAt(storage, 0), .blue, "clamped to the last line and highlighted")
    }

    // MARK: - Strings vs. comments (single left-to-right scan)

    func testCommentMarkerInsideStringStaysString() {
        // `//` inside a string literal must not repaint the rest of the line.
        let text = "let url = \"https://example.com\""
        let s = highlighted(text, .swift)
        let ns = text as NSString
        XCTAssertEqual(colorAt(s, ns.range(of: "\"https").location), .green, "string start")
        XCTAssertEqual(colorAt(s, ns.range(of: "//example").location), .green, "`//` inside the string stays string-colored")
    }

    func testTrailingCommentAfterStringIsStillComment() {
        let text = "let s = \"a\" // note"
        let s = highlighted(text, .swift)
        let ns = text as NSString
        XCTAssertEqual(colorAt(s, ns.range(of: "\"a\"").location), .green, "string literal")
        XCTAssertEqual(colorAt(s, ns.range(of: "// note").location), .red, "real trailing comment")
    }

    func testQuoteInsideCommentStaysComment() {
        let text = "// say \"hi\" ok"
        let s = highlighted(text, .swift)
        let ns = text as NSString
        XCTAssertEqual(colorAt(s, 0), .red, "comment start")
        XCTAssertEqual(colorAt(s, ns.range(of: "\"hi\"").location), .red, "quotes inside a comment stay comment-colored")
        XCTAssertEqual(colorAt(s, ns.range(of: "ok").location), .red, "text after the quotes stays comment-colored")
    }

    func testSQLDashesInsideStringStayString() {
        let text = "SELECT 'a--b' FROM t"
        let s = highlighted(text, .sql)
        let ns = text as NSString
        XCTAssertEqual(colorAt(s, ns.range(of: "--b").location), .green, "`--` inside a SQL string stays string-colored")
    }

    func testPythonHashInsideStringThenRealComment() {
        let text = "path = \"a#b\"  # real"
        let s = highlighted(text, .python)
        let ns = text as NSString
        XCTAssertEqual(colorAt(s, ns.range(of: "#b").location), .green, "`#` inside the string stays string-colored")
        XCTAssertEqual(colorAt(s, ns.range(of: "# real").location), .red, "real trailing comment")
    }

    // MARK: - Hover doc-comment extraction (language-aware markers)

    func testDocCommentIgnoresCPreprocessorLines() {
        let text = "#include <stdio.h>\n#define MAX_USERS 10\nint init_users(void) {}\n"
        let ns = text as NSString
        let loc = ns.range(of: "int init_users").location
        XCTAssertEqual(TreeSitterHighlighter.docComment(above: loc, in: ns, language: .c), "",
                       "preprocessor directives are not documentation in C")
    }

    func testDocCommentReadsSlashDocsInC() {
        let text = "/// Initializes the user table.\nint init_users(void) {}\n"
        let ns = text as NSString
        let loc = ns.range(of: "int init_users").location
        XCTAssertEqual(TreeSitterHighlighter.docComment(above: loc, in: ns, language: .c),
                       "Initializes the user table.")
    }

    func testDocCommentReadsHashDocsInPython() {
        let text = "# Adds two numbers.\ndef add(a, b):\n    return a + b\n"
        let ns = text as NSString
        let loc = ns.range(of: "def add").location
        XCTAssertEqual(TreeSitterHighlighter.docComment(above: loc, in: ns, language: .python),
                       "Adds two numbers.")
    }

    func testDocCommentSkipsShebang() {
        let text = "#!/usr/bin/env python3\ndef main():\n    pass\n"
        let ns = text as NSString
        let loc = ns.range(of: "def main").location
        XCTAssertEqual(TreeSitterHighlighter.docComment(above: loc, in: ns, language: .python), "",
                       "a shebang is not documentation")
    }

    // MARK: - ProjectSymbolIndex build supersession

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testBuildAfterInvalidateIsNotDropped() {
        // Project switch while a build is in flight: invalidate() + build(newRoot)
        // must actually run the second build (it used to be silently dropped).
        let idx = ProjectSymbolIndex()
        let dirA = makeTempDir(), dirB = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dirA); try? FileManager.default.removeItem(at: dirB) }
        let first = expectation(description: "first build completes")
        let second = expectation(description: "second build completes")
        idx.build(root: dirA) { first.fulfill() }
        idx.invalidate()                          // switch projects mid-build
        idx.build(root: dirB) { second.fulfill() }
        wait(for: [first, second], timeout: 10)
        XCTAssertTrue(idx.isBuilt, "the second build must install its index")
    }

    func testSupersededBuildDoesNotInstallStaleIndex() {
        let idx = ProjectSymbolIndex()
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let done = expectation(description: "superseded build still completes")
        idx.build(root: dir) { done.fulfill() }
        idx.invalidate()                          // supersedes the in-flight build
        wait(for: [done], timeout: 10)
        XCTAssertFalse(idx.isBuilt, "a superseded build must not install its stale results")
    }
}
