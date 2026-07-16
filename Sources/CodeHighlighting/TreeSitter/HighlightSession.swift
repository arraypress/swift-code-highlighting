//
//  HighlightSession.swift
//  SwiftCodeHighlighting
//
//  A stateful, incremental companion to TreeSitterHighlighter: it caches the
//  parsed syntax tree between highlight passes so scrolling a huge file only
//  runs the query, never a re-parse, and edits re-parse incrementally via
//  tree-sitter's `tree.edit(InputEdit)` + `parser.parse(tree:string:)`.
//

import AppKit
import CodeLanguage
import SwiftTreeSitter

/// A stateful tree-sitter highlighting session that parses a document **once**
/// and keeps the syntax tree alive across highlight passes.
///
/// The stateless ``TreeSitterHighlighter/highlight(_:in:)`` re-parses the whole
/// buffer on every call — fine for small files, but a per-viewport re-highlight
/// while scrolling a multi-megabyte file re-parses those megabytes every scroll
/// tick. A `HighlightSession` instead:
///
/// - parses the full text once, on the first ``highlight(in:text:clip:)``,
/// - re-highlights any viewport clip from the **cached** tree (query only,
///   no parse),
/// - re-parses **incrementally** on edits via ``noteEdit(range:replacementLength:newText:)``
///   (tree-sitter re-lexes only the changed region),
/// - and drops the tree on ``invalidate()`` (file reload, language change),
///   after which the next highlight performs one fresh full parse.
///
/// The color pipeline is identical to the static path: the grammar's
/// `highlights.scm` with later-pattern-wins precedence, `#eq?`/`#match?`
/// predicates resolved, and recursive injection highlighting.
///
/// - Note: Injected languages (CSS in `<style>`, HTML in PHP, …) are still
///   fully re-parsed per highlight call — only the *host* language's tree is
///   cached. Host-language files dominate the huge-file case, so this is an
///   accepted cost; injection trees can be cached later without API changes.
/// - Important: ``highlight(in:text:clip:)`` must run on the main thread (the
///   resolving query cursor is main-actor-isolated), and `text` must be the
///   exact current contents of `storage`. Only `.foregroundColor` is touched.
public final class HighlightSession {

    /// The resolved grammar (language pointer + compiled highlight/injection
    /// queries) this session highlights with.
    private let grammar: TreeSitterHighlighter.Grammar

    /// The session's parser; configured once with the grammar's language.
    private let parser = Parser()

    /// The cached syntax tree for ``lastText``, or nil before the first parse
    /// / after ``invalidate()`` / after a desynced edit was rejected.
    private var tree: MutableTree?

    /// The exact text ``tree`` was parsed from — the "old text" side of the
    /// next ``noteEdit(range:replacementLength:newText:)`` byte/Point math.
    private var lastText: String?

    /// Test seam: number of from-scratch parses performed (first highlight
    /// after init/invalidate). A scroll-only workload must keep this at 1.
    private(set) var fullParseCount = 0

    /// Test seam: number of incremental re-parses performed by
    /// ``noteEdit(range:replacementLength:newText:)``.
    private(set) var incrementalParseCount = 0

    /// Creates a session for `language`, or nil when no grammar (with its
    /// query bundle) is loaded for it — the same condition as
    /// ``TreeSitterHighlighter/supports(_:)``. Fall back to the stateless
    /// highlighter or ``SyntaxHighlighter`` when this returns nil.
    public init?(language: CodeLanguage.Language) {
        guard let g = TreeSitterHighlighter.grammars[language] else { return nil }
        grammar = g
        try? parser.setLanguage(g.language)
    }

    /// Test seam: builds a session around a hand-assembled grammar (e.g. a
    /// query compiled from a string), bypassing the resource-bundle lookup —
    /// the `.scm` bundles are absent under headless `swift test`.
    init(grammar: TreeSitterHighlighter.Grammar) {
        self.grammar = grammar
        try? parser.setLanguage(grammar.language)
    }

    /// Records a text edit and incrementally re-parses.
    ///
    /// Call this for every storage mutation, **after** the change has been
    /// applied, describing it in the old document's coordinates:
    ///
    /// - Parameters:
    ///   - range: the replaced range in the **old** text (UTF-16 units, i.e.
    ///     the `NSRange` NSTextStorage reports — for an insertion, length 0).
    ///   - replacementLength: the UTF-16 length of the inserted text (0 for a
    ///     deletion).
    ///   - newText: the **full** document text after the edit.
    ///
    /// Byte offsets follow the load-bearing SwiftTreeSitter rule — the parser
    /// consumes UTF-16LE, so a tree-sitter byte offset is the UTF-16 index × 2,
    /// NOT `utf8.count`. `Point`s (row, byte-column) are computed with the same
    /// forward newline scan the injection combined-parse uses.
    ///
    /// If no tree is cached yet this is a no-op (the next highlight parses from
    /// scratch anyway). If the edit is inconsistent with the cached text (out
    /// of bounds, or the lengths don't reconcile), the tree is dropped instead
    /// of edited — the next highlight recovers with one full parse.
    public func noteEdit(range: NSRange, replacementLength: Int, newText: String) {
        guard let tree, let old = lastText else { return }
        let oldNS = old as NSString
        let newNS = newText as NSString
        guard range.location >= 0, range.length >= 0, replacementLength >= 0,
              NSMaxRange(range) <= oldNS.length,
              newNS.length == oldNS.length - range.length + replacementLength else {
            invalidate()   // desynced with the cached text: full reparse next highlight
            return
        }

        // Bytes: UTF-16 index × 2. Points: rows from a newline scan, columns in
        // bytes. start/oldEnd scan the OLD text; newEnd scans the NEW text (the
        // prefix before `range.location` is identical in both).
        var oldScan = UTF16NewlineScanner(oldNS)
        let startPoint = oldScan.point(at: range.location)
        let oldEndPoint = oldScan.point(at: NSMaxRange(range))
        var newScan = UTF16NewlineScanner(newNS)
        let newEndPoint = newScan.point(at: range.location + replacementLength)

        tree.edit(InputEdit(startByte: range.location * 2,
                            oldEndByte: NSMaxRange(range) * 2,
                            newEndByte: (range.location + replacementLength) * 2,
                            startPoint: startPoint,
                            oldEndPoint: oldEndPoint,
                            newEndPoint: newEndPoint))

        if let newTree = parser.parse(tree: tree, string: newText) {
            self.tree = newTree
            lastText = newText
            incrementalParseCount += 1
        } else {
            invalidate()
        }
    }

    /// Highlights `clip` (a viewport range, in `storage` coordinates) from the
    /// cached tree — **no parsing** happens unless this is the first call after
    /// init/``invalidate()``, which parses `text` once.
    ///
    /// Runs the same pipeline as the stateless highlighter: resets
    /// `.foregroundColor` inside the clip, applies the grammar's highlights
    /// query (later pattern wins, predicates resolved), then the recursive
    /// injection pass (injections re-parse their sub-documents each call — see
    /// the class note).
    ///
    /// - Parameters:
    ///   - storage: the text storage to color. Only `.foregroundColor` is set.
    ///   - text: the current full document text; must match `storage.string`
    ///     and the text the cached tree was built from (keep the tree current
    ///     via ``noteEdit(range:replacementLength:newText:)``).
    ///   - clip: the range to (re)color; clamped to the storage bounds.
    /// - Note: Must be called on the main thread.
    public func highlight(in storage: NSTextStorage, text: String, clip: NSRange) {
        if tree == nil {
            tree = parser.parse(text)
            lastText = text
            if tree != nil { fullParseCount += 1 }
        }
        guard let tree else { return }
        let ns = text as NSString
        let clipped = NSIntersectionRange(clip, NSRange(location: 0, length: storage.length))
        guard clipped.length > 0 else { return }

        storage.addAttribute(.foregroundColor, value: HighlightTheme.colors.foreground, range: clipped)

        // ResolvingQueryCursor is main-actor-isolated; highlight only runs on main.
        MainActor.assumeIsolated {
            TreeSitterHighlighter.applyQuery(grammar.highlights, tree: tree, source: ns,
                                             offset: 0, clip: clipped, into: storage)
            TreeSitterHighlighter.applyInjections(grammar, tree: tree, source: ns,
                                                  offset: 0, clip: clipped, into: storage, depth: 0)
        }
    }

    /// Drops the cached tree (and its text). The next
    /// ``highlight(in:text:clip:)`` performs one full parse. Call on file
    /// reload, external modification, or language change — anywhere the storage
    /// text changed without a matching ``noteEdit(range:replacementLength:newText:)``.
    public func invalidate() {
        tree = nil
        lastText = nil
    }
}

/// Forward-only newline scanner over an NSString: converts ascending UTF-16
/// indices to tree-sitter `Point`s (row = newline count, column = bytes since
/// the last newline, i.e. UTF-16 units × 2) in one O(n) pass — the same
/// approach `TreeSitterHighlighter.combinedParse` uses for injection ranges.
struct UTF16NewlineScanner {
    private let ns: NSString
    private var row = 0
    private var lastNL = -1
    private var scan = 0

    /// Creates a scanner positioned at the start of `ns`.
    init(_ ns: NSString) { self.ns = ns }

    /// The `Point` at UTF-16 index `idx`. Indices must be asked in ascending
    /// order (the scan never rewinds) and be ≤ `ns.length`.
    mutating func point(at idx: Int) -> Point {
        while scan < idx {
            if ns.character(at: scan) == 0x0A { row += 1; lastNL = scan }
            scan += 1
        }
        return Point(row: row, column: (idx - lastNL - 1) * 2)
    }
}
