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

    /// The `CodeLanguage` this session was created for (drives the symbol
    /// query lookup); nil for the test-seam grammar init.
    private let language: CodeLanguage.Language?

    /// The session's parser; configured once with the grammar's language.
    /// Main-thread only — ``warmUp(text:completion:)`` parses on a private
    /// parser instance, never this one.
    private let parser = Parser()

    /// The cached syntax tree for ``lastText``, or nil before the first parse
    /// / after ``invalidate()`` / after a desynced edit was rejected.
    /// Guarded by ``stateLock``.
    private var tree: MutableTree?

    /// The exact text ``tree`` was parsed from — the "old text" side of the
    /// next ``noteEdit(range:replacementLength:newText:)`` byte/Point math.
    /// Guarded by ``stateLock``.
    private var lastText: String?

    /// Guards `tree`/`lastText`/`generation` between the main thread (highlight,
    /// noteEdit, invalidate — all main-only) and the warm-up queue. The warm-up
    /// thread only holds it for the install, never for the parse itself, so the
    /// main thread is never blocked behind a multi-second background parse.
    private let stateLock = NSLock()

    /// Bumped whenever the session learns its text changed (`noteEdit`,
    /// `invalidate`), so an in-flight ``warmUp(text:completion:)`` parse of
    /// superseded text is discarded on arrival instead of installing a tree
    /// that no longer matches the document. Guarded by ``stateLock``.
    private var generation = 0

    /// Test seam: number of from-scratch parses performed (first highlight
    /// after init/invalidate, or a completed warm-up). A scroll-only workload
    /// must keep this at 1.
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
        self.language = language
        try? parser.setLanguage(g.language)
    }

    /// Test seam: builds a session around a hand-assembled grammar (e.g. a
    /// query compiled from a string), bypassing the resource-bundle lookup —
    /// the `.scm` bundles are absent under headless `swift test`.
    init(grammar: TreeSitterHighlighter.Grammar) {
        self.grammar = grammar
        self.language = nil
        try? parser.setLanguage(grammar.language)
    }

    // MARK: - Background warm-up

    /// Whether a parsed tree is installed (highlight passes will be query-only).
    /// False before the first parse, while a warm-up is still running, and after
    /// ``invalidate()``. Thread-safe.
    public var hasTree: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return tree != nil
    }

    /// Parses `text` on a background queue and installs the resulting tree, so
    /// opening a huge document never runs the multi-second first parse on the
    /// main thread (the host shows plain text until `completion`, which is what
    /// the regex tier did at open anyway).
    ///
    /// The parse runs on a private parser instance; the session's state is only
    /// touched under the lock, and the parsed tree is **discarded** when the
    /// session learned of any text change while parsing (an edit's `noteEdit`,
    /// or `invalidate()`) or when a tree was installed by another path first.
    /// `completion` always runs on the main queue — check ``hasTree`` there:
    /// false means the warm-up was superseded, so re-warm with the current text.
    public func warmUp(text: String, completion: @escaping () -> Void) {
        stateLock.lock()
        let gen = generation
        let alreadyInstalled = tree != nil
        stateLock.unlock()
        if alreadyInstalled {
            DispatchQueue.main.async(execute: completion)
            return
        }
        let tsLanguage = grammar.language
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = Parser()
            try? p.setLanguage(tsLanguage)
            let parsed = p.parse(text)
            if let self, let parsed {
                self.stateLock.lock()
                if self.generation == gen, self.tree == nil {
                    self.tree = parsed
                    self.lastText = text
                    self.fullParseCount += 1
                }
                self.stateLock.unlock()
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    // MARK: - Cached-tree accessors (no parsing — nil/empty until a tree exists)

    /// The cached tree iff it was parsed from exactly `text`; nil when no tree
    /// is installed (pre-parse, warming up, invalidated) or the text diverged
    /// (a desync — `noteEdit` normally keeps the tree current on every edit).
    private func currentTree(matching text: String) -> MutableTree? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let tree, lastText == text else { return nil }
        return tree
    }

    /// Enclosing definition names at `offset` (outermost → innermost) from the
    /// **cached** tree — a node walk, no parse (the static
    /// ``TreeSitterHighlighter/breadcrumbs(at:text:language:)`` re-parses the
    /// whole text per call). Empty until a tree is installed for `text`.
    public func breadcrumbs(at offset: Int, text: String) -> [String] {
        guard let tree = currentTree(matching: text), let root = tree.rootNode else { return [] }
        return TreeSitterHighlighter.breadcrumbs(at: offset, ns: text as NSString, root: root)
    }

    /// Smallest syntax node range strictly larger than `selection` (Expand
    /// Selection), from the **cached** tree — no parse. Nil until a tree is
    /// installed for `text`.
    public func enclosingNodeRange(selection: NSRange, text: String) -> NSRange? {
        guard let tree = currentTree(matching: text), let root = tree.rootNode else { return nil }
        return TreeSitterHighlighter.enclosingNodeRange(selection: selection, ns: text as NSString, root: root)
    }

    /// Range of the next/previous named sibling of the node at `selection`,
    /// from the **cached** tree — no parse. Nil until a tree is installed.
    public func siblingRange(of selection: NSRange, text: String, forward: Bool) -> NSRange? {
        guard let tree = currentTree(matching: text), let root = tree.rootNode,
              let node = TreeSitterHighlighter.nodeSpanning(selection, ns: text as NSString, root: root)
        else { return nil }
        return (forward ? node.nextNamedSibling : node.previousNamedSibling)?.range
    }

    /// Definition symbols in `text` from the **cached** tree — query-only, no
    /// parse (the static ``TreeSitterHighlighter/symbols(in:language:)``
    /// re-parses per call). Empty until a tree is installed for `text`, and for
    /// sessions built via the test seam (no `CodeLanguage` to key the symbol
    /// query).
    public func symbols(text: String) -> [Symbol] {
        guard let language, let tree = currentTree(matching: text) else { return [] }
        return TreeSitterHighlighter.symbols(tree: tree, ns: text as NSString, language: language)
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
        stateLock.lock()
        defer { stateLock.unlock() }
        generation += 1   // any in-flight warm-up is now parsing superseded text
        guard let tree, let old = lastText else { return }
        let oldNS = old as NSString
        let newNS = newText as NSString
        guard range.location >= 0, range.length >= 0, replacementLength >= 0,
              NSMaxRange(range) <= oldNS.length,
              newNS.length == oldNS.length - range.length + replacementLength else {
            self.tree = nil       // desynced with the cached text: full reparse
            self.lastText = nil   // on the next highlight
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
            self.tree = nil
            self.lastText = nil
        }
    }

    /// Highlights `clip` (a viewport range, in `storage` coordinates) from the
    /// cached tree — **no parsing** happens unless this is the first call after
    /// init/``invalidate()``, which parses `text` once.
    ///
    /// Runs the same pipeline as the stateless highlighter: the grammar's
    /// highlights query (later pattern wins, predicates resolved) plus the
    /// recursive injection pass (injections re-parse their sub-documents each
    /// call — see the class note), resolved into the final per-range colors and
    /// applied **diff-aware**: only ranges whose color actually changes are
    /// written, so a pass over an already-settled viewport is zero storage
    /// edits — TextKit 2 reconciles nothing (see
    /// ``TreeSitterHighlighter/applyResolved(hits:clip:defaultColor:into:)``).
    ///
    /// - Parameters:
    ///   - storage: the text storage to color. Only `.foregroundColor` is set.
    ///   - text: the current full document text; must match `storage.string`
    ///     and the text the cached tree was built from (keep the tree current
    ///     via ``noteEdit(range:replacementLength:newText:)``).
    ///   - clip: the range to (re)color; clamped to the storage bounds.
    /// - Note: Must be called on the main thread.
    public func highlight(in storage: NSTextStorage, text: String, clip: NSRange) {
        stateLock.lock()
        if tree == nil {
            tree = parser.parse(text)
            lastText = text
            if tree != nil { fullParseCount += 1 }
        }
        let tree = self.tree
        stateLock.unlock()
        guard let tree else { return }
        let ns = text as NSString
        let clipped = NSIntersectionRange(clip, NSRange(location: 0, length: storage.length))
        guard clipped.length > 0 else { return }

        // ResolvingQueryCursor is main-actor-isolated; highlight only runs on main.
        MainActor.assumeIsolated {
            var base = 0
            var hits = TreeSitterHighlighter.collectHits(grammar.highlights, tree: tree, source: ns,
                                                         offset: 0, clip: clipped, nextBase: &base)
            hits += TreeSitterHighlighter.collectInjectionHits(grammar, tree: tree, source: ns,
                                                               offset: 0, clip: clipped, depth: 0,
                                                               nextBase: &base)
            TreeSitterHighlighter.applyResolved(hits: hits, clip: clipped,
                                                defaultColor: HighlightTheme.colors.foreground,
                                                into: storage)
        }
    }

    /// Drops the cached tree (and its text). The next
    /// ``highlight(in:text:clip:)`` performs one full parse. Call on file
    /// reload, external modification, or language change — anywhere the storage
    /// text changed without a matching ``noteEdit(range:replacementLength:newText:)``.
    public func invalidate() {
        stateLock.lock()
        generation += 1   // discard any in-flight warm-up parse on arrival
        tree = nil
        lastText = nil
        stateLock.unlock()
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
