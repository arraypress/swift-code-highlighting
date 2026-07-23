//
//  SymbolIndexTests.swift
//  Tests for SymbolKind mapping, TreeSitterHighlighter.symbols(in:), and the
//  ProjectSymbolIndex build/update lifecycle. These run headless: the symbol
//  queries are inline strings (SymbolQueries), not bundle resources.
//

import XCTest
import CodeLanguage
@testable import CodeHighlighting

final class SymbolIndexTests: XCTestCase {

    // MARK: - SymbolKind capture mapping

    func testSymbolKindCaptureMapping() {
        XCTAssertEqual(SymbolKind(capture: "function"), .function)
        XCTAssertEqual(SymbolKind(capture: "method"), .method)
        XCTAssertEqual(SymbolKind(capture: "class"), .type)
        XCTAssertEqual(SymbolKind(capture: "struct"), .structure)
        XCTAssertEqual(SymbolKind(capture: "enum"), .enumeration)
        XCTAssertEqual(SymbolKind(capture: "interface"), .interface)
        XCTAssertEqual(SymbolKind(capture: "module"), .module)
        XCTAssertEqual(SymbolKind(capture: "constant"), .constant)
        XCTAssertNil(SymbolKind(capture: "definitely.not.a.kind"))
        XCTAssertNil(SymbolKind(capture: ""))
    }

    // MARK: - symbols(in:language:)

    func testSymbolsFindsPythonDefinitionsInOrder() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        let text = """
        class Repo:
            def find(self):
                pass

        def helper():
            pass
        """
        let syms = TreeSitterHighlighter.symbols(in: text, language: .python)
        XCTAssertEqual(syms.map(\.name), ["Repo", "find", "helper"], "position order")
        XCTAssertEqual(syms.map(\.kind), [.type, .function, .function])
        XCTAssertEqual(syms.map(\.line), [1, 2, 5], "1-based definition lines")
    }

    func testSymbolsJavaScriptArrowAndClass() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.javascript), "JS grammar failed to load")
        let text = "const go = () => 1;\nclass Widget {\n  render() {}\n}\n"
        let syms = TreeSitterHighlighter.symbols(in: text, language: .javascript)
        XCTAssertEqual(syms.map(\.name), ["go", "Widget", "render"])
        XCTAssertEqual(syms.map(\.kind), [.function, .type, .method])
    }

    func testSymbolsUnsupportedLanguageReturnsEmpty() {
        // No grammar AND no symbol query (.plainText), plus an empty buffer in a
        // fully supported language: both must degrade to [] rather than crash.
        // (.swift used to be this test's no-grammar case — it has one now, and
        //  its symbols are covered by testSymbolsSwiftDefinitions below.)
        XCTAssertEqual(TreeSitterHighlighter.symbols(in: "hello", language: .plainText).count, 0)
        XCTAssertEqual(TreeSitterHighlighter.symbols(in: "", language: .python).count, 0, "empty buffer")
    }

    func testSymbolsSwiftDefinitions() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.swift), "Swift grammar failed to load")
        let text = """
        protocol Greeter {
            func greet()
        }

        struct Widget {
            init() {}
            func render() {}
        }

        func helper() {}
        """
        let syms = TreeSitterHighlighter.symbols(in: text, language: .swift)
        XCTAssertEqual(syms.map(\.name), ["Greeter", "greet", "Widget", "init", "render", "helper"],
                       "position order; struct uses the same node as class")
        XCTAssertEqual(syms.map(\.kind), [.interface, .method, .type, .method, .function, .function])
        XCTAssertEqual(syms.map(\.line), [1, 2, 5, 6, 7, 10], "1-based definition lines")
    }

    /// Line numbers come from ONE forward pass whose cursor only moves forward
    /// (it used to re-count each symbol's prefix independently, which was
    /// O(n·m)). Two definitions sharing a line are the case that pass can get
    /// wrong: the second must not consume the newline the first stopped at.
    func testSymbolLinesWithTwoDefinitionsOnOneLine() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.javascript), "JS grammar failed to load")
        let text = "\n\nfunction a() {}  function b() {}\n\nfunction c() {}\n"
        let syms = TreeSitterHighlighter.symbols(in: text, language: .javascript)
        XCTAssertEqual(syms.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(syms.map(\.line), [3, 3, 5], "both share line 3; the blank lines still count")
    }

    /// The same forward pass over many symbols and many lines — every line must
    /// be exact, not just the first few.
    func testSymbolLinesStayExactAcrossManyDefinitions() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python), "Python grammar failed to load")
        // One def every 3 lines: def_i sits on line 3i + 1.
        let count = 200
        let text = (0..<count).map { "def def_\($0)():\n    pass\n\n" }.joined()
        let syms = TreeSitterHighlighter.symbols(in: text, language: .python)
        XCTAssertEqual(syms.count, count)
        XCTAssertEqual(syms.map(\.line), (0..<count).map { $0 * 3 + 1 })
        XCTAssertEqual(syms.last?.name, "def_\(count - 1)")
    }

    func testSymbolsSwiftPatternsDoNotOverlap() throws {
        // symbols(...) appends EVERY capture of EVERY match with no dedupe, so a
        // method matching both a generic and a body-scoped pattern would be
        // emitted twice. Guards the Swift query against that regression.
        try XCTSkipUnless(TreeSitterHighlighter.supports(.swift), "Swift grammar failed to load")
        let syms = TreeSitterHighlighter.symbols(in: "class C {\n    func m() {}\n}", language: .swift)
        XCTAssertEqual(syms.map(\.name), ["C", "m"], "no duplicate entry for the method")
    }

    // MARK: - ProjectSymbolIndex

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Spins the main run loop until `condition()` holds or `timeout` elapses.
    /// (ProjectSymbolIndex.updateFile has no completion hook.)
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    func testBuildIndexesDefinitionsAcrossLanguages() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python) && TreeSitterHighlighter.supports(.javascript))
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def alpha():\n    pass\n".write(to: dir.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        try "function beta() {}\n".write(to: dir.appendingPathComponent("b.js"), atomically: true, encoding: .utf8)

        let idx = ProjectSymbolIndex()
        let built = expectation(description: "build completes")
        idx.build(root: dir) { built.fulfill() }
        wait(for: [built], timeout: 10)

        XCTAssertTrue(idx.isBuilt)
        let alpha = idx.definitions(of: "alpha")
        XCTAssertEqual(alpha.count, 1)
        XCTAssertEqual(alpha.first?.kind, .function)
        XCTAssertEqual(alpha.first?.line, 1)
        XCTAssertEqual(alpha.first?.url.lastPathComponent, "a.py")
        XCTAssertEqual(idx.definitions(of: "beta").first?.url.lastPathComponent, "b.js")
        XCTAssertEqual(idx.definitions(of: "nonexistent").count, 0)
    }

    func testBuildSkipsDependencyDirectories() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.javascript))
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nm = dir.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
        try "function vendored() {}\n".write(to: nm.appendingPathComponent("dep.js"), atomically: true, encoding: .utf8)
        try "function mine() {}\n".write(to: dir.appendingPathComponent("app.js"), atomically: true, encoding: .utf8)

        let idx = ProjectSymbolIndex()
        let built = expectation(description: "build completes")
        idx.build(root: dir) { built.fulfill() }
        wait(for: [built], timeout: 10)

        XCTAssertEqual(idx.definitions(of: "mine").count, 1)
        XCTAssertEqual(idx.definitions(of: "vendored").count, 0, "node_modules must be skipped")
    }

    func testUpdateFileReindexesEditedFile() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python))
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.py")
        try "def alpha():\n    pass\n".write(to: file, atomically: true, encoding: .utf8)

        let idx = ProjectSymbolIndex()
        let built = expectation(description: "build completes")
        idx.build(root: dir) { built.fulfill() }
        wait(for: [built], timeout: 10)
        XCTAssertEqual(idx.definitions(of: "alpha").count, 1)

        // Rename the definition on disk, then incrementally re-index the file:
        // the old name must drop out and the new one appear.
        try "def gamma():\n    pass\n".write(to: file, atomically: true, encoding: .utf8)
        idx.updateFile(file)
        XCTAssertTrue(waitUntil { idx.definitions(of: "gamma").count == 1 }, "new symbol indexed")
        XCTAssertEqual(idx.definitions(of: "alpha").count, 0, "stale symbol removed")
    }

    func testUpdateFileDropsDeletedFile() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python))
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.py")
        try "def alpha():\n    pass\n".write(to: file, atomically: true, encoding: .utf8)

        let idx = ProjectSymbolIndex()
        let built = expectation(description: "build completes")
        idx.build(root: dir) { built.fulfill() }
        wait(for: [built], timeout: 10)
        XCTAssertEqual(idx.definitions(of: "alpha").count, 1)

        try FileManager.default.removeItem(at: file)
        idx.updateFile(file)
        XCTAssertTrue(waitUntil { idx.definitions(of: "alpha").isEmpty }, "deleted file's symbols dropped")
    }

    func testCanonicalPathStableAcrossDeletion() throws {
        // macOS aliases /var → /private/var, and URL standardization is
        // existence-dependent: a deleted file's standardized path drifts.
        // The canonical key must be identical before and after deletion, and
        // identical for both spellings of the same file.
        let dir = makeTempDir()   // lives under /var/folders/... (a /private symlink)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.py")
        try "def alpha():\n    pass\n".write(to: file, atomically: true, encoding: .utf8)

        let privateSpelling = URL(fileURLWithPath: "/private" + file.path)
        let before = ProjectSymbolIndex.canonicalPath(for: file)
        XCTAssertEqual(ProjectSymbolIndex.canonicalPath(for: privateSpelling), before,
                       "both spellings of an existing file share one key")

        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(ProjectSymbolIndex.canonicalPath(for: file), before,
                       "the key survives the file's deletion (parent still exists)")
        XCTAssertEqual(ProjectSymbolIndex.canonicalPath(for: privateSpelling), before)
    }

    func testUpdateFileDuringBuildIsReplayedAfterInstall() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python))
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.py")
        try "def alpha():\n    pass\n".write(to: file, atomically: true, encoding: .utf8)

        let idx = ProjectSymbolIndex()
        let built = expectation(description: "build completes")
        idx.build(root: dir) { built.fulfill() }
        // Mid-build edit: isBuilt is still false here (the install runs on a
        // later main-queue turn), and the build's enumerator may already have
        // read the pre-edit file — so this notification must be queued and
        // replayed after the install, not silently dropped.
        try "def gamma():\n    pass\n".write(to: file, atomically: true, encoding: .utf8)
        idx.updateFile(file)
        XCTAssertFalse(idx.isBuilt)
        wait(for: [built], timeout: 10)

        XCTAssertTrue(waitUntil { idx.definitions(of: "gamma").count == 1 },
                      "mid-build edit re-indexed after the install")
        XCTAssertTrue(waitUntil { idx.definitions(of: "alpha").isEmpty },
                      "pre-edit symbols corrected")
    }

    func testUpdateFileBeforeBuildIsNoOp() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python))
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.py")
        try "def alpha():\n    pass\n".write(to: file, atomically: true, encoding: .utf8)

        let idx = ProjectSymbolIndex()
        idx.updateFile(file)   // before any build: guarded no-op
        XCTAssertFalse(idx.isBuilt)
        XCTAssertEqual(idx.definitions(of: "alpha").count, 0)
    }

    // MARK: - Prefix query (the completion popup's project-symbol tier)

    /// Builds an index over one Python file defining `names`, one `def` each.
    private func makePrefixIndex(names: [String], file: String = "a.py") throws -> (ProjectSymbolIndex, URL) {
        let dir = makeTempDir()
        let source = names.map { "def \($0)():\n    pass\n" }.joined()
        try source.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        let idx = ProjectSymbolIndex()
        let built = expectation(description: "build completes")
        idx.build(root: dir) { built.fulfill() }
        wait(for: [built], timeout: 10)
        return (idx, dir)
    }

    func testPrefixQueryReturnsMatchesAlphabeticallyWithKindAndFile() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python))
        let (idx, dir) = try makePrefixIndex(names: ["get_user_by_id", "get_user", "getaway", "set_user"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let hits = idx.definitions(matchingPrefix: "get_")
        XCTAssertEqual(hits.map(\.name), ["get_user", "get_user_by_id"], "alphabetical; get_ excludes getaway")
        // The popup renders kind + defining file from these.
        XCTAssertEqual(hits.first?.kind, .function)
        XCTAssertEqual(hits.first?.url.lastPathComponent, "a.py")
    }

    func testPrefixQueryIsCaseInsensitiveAndPreservesSpelling() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python))
        let (idx, dir) = try makePrefixIndex(names: ["GetUser", "getFile"])
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(idx.definitions(matchingPrefix: "get").map(\.name).sorted(), ["GetUser", "getFile"],
                       "matches ignore case but results keep the definition's own spelling")
        XCTAssertEqual(idx.definitions(matchingPrefix: "GETUSER").map(\.name), ["GetUser"])
    }

    /// The walk stops at the first non-matching name, so a name sorting just
    /// past the prefix run must not leak in (nor one sorting just before it).
    func testPrefixQueryExcludesNamesOutsideTheRun() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python))
        let (idx, dir) = try makePrefixIndex(names: ["gap", "get", "getx", "gfx", "zzz"])
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(idx.definitions(matchingPrefix: "get").map(\.name), ["get", "getx"])
        XCTAssertTrue(idx.definitions(matchingPrefix: "zzzz").isEmpty, "prefix past every name")
        XCTAssertTrue(idx.definitions(matchingPrefix: "aaa").isEmpty, "prefix before every name")
    }

    func testPrefixQueryEmptyPrefixAndZeroLimitYieldNothing() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python))
        let (idx, dir) = try makePrefixIndex(names: ["alpha", "beta"])
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertTrue(idx.definitions(matchingPrefix: "").isEmpty, "every symbol is not a suggestion")
        XCTAssertTrue(idx.definitions(matchingPrefix: "a", limit: 0).isEmpty)
    }

    func testPrefixQueryRespectsLimit() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python))
        let (idx, dir) = try makePrefixIndex(names: (0..<20).map { "item\($0)" })
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(idx.definitions(matchingPrefix: "item").count, 20)
        XCTAssertEqual(idx.definitions(matchingPrefix: "item", limit: 5).count, 5)
    }

    /// A name defined in several files is one suggestion, not one per site.
    func testPrefixQueryReturnsOneRowPerName() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python))
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def shared():\n    pass\n".write(to: dir.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        try "def shared():\n    pass\n".write(to: dir.appendingPathComponent("b.py"), atomically: true, encoding: .utf8)

        let idx = ProjectSymbolIndex()
        let built = expectation(description: "build completes")
        idx.build(root: dir) { built.fulfill() }
        wait(for: [built], timeout: 10)

        XCTAssertEqual(idx.definitions(of: "shared").count, 2, "both sites are indexed")
        XCTAssertEqual(idx.definitions(matchingPrefix: "shar").count, 1, "but the popup gets one row")
    }

    /// The sorted cursor is cached; an incremental update must invalidate it or
    /// the popup would keep suggesting a name that no longer exists.
    func testPrefixQueryFollowsIncrementalUpdate() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python))
        let (idx, dir) = try makePrefixIndex(names: ["alpha"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.py")

        XCTAssertEqual(idx.definitions(matchingPrefix: "alp").map(\.name), ["alpha"])   // caches the cursor

        try "def alphabet():\n    pass\n".write(to: file, atomically: true, encoding: .utf8)
        idx.updateFile(file)
        XCTAssertTrue(waitUntil { idx.definitions(matchingPrefix: "alp").map(\.name) == ["alphabet"] },
                      "renamed symbol replaces the stale one in the prefix cursor")
    }

    func testPrefixQueryEmptyAfterInvalidate() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python))
        let (idx, dir) = try makePrefixIndex(names: ["alpha"])
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertFalse(idx.definitions(matchingPrefix: "alp").isEmpty)
        idx.invalidate()
        XCTAssertTrue(idx.definitions(matchingPrefix: "alp").isEmpty, "cursor dropped with the index")
    }

    func testPrefixQueryBeforeBuildIsEmpty() {
        let idx = ProjectSymbolIndex()
        XCTAssertTrue(idx.definitions(matchingPrefix: "any").isEmpty)
    }

    // MARK: - hoverInfo (the parse-free variants)

    func testHoverInfoPrefetchedSymbolsMatchesParsingVariant() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python))
        let text = "# adds things\ndef alpha():\n    pass\n"
        let syms = TreeSitterHighlighter.symbols(in: text, language: .python)
        let parsed = try XCTUnwrap(TreeSitterHighlighter.hoverInfo(for: "alpha", in: text, language: .python))
        let prefetched = try XCTUnwrap(TreeSitterHighlighter.hoverInfo(for: "alpha", symbols: syms,
                                                                       in: text, language: .python))
        XCTAssertEqual(prefetched.kind, parsed.kind)
        XCTAssertEqual(prefetched.signature.string, parsed.signature.string)
        XCTAssertEqual(prefetched.doc, parsed.doc)
        XCTAssertNil(TreeSitterHighlighter.hoverInfo(for: "alpha", symbols: [], in: text, language: .python),
                     "a warming session's empty symbols yield nil, never a parse")
    }

    func testHoverInfoDefinedAtVerifiesTheSiteStillHoldsTheWord() throws {
        try XCTSkipUnless(TreeSitterHighlighter.supports(.python))
        let text = "def alpha():\n    pass\n"
        let range = (text as NSString).range(of: "alpha")
        let info = try XCTUnwrap(TreeSitterHighlighter.hoverInfo(for: "alpha", definedAt: range,
                                                                 kind: .function, in: text, language: .python))
        XCTAssertEqual(info.kind, .function)
        XCTAssertEqual(info.signature.string, "def alpha():")
        // A stale index site (the range no longer holds the word, or is out of
        // bounds) yields nil rather than a guessed signature.
        XCTAssertNil(TreeSitterHighlighter.hoverInfo(for: "alpha", definedAt: NSRange(location: 0, length: 5),
                                                     kind: .function, in: text, language: .python))
        XCTAssertNil(TreeSitterHighlighter.hoverInfo(for: "alpha", definedAt: NSRange(location: 500, length: 5),
                                                     kind: .function, in: text, language: .python))
    }
}
