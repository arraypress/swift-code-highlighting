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
        // No tree-sitter grammar (.swift) and no symbol query (.plainText):
        // both must degrade to [] rather than crash.
        XCTAssertEqual(TreeSitterHighlighter.symbols(in: "func f() {}", language: .swift).count, 0)
        XCTAssertEqual(TreeSitterHighlighter.symbols(in: "hello", language: .plainText).count, 0)
        XCTAssertEqual(TreeSitterHighlighter.symbols(in: "", language: .python).count, 0, "empty buffer")
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
}
