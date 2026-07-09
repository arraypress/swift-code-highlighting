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
}
