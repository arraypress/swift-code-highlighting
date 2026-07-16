//
//  CustomLanguageTests.swift
//  Tests for SwiftCodeHighlighting
//
//  CustomLanguageDefinition: decoding (with readable errors), rule building,
//  and end-to-end highlighting through SyntaxHighlighter(custom:colors:),
//  driven by the reference JSFX fixture (Resources/jsfx.json).
//
//  Created by David Sherlock on 7/17/26.
//

import XCTest
import AppKit
@testable import CodeHighlighting

/// Distinct color per role so tests can assert which role a range received.
private struct Palette: TokenColorProviding {
    static let map: [TokenKind: NSColor] = [
        .comment: .red, .string: .green, .keyword: .blue, .type: .purple,
        .number: .orange, .function: .brown, .attribute: .magenta,
        .variable: .cyan, .property: .yellow,
    ]
    func color(for kind: TokenKind) -> NSColor { Palette.map[kind]! }
    var foreground: NSColor { .black }
}

final class CustomLanguageTests: XCTestCase {

    // MARK: - Helpers

    private func colorAt(_ storage: NSTextStorage, _ index: Int) -> NSColor? {
        storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    private func highlighted(_ text: String, _ definition: CustomLanguageDefinition) -> NSTextStorage {
        let hl = SyntaxHighlighter(custom: definition, colors: Palette())
        let storage = NSTextStorage(string: text)
        hl.highlight(storage, in: NSRange(location: 0, length: storage.length))
        return storage
    }

    private func jsfxData() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "jsfx", withExtension: "json"),
                                "jsfx.json fixture must be bundled with the test target")
        return try Data(contentsOf: url)
    }

    private func jsfxDefinition() throws -> CustomLanguageDefinition {
        try CustomLanguageDefinition.decode(from: jsfxData()).get()
    }

    // MARK: - Decoding the JSFX fixture

    func testDecodeJSFXFixture() throws {
        let def = try jsfxDefinition()
        XCTAssertEqual(def.name, "JSFX")
        XCTAssertEqual(def.extensions, ["jsfx"])
        XCTAssertEqual(def.lineComment, "//")
        XCTAssertEqual(def.blockCommentStart, "/*")
        XCTAssertEqual(def.blockCommentEnd, "*/")
        XCTAssertEqual(def.stringDelimiters, ["\""])
        XCTAssertEqual(def.caseInsensitive, true)
        XCTAssertEqual(def.numbers, true)
        XCTAssertEqual(def.functionCalls, true)
        XCTAssertTrue(def.keywords?.contains("function") == true)
        XCTAssertTrue(def.constants?.contains("srate") == true)
        XCTAssertEqual(def.patterns?.count, 7)
        XCTAssertNil(def.validationError, "the reference fixture must validate cleanly")
        XCTAssertTrue(def.patterns?.allSatisfy { $0.tokenKind != nil } == true,
                      "every fixture pattern kind must be a known kind")
    }

    // MARK: - Highlighting JSFX end to end

    private let jsfxSnippet = """
    desc:Simple gain
    slider1:0<0,2,0.01>Gain
    in_pin:left input

    @init
    gain = 2 ^ (slider1 / 6.02); // convert dB
    attack = $x10 + $'A';
    rate = srate;

    @sample
    /* per-sample block */
    spl0 = spl0 * gain;
    spl1 = min(spl1 * gain, 1.0);
    msg = "https://example.com // not a comment";

    function process(x) local(y) (
      y = x;
    );
    """

    func testJSFXHeaderDirectivesAndSectionMarkers() throws {
        let s = highlighted(jsfxSnippet, try jsfxDefinition())
        let ns = jsfxSnippet as NSString
        XCTAssertEqual(colorAt(s, ns.range(of: "desc:").location), .blue, "desc: header directive → keyword")
        XCTAssertEqual(colorAt(s, ns.range(of: "slider1:").location), .blue, "slider1: header directive → keyword")
        XCTAssertEqual(colorAt(s, ns.range(of: "in_pin:").location), .blue, "in_pin: header directive → keyword")
        XCTAssertEqual(colorAt(s, ns.range(of: "@init").location), .magenta, "@init section marker → attribute")
        XCTAssertEqual(colorAt(s, ns.range(of: "@sample").location), .magenta, "@sample section marker → attribute")
    }

    func testJSFXKeywordsVariablesConstantsAndCalls() throws {
        let s = highlighted(jsfxSnippet, try jsfxDefinition())
        let ns = jsfxSnippet as NSString
        XCTAssertEqual(colorAt(s, ns.range(of: "function").location), .blue, "EEL2 keyword")
        XCTAssertEqual(colorAt(s, ns.range(of: "spl0").location), .cyan, "spl0 sample register → variable")
        XCTAssertEqual(colorAt(s, ns.range(of: "slider1 /").location), .cyan, "slider1 in code (no colon) → variable")
        XCTAssertEqual(colorAt(s, ns.range(of: "srate").location), .orange, "srate builtin → constant (number color)")
        XCTAssertEqual(colorAt(s, ns.range(of: "min(").location), .brown, "identifier before ( → function call")
    }

    func testJSFXNumbersIncludingEELLiterals() throws {
        let s = highlighted(jsfxSnippet, try jsfxDefinition())
        let ns = jsfxSnippet as NSString
        XCTAssertEqual(colorAt(s, ns.range(of: "6.02").location), .orange, "decimal literal")
        XCTAssertEqual(colorAt(s, ns.range(of: "$x10").location), .orange, "$x hex literal")
        XCTAssertEqual(colorAt(s, ns.range(of: "$'A'").location), .orange, "$'c' char literal")
    }

    func testJSFXCommentsAndStringsKeepPrecedence() throws {
        let s = highlighted(jsfxSnippet, try jsfxDefinition())
        let ns = jsfxSnippet as NSString
        XCTAssertEqual(colorAt(s, ns.range(of: "// convert dB").location), .red, "line comment")
        XCTAssertEqual(colorAt(s, ns.range(of: "/* per-sample block */").location), .red, "block comment")
        XCTAssertEqual(colorAt(s, ns.range(of: "\"https").location), .green, "string start")
        XCTAssertEqual(colorAt(s, ns.range(of: "// not a comment").location), .green,
                       "`//` inside a string literal stays string-colored")
    }

    func testJSFXCaseInsensitivityAppliesToRules() throws {
        // EEL2 is case-insensitive and the fixture sets the flag, so
        // upper-cased keywords, registers, and section markers still color.
        let text = "@INIT\nFUNCTION f(a) ( SPL0 = a; );"
        let s = highlighted(text, try jsfxDefinition())
        let ns = text as NSString
        XCTAssertEqual(colorAt(s, ns.range(of: "@INIT").location), .magenta, "@INIT → attribute despite case")
        XCTAssertEqual(colorAt(s, ns.range(of: "FUNCTION").location), .blue, "FUNCTION → keyword despite case")
        XCTAssertEqual(colorAt(s, ns.range(of: "SPL0").location), .cyan, "SPL0 → variable despite case")
    }

    // MARK: - Structured-field behavior on small inline definitions

    func testCaseInsensitiveFlagOffByDefault() {
        let def = CustomLanguageDefinition(name: "T", extensions: ["t"],
                                           keywords: ["begin"], numbers: false, functionCalls: false)
        let s = highlighted("BEGIN work", def)
        XCTAssertEqual(colorAt(s, 0), .black, "case-sensitive by default: BEGIN is not the keyword begin")

        var ci = def
        ci.caseInsensitive = true
        let s2 = highlighted("BEGIN work", ci)
        XCTAssertEqual(colorAt(s2, 0), .blue, "caseInsensitive: true colors BEGIN as a keyword")
    }

    func testNumbersAndFunctionCallsDefaultOn() {
        let def = CustomLanguageDefinition(name: "Minimal", extensions: ["min"])
        let text = "foo(42)"
        let s = highlighted(text, def)
        let ns = text as NSString
        XCTAssertEqual(colorAt(s, 0), .brown, "functionCalls defaults to true")
        XCTAssertEqual(colorAt(s, ns.range(of: "42").location), .orange, "numbers defaults to true")
    }

    func testNumbersAndFunctionCallsCanBeDisabled() {
        let def = CustomLanguageDefinition(name: "Off", extensions: ["off"],
                                           numbers: false, functionCalls: false)
        let text = "foo(42)"
        let s = highlighted(text, def)
        let ns = text as NSString
        XCTAssertEqual(colorAt(s, 0), .black, "functionCalls: false leaves calls uncolored")
        XCTAssertEqual(colorAt(s, ns.range(of: "42").location), .black, "numbers: false leaves numbers uncolored")
    }

    func testCustomStringDelimiterAndCommentPrecedenceMerge() {
        // Custom single-quote strings + # comments must go through the same
        // left-to-right merge the built-in tables use.
        let def = CustomLanguageDefinition(name: "T", extensions: ["t"],
                                           lineComment: "#", stringDelimiters: ["'"])
        let text = "x = 'a#b' # real"
        let s = highlighted(text, def)
        let ns = text as NSString
        XCTAssertEqual(colorAt(s, ns.range(of: "'a").location), .green, "string literal")
        XCTAssertEqual(colorAt(s, ns.range(of: "#b").location), .green, "`#` inside the string stays string-colored")
        XCTAssertEqual(colorAt(s, ns.range(of: "# real").location), .red, "real trailing comment")
    }

    func testInvalidRegexPatternIsSkippedNotFatal() {
        let def = CustomLanguageDefinition(
            name: "Broken", extensions: ["brk"],
            keywords: ["magic"],
            patterns: [
                CustomPattern(pattern: "([unclosed", kind: "keyword"),   // invalid regex → skipped
                CustomPattern(pattern: "@\\w+", kind: "attribute"),      // valid → still applied
            ])
        XCTAssertNil(def.validationError, "an invalid regex is not a validation error")
        let text = "magic @tag"
        let s = highlighted(text, def)   // must not crash
        let ns = text as NSString
        XCTAssertEqual(colorAt(s, 0), .blue, "rules after the broken one still apply")
        XCTAssertEqual(colorAt(s, ns.range(of: "@tag").location), .magenta, "valid pattern still applies")
    }

    // MARK: - Decode error messages (the JSON is hand-authored)

    private func decodeError(_ json: String) -> CustomLanguageDefinitionError? {
        guard case .failure(let error) = CustomLanguageDefinition.decode(from: Data(json.utf8)) else { return nil }
        return error as? CustomLanguageDefinitionError
    }

    func testUnknownPatternKindFailsDecodeWithClearMessage() {
        let json = #"{"name":"X","extensions":["x"],"patterns":[{"pattern":"a","kind":"wibble"}]}"#
        let error = decodeError(json)
        XCTAssertEqual(error, .unknownPatternKind(kind: "wibble", index: 0))
        let message = error?.errorDescription ?? ""
        XCTAssertTrue(message.contains("wibble"), "message names the bad kind")
        XCTAssertTrue(message.contains("attribute"), "message lists the valid kinds")
    }

    func testMissingNameProducesReadableError() {
        let error = decodeError(#"{"extensions":["x"]}"#)
        XCTAssertEqual(error, .missingField("name"))
        XCTAssertEqual(error?.errorDescription, "Missing required field \"name\".")
    }

    func testMissingExtensionsProducesReadableError() {
        XCTAssertEqual(decodeError(#"{"name":"X"}"#), .missingField("extensions"))
    }

    func testEmptyExtensionsProducesReadableError() {
        XCTAssertEqual(decodeError(#"{"name":"X","extensions":[]}"#), .emptyExtensions)
    }

    func testWrongTypeProducesReadableError() {
        guard case .wrongType(let field, _)? = decodeError(#"{"name":"X","extensions":"x"}"#) else {
            return XCTFail("expected a wrongType error")
        }
        XCTAssertEqual(field, "extensions")
    }

    func testMalformedJSONProducesReadableError() {
        guard case .invalidJSON? = decodeError("{ not json") else {
            return XCTFail("expected an invalidJSON error")
        }
    }
}
