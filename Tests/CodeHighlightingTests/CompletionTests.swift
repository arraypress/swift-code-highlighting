//
//  CompletionTests.swift
//  Tests for CompletionProvider's pure ranking/scanning core: rank() tier order,
//  dedup, prefix rules, cap; bufferWords() charset, length bounds, and sorting.
//  Headless — no editor, no tree-sitter parse.
//

import XCTest
@testable import CodeHighlighting

final class CompletionTests: XCTestCase {

    private func item(_ text: String, kind: SymbolKind? = .function, detail: String? = nil) -> CompletionItem {
        CompletionItem(text: text, kind: kind, detail: detail)
    }

    // MARK: - rank

    func testPrefixMatchIsCaseInsensitive() {
        let out = CompletionProvider.rank(
            partial: "fo",
            fileSymbols: [item("Foobar"), item("food"), item("bar")],
            projectSymbols: [], bufferWords: [])
        XCTAssertEqual(out.map(\.text), ["Foobar", "food"])
    }

    func testTierOrderFileThenProjectThenBuffer() {
        let out = CompletionProvider.rank(
            partial: "a",
            fileSymbols: [item("alpha")],
            projectSymbols: [item("apex", detail: "x.swift")],
            bufferWords: ["around"])
        XCTAssertEqual(out.map(\.text), ["alpha", "apex", "around"])
    }

    func testDedupPrefersHigherTier() {
        // "shared" appears in all three tiers; only the file-symbol copy (with
        // its kind) survives, at rank 0.
        let out = CompletionProvider.rank(
            partial: "sh",
            fileSymbols: [item("shared", kind: .method)],
            projectSymbols: [item("shared", kind: .function, detail: "p.swift")],
            bufferWords: ["shared"])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].kind, .method)
        XCTAssertNil(out[0].detail)
    }

    func testDropsCandidateIdenticalToPartial() {
        // Completing "count" to "count" is noise; a longer match survives.
        let out = CompletionProvider.rank(
            partial: "count",
            fileSymbols: [item("count"), item("counter")],
            projectSymbols: [], bufferWords: [])
        XCTAssertEqual(out.map(\.text), ["counter"])
    }

    func testCapLimitsResults() {
        let syms = (0..<10).map { item("item\($0)") }
        let out = CompletionProvider.rank(
            partial: "item", fileSymbols: syms, projectSymbols: [], bufferWords: [], cap: 3)
        XCTAssertEqual(out.count, 3)
    }

    func testEmptyPartialYieldsNothing() {
        XCTAssertTrue(CompletionProvider.rank(
            partial: "", fileSymbols: [item("x")], projectSymbols: [], bufferWords: []).isEmpty)
    }

    func testNonMatchingPrefixExcluded() {
        let out = CompletionProvider.rank(
            partial: "zz", fileSymbols: [item("alpha")], projectSymbols: [], bufferWords: ["beta"])
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - bufferWords

    func testBufferWordsExtractsIdentifiers() {
        let words = CompletionProvider.bufferWords(in: "let userName = fetchData(userName)")
        XCTAssertEqual(words, ["fetchData", "let", "userName"])   // sorted, unique
    }

    func testBufferWordsSkipsShortWords() {
        // "a" and "id" are below minWordLength (3).
        let words = CompletionProvider.bufferWords(in: "a id abc")
        XCTAssertEqual(words, ["abc"])
    }

    func testBufferWordsRejectsDigitLedTokens() {
        // "3rd" starts with a digit → not identifier-shaped; "_x9" is fine.
        let words = CompletionProvider.bufferWords(in: "3rd value _x9 100")
        XCTAssertEqual(words, ["_x9", "value"])
    }

    func testBufferWordsAllowsUnderscoreAndDollar() {
        let words = CompletionProvider.bufferWords(in: "$scope _private mixed_Case")
        XCTAssertEqual(words, ["$scope", "_private", "mixed_Case"])
    }

    func testBufferWordsCaseInsensitiveSortStableTiebreak() {
        let words = CompletionProvider.bufferWords(in: "Beta alpha Alpha beta")
        // caseInsensitive groups Alpha/alpha then Beta/beta; case-sensitive
        // tiebreak puts uppercase first.
        XCTAssertEqual(words, ["Alpha", "alpha", "Beta", "beta"])
    }

    func testBufferWordsEmptyForNoIdentifiers() {
        XCTAssertTrue(CompletionProvider.bufferWords(in: "!!! ... ,,,").isEmpty)
    }

    // MARK: - Language built-ins tier

    func testPHPBuiltinsLoadAndPrefixMatch() {
        let builtins = LanguageBuiltins.completions(for: .php)
        XCTAssertFalse(builtins.isEmpty, "php.txt should load")
        XCTAssertTrue(builtins.contains { $0.text == "array_map" })
        XCTAssertTrue(builtins.contains { $0.text == "preg_match" })
        // Ranked into completion for a partial.
        let out = CompletionProvider.rank(partial: "array_", fileSymbols: [], projectSymbols: [],
                                          bufferWords: [], builtins: builtins)
        XCTAssertTrue(out.contains { $0.text == "array_map" })
        XCTAssertTrue(out.contains { $0.text == "array_filter" })
    }

    func testJavaScriptAndTypeScriptShareBuiltins() {
        let js = LanguageBuiltins.completions(for: .javascript)
        let ts = LanguageBuiltins.completions(for: .typescript)
        XCTAssertFalse(js.isEmpty)
        XCTAssertEqual(js.map(\.text), ts.map(\.text))   // TS reuses the JS set
        XCTAssertTrue(js.contains { $0.text == "forEach" })
    }

    func testPythonBuiltins() {
        let py = LanguageBuiltins.completions(for: .python)
        XCTAssertTrue(py.contains { $0.text == "enumerate" })
        XCTAssertTrue(py.contains { $0.text == "len" })
    }

    func testUnsupportedLanguageHasNoBuiltins() {
        XCTAssertTrue(LanguageBuiltins.completions(for: .plainText).isEmpty)
    }

    func testBuiltinSignatureParsedIntoDetail() {
        // A `name<TAB>signature` line puts the signature in the item's detail
        // (shown in the popup); only the name is inserted (item.text).
        let php = LanguageBuiltins.completions(for: .php)
        let arrayMap = php.first { $0.text == "array_map" }
        XCTAssertNotNil(arrayMap)
        XCTAssertEqual(arrayMap?.detail, "array_map(callable $callback, array ...$arrays): array")
        // A bare-name line has no detail.
        let isString = php.first { $0.text == "is_string" }
        XCTAssertNotNil(isString)
        XCTAssertEqual(isString?.detail, "is_string(mixed $value): bool")
    }

    func testBuiltinsRankBelowProjectSymbolsAboveBufferWords() {
        // A file symbol / project symbol named the same as a builtin wins; a bare
        // buffer word of the same name loses to the builtin.
        let out = CompletionProvider.rank(
            partial: "ma",
            fileSymbols: [], projectSymbols: [item("mainHandler", kind: .function)],
            bufferWords: ["maybe"],
            builtins: [item("map", kind: .function)])
        // Order: project (mainHandler) → builtin (map) → buffer (maybe).
        XCTAssertEqual(out.map(\.text), ["mainHandler", "map", "maybe"])
    }
}
