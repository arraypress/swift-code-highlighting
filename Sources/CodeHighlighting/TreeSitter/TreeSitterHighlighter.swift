import AppKit
import CodeLanguage
import SwiftTreeSitter
import TreeSitterJSON
import TreeSitterCSS
import TreeSitterJavaScript
import TreeSitterPython
import TreeSitterRust
import TreeSitterGo
import TreeSitterHTML
import TreeSitterBash
import TreeSitterC
import TreeSitterJava
import TreeSitterRuby
import TreeSitterTypeScript
import TreeSitterCPP
import TreeSitterCSharp
import TreeSitterPHP
import TreeSitterYAML
import TreeSitterTOML
import TreeSitterLua
import TreeSitterKotlin
import TreeSitterDart
import TreeSitterDockerfile
import TreeSitterSwift

/// Tree-sitter–backed highlighter: parses the buffer into a syntax tree and
/// applies colors from the grammar's `highlights.scm` query. Correct across the
/// whole file (no viewport gaps) and far more accurate than regex.
public final class TreeSitterHighlighter: CodeHighlighter {
    /// A loaded grammar: the language pointer plus its compiled highlight and
    /// (optional) injection queries. Internal (not private) so ``HighlightSession``
    /// can share the loaded grammars and tests can build one from a hand-compiled query.
    struct Grammar { let language: SwiftTreeSitter.Language; let highlights: Query; let injections: Query? }

    /// Grammars we bundle. Add a package + a line here to support a language.
    /// `bundle` is the SwiftPM resource-bundle name: `<Product>_<Product>`.
    /// Internal so ``HighlightSession`` resolves languages through the same table.
    static let grammars: [CodeLanguage.Language: Grammar] = {
        func queryText(_ product: String, _ file: String = "highlights.scm") -> String? {
            guard let url = queryURL(bundle: "\(product)_\(product)", file: file) else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        // `inherits` prepends base grammars' highlights (TS overlays JS; C++ overlays C).
        // `injectHTMLText` adds an HTML injection for inline `text` (PHP templates).
        func g(_ ptr: OpaquePointer?, _ product: String, inherits: [String] = [], injectHTMLText: Bool = false, extra: String = "") -> Grammar? {
            guard let ptr else { return nil }
            let language = SwiftTreeSitter.Language(ptr)
            func build(_ src: String) -> Query? {
                src.isEmpty ? nil : try? Query(language: language, data: Data(src.utf8))
            }
            // Highlights are PRUNED before compiling: patterns that can never
            // paint (all captures map to nil colors) still cost a cursor match
            // per occurrence — see `prunedQuerySource`. Injections must NOT be
            // pruned: their `@injection.*` captures map to no color by design.
            func buildHighlights(_ src: String) -> Query? {
                src.isEmpty ? nil : build(prunedQuerySource(src))
            }
            // `extra` is a Sidewatch supplementary query appended last → wins under
            // later-pattern-wins precedence (e.g. distinguishing JSON keys from values).
            let own = (queryText(product) ?? "") + (extra.isEmpty ? "" : "\n" + extra)
            let combined = inherits.compactMap { queryText($0) }.joined(separator: "\n") + "\n" + own
            guard let highlights = buildHighlights(combined) ?? buildHighlights(own) else { return nil }
            var injSrc = queryText(product, "injections.scm") ?? ""
            if injectHTMLText { injSrc += "\n((text) @injection.content (#set! injection.language \"html\"))\n" }
            return Grammar(language: language, highlights: highlights, injections: injSrc.isEmpty ? nil : build(injSrc))
        }
        var m: [CodeLanguage.Language: Grammar] = [:]
        m[.json]       = g(tree_sitter_json(),       "TreeSitterJSON",
                           extra: "(pair key: (string) @property)\n((number) @number)\n[(true) (false)] @boolean\n(null) @constant.builtin")
        // CSS custom properties (`--brand-primary`) are captured `@variable` upstream
        // with a `^--` guard; the bare-variable role is nil now (see `role(for:)`),
        // so re-capture them as `@property` — sigiled, self-distinguishing tokens
        // that VS Code keeps colored (same hue family as bash's `$VAR` @property).
        m[.css]        = g(tree_sitter_css(),        "TreeSitterCSS",
                           extra: "((property_name) @property (#match? @property \"^--\"))\n((plain_value) @property (#match? @property \"^--\"))")
        m[.javascript] = g(tree_sitter_javascript(), "TreeSitterJavaScript")
        m[.python]     = g(tree_sitter_python(),     "TreeSitterPython")
        m[.rust]       = g(tree_sitter_rust(),       "TreeSitterRust")
        m[.go]         = g(tree_sitter_go(),         "TreeSitterGo")
        m[.html]       = g(tree_sitter_html(),       "TreeSitterHTML")
        m[.bash]      = g(tree_sitter_bash(),       "TreeSitterBash")
        m[.c]          = g(tree_sitter_c(),          "TreeSitterC")
        m[.java]       = g(tree_sitter_java(),       "TreeSitterJava")
        m[.ruby]       = g(tree_sitter_ruby(),       "TreeSitterRuby")
        m[.typescript] = g(tree_sitter_typescript(), "TreeSitterTypeScript", inherits: ["TreeSitterJavaScript"])
        m[.cpp]        = g(tree_sitter_cpp(),        "TreeSitterCPP", inherits: ["TreeSitterC"])
        m[.csharp]     = g(tree_sitter_c_sharp(),    "TreeSitterCSharp")
        // PHP `$vars` are captured `(variable_name) @variable` upstream — nil'd by the
        // bare-variable role now. Like bash's `$VAR`, they're sigiled tokens VS Code
        // keeps colored, so re-capture as `@property` — except `$this`, whose inner
        // `(name)` keeps the `@variable.builtin` color (this extra would outrank it).
        m[.php]        = g(tree_sitter_php(),         "TreeSitterPHP", injectHTMLText: true,
                           extra: "((variable_name) @property (#not-eq? @property \"$this\"))")
        m[.yaml]       = g(tree_sitter_yaml(),       "TreeSitterYAML")
        m[.toml]       = g(tree_sitter_toml(),       "TreeSitterTOML")
        m[.lua]        = g(tree_sitter_lua(),        "TreeSitterLua")
        m[.kotlin]     = g(tree_sitter_kotlin(),     "TreeSitterKotlin")
        m[.dart]       = g(tree_sitter_dart(),       "TreeSitterDart")
        m[.dockerfile] = g(tree_sitter_dockerfile(), "TreeSitterDockerfile")
        m[.swift]      = g(tree_sitter_swift(),      "TreeSitterSwift")
        return m
    }()

    /// Finds a query file inside a grammar's resource bundle, handling both the
    /// flat layout (`swift build`) and the deep layout (Xcode).
    private static func queryURL(bundle: String, file: String = "highlights.scm") -> URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let base = res.appendingPathComponent("\(bundle).bundle")
        let candidates = [
            base.appendingPathComponent("queries/\(file)"),
            base.appendingPathComponent("Contents/Resources/queries/\(file)"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Maps an injection language name (from injections.scm) to a bundled grammar.
    private static func grammarForInjection(_ name: String) -> Grammar? {
        switch name.lowercased() {
        case "html":                   return grammars[.html]
        case "css", "scss":            return grammars[.css]
        case "javascript", "js", "jsx": return grammars[.javascript]
        case "typescript", "ts":       return grammars[.typescript]
        case "json":                   return grammars[.json]
        case "python":                 return grammars[.python]
        case "ruby":                   return grammars[.ruby]
        case "bash", "sh", "shell":    return grammars[.bash]
        case "yaml":                   return grammars[.yaml]
        default:                       return grammars[CodeLanguage.Language(rawValue: name.lowercased()) ?? .plainText]
        }
    }

    /// Whether a grammar (with its query bundle) is loaded for `language` —
    /// i.e. whether `init?(language:)` would succeed. When false, fall back to
    /// the regex ``SyntaxHighlighter``.
    public static func supports(_ language: CodeLanguage.Language) -> Bool { grammars[language] != nil }

    /// How many grammars loaded successfully (a startup sanity check: 0 usually
    /// means the `.bundle` query resources weren't shipped next to the executable).
    public static var loadedCount: Int { grammars.count }

    /// The loaded tree-sitter language object for `language`. Internal for tests
    /// (lets them compile hand-written queries against a bundled grammar).
    static func tsLanguage(for language: CodeLanguage.Language) -> SwiftTreeSitter.Language? {
        grammars[language]?.language
    }

    /// Smallest syntax node whose range is strictly larger than `selection`
    /// (for Expand Selection). Returns nil if unavailable.
    /// - Important: performs a fresh full parse of `text`; on big documents
    ///   prefer ``HighlightSession/enclosingNodeRange(selection:text:)``, which
    ///   walks the session's cached tree instead.
    public static func enclosingNodeRange(selection: NSRange, text: String, language: CodeLanguage.Language) -> NSRange? {
        guard let root = freshParseRoot(text, language: language) else { return nil }
        return enclosingNodeRange(selection: selection, ns: text as NSString, root: root)
    }

    /// Tree-walk half of Expand Selection, against an already-parsed `root`.
    /// Internal so ``HighlightSession`` reuses it with its cached tree.
    static func enclosingNodeRange(selection: NSRange, ns: NSString, root: Node) -> NSRange? {
        guard let node = nodeSpanning(selection, ns: ns, root: root) else { return nil }
        var n = node
        while n.range.length <= selection.length {
            guard let p = n.parent else { return nil }
            n = p
        }
        return n.range
    }

    /// Range of the next/previous named sibling of the node at `selection`.
    /// - Important: performs a fresh full parse of `text`; on big documents
    ///   prefer ``HighlightSession/siblingRange(of:text:forward:)``.
    public static func siblingRange(of selection: NSRange, text: String, language: CodeLanguage.Language, forward: Bool) -> NSRange? {
        guard let root = freshParseRoot(text, language: language) else { return nil }
        guard let node = nodeSpanning(selection, ns: text as NSString, root: root) else { return nil }
        return (forward ? node.nextNamedSibling : node.previousNamedSibling)?.range
    }

    /// Root node of one fresh full parse of `text`, or nil when no grammar is loaded.
    private static func freshParseRoot(_ text: String, language: CodeLanguage.Language) -> Node? {
        guard let g = grammars[language] else { return nil }
        let parser = Parser()
        try? parser.setLanguage(g.language)
        return parser.parse(text)?.rootNode
    }

    /// The smallest syntax node covering `selection` in an already-parsed tree.
    /// Internal so ``HighlightSession`` reuses it with its cached tree.
    static func nodeSpanning(_ selection: NSRange, ns: NSString, root: Node) -> Node? {
        guard NSMaxRange(selection) <= ns.length else { return nil }
        // SwiftTreeSitter parses strings as UTF-16LE, so a tree-sitter byte offset
        // equals the UTF-16 (NSRange) index × 2 — NOT the UTF-8 byte count.
        let byteStart = selection.location * 2
        let byteLen = selection.length * 2
        return root.descendant(in: UInt32(byteStart)..<UInt32(byteStart + byteLen))
    }

    /// Compiled symbol queries, cached per language (guarded by `symbolCacheLock`).
    private static var symbolQueryCache: [CodeLanguage.Language: Query] = [:]
    private static let symbolCacheLock = NSLock()

    /// All definition symbols (functions, classes, …) in `text`, ordered by
    /// position. Empty when the language has no symbol query or the grammar
    /// isn't loaded. Thread-safe (the project index calls this off the main queue).
    /// - Important: performs a fresh full parse of `text`; on big open documents
    ///   prefer ``HighlightSession/symbols(text:)``, which queries the cached tree.
    public static func symbols(in text: String, language: CodeLanguage.Language) -> [Symbol] {
        guard let g = grammars[language], SymbolQueries.sources[language] != nil else { return [] }
        let parser = Parser()
        try? parser.setLanguage(g.language)
        guard let tree = parser.parse(text) else { return [] }
        return symbols(tree: tree, ns: text as NSString, language: language)
    }

    /// Query half of ``symbols(in:language:)``, against an already-parsed tree.
    /// Internal so ``HighlightSession`` reuses it with its cached tree.
    static func symbols(tree: MutableTree, ns: NSString, language: CodeLanguage.Language) -> [Symbol] {
        guard let g = grammars[language], let src = SymbolQueries.sources[language] else { return [] }
        symbolCacheLock.lock()
        var query = symbolQueryCache[language]
        symbolCacheLock.unlock()
        if query == nil {
            guard let q = try? Query(language: g.language, data: Data(src.utf8)) else { return [] }
            symbolCacheLock.lock(); symbolQueryCache[language] = q; symbolCacheLock.unlock()
            query = q
        }
        guard let query else { return [] }
        var out: [Symbol] = []
        let cursor = query.execute(in: tree)
        while let match = cursor.next() {
            for capture in match.captures {
                guard let name = capture.name, let kind = SymbolKind(capture: name) else { continue }
                let r = capture.range
                guard r.length > 0, NSMaxRange(r) <= ns.length else { continue }
                let line = ns.substring(to: r.location).components(separatedBy: "\n").count
                out.append(Symbol(name: ns.substring(with: r), kind: kind, range: r, line: line))
            }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// For hover-doc: the definition signature + preceding doc comment for `word`,
    /// if it's defined in `text`. Returns nil when the word isn't a known symbol.
    public static func hoverInfo(for word: String, in text: String, language: CodeLanguage.Language) -> (kind: SymbolKind, signature: NSAttributedString, doc: String)? {
        guard word.count > 1, let sym = symbols(in: text, language: language).first(where: { $0.name == word }) else { return nil }
        let ns = text as NSString
        guard sym.range.location <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: sym.range.location, length: 0))
        var signature = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
        while signature.hasSuffix("{") || signature.hasSuffix("}") || signature.hasSuffix(";") {
            signature = String(signature.dropLast())
        }
        signature = signature.trimmingCharacters(in: .whitespaces)
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        return (sym.kind, attributedSnippet(signature, language: language, font: mono), docComment(above: lineRange.location, in: ns, language: language))
    }

    /// Syntax-highlights a short code snippet (e.g. a hover signature) into an
    /// attributed string. Appends "{}" so a body-less definition still parses.
    public static func attributedSnippet(_ code: String, language: CodeLanguage.Language, font: NSFont) -> NSAttributedString {
        let storage = NSTextStorage(string: code + " {}",
                                    attributes: [.font: font, .foregroundColor: HighlightTheme.colors.foreground])
        if let hl = TreeSitterHighlighter(language: language) {
            storage.beginEditing()
            hl.highlight(storage, in: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        let len = (code as NSString).length
        guard len <= storage.length else { return storage }
        return storage.attributedSubstring(from: NSRange(location: 0, length: len))
    }

    /// Enclosing definition names at `offset` (outermost → innermost) for breadcrumbs,
    /// e.g. ["UserRepository", "findById"].
    /// - Important: performs a fresh full parse of `text` (~620 ms on a 2.8 MB
    ///   Swift file); on open documents prefer ``HighlightSession/breadcrumbs(at:text:)``,
    ///   which walks the session's cached tree in microseconds.
    public static func breadcrumbs(at offset: Int, text: String, language: CodeLanguage.Language) -> [String] {
        guard let root = freshParseRoot(text, language: language) else { return [] }
        return breadcrumbs(at: offset, ns: text as NSString, root: root)
    }

    /// A reusable breadcrumb resolver over **one** parse of `text`: parses once,
    /// then each call to the returned closure is a cached-tree walk (microseconds).
    /// Use when resolving many offsets in the same text — e.g. Blast Radius maps
    /// every changed line to its enclosing symbol, and the per-call static
    /// ``breadcrumbs(at:text:language:)`` re-parses the whole file *per line*
    /// (~620 ms each on a 2.8 MB Swift file). Nil when no grammar is loaded.
    /// The closure retains the parsed tree (a root `Node` keeps its `Tree` alive)
    /// and is safe on any single thread — confine it to the thread that made it.
    public static func breadcrumbResolver(text: String, language: CodeLanguage.Language) -> ((Int) -> [String])? {
        guard let root = freshParseRoot(text, language: language) else { return nil }
        let ns = text as NSString
        return { offset in breadcrumbs(at: offset, ns: ns, root: root) }
    }

    /// Tree-walk half of ``breadcrumbs(at:text:language:)``, against an
    /// already-parsed `root`. Internal so ``HighlightSession`` reuses it.
    static func breadcrumbs(at offset: Int, ns: NSString, root: Node) -> [String] {
        guard offset <= ns.length else { return [] }
        let byteOffset = offset * 2   // UTF-16 index → tree-sitter byte offset
        guard let node = root.descendant(in: UInt32(byteOffset)..<UInt32(byteOffset)) else { return [] }
        let keywords = ["function", "method", "class", "struct", "enum", "interface",
                        "namespace", "module", "impl", "trait", "constructor", "object"]
        var path: [String] = []
        var cur: Node? = node
        while let n = cur {
            let type = n.nodeType ?? ""
            if keywords.contains(where: { type.contains($0) }),
               let nameNode = n.child(byFieldName: "name"),
               NSMaxRange(nameNode.range) <= ns.length {
                path.insert(ns.substring(with: nameNode.range), at: 0)
            }
            cur = n.parent
        }
        return path
    }

    /// Contiguous comment lines immediately above `location` (a doc block).
    /// The recognized markers come from `language`'s own comment tokens, so a
    /// C-family `#include`/`#define` line (not a comment there) or a shebang is
    /// never absorbed as documentation. Internal for tests.
    static func docComment(above location: Int, in ns: NSString, language: CodeLanguage.Language) -> String {
        let markers = docMarkers(for: language)
        guard !markers.isEmpty else { return "" }
        var lines: [String] = []
        var idx = location
        while idx > 0 {
            let prev = ns.lineRange(for: NSRange(location: idx - 1, length: 0))
            var raw = ns.substring(with: prev)
            while raw.hasSuffix("\n") || raw.hasSuffix("\r") { raw.removeLast() }
            let afterIndent = raw.drop { $0 == " " || $0 == "\t" }   // indentation before the marker
            guard let marker = markers.first(where: { afterIndent.hasPrefix($0) }) else { break }
            if marker == "#", afterIndent.hasPrefix("#!") { break }   // shebang, not a doc line
            var content = String(afterIndent.dropFirst(marker.count))
            if content.hasPrefix(" ") { content.removeFirst() }   // just the conventional space after the marker
            if content.hasSuffix("*/") { content = String(content.dropLast(2)) }
            lines.insert(content, at: 0)   // keep the REST of the spacing (e.g. @param column alignment)
            idx = prev.location
            if prev.location == 0 { break }
        }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Doc-comment markers for `language`, derived from its own comment tokens
    /// (so '#' is a marker for Python/Ruby/Bash but never for C-family files).
    /// "*" is last among the block markers so "/**", "/*", "*/" match first.
    private static func docMarkers(for language: CodeLanguage.Language) -> [String] {
        var markers: [String] = []
        if let line = language.lineCommentToken {
            if line == "//" { markers.append("///") }   // doc variants of the plain token
            if line == "--" { markers.append("---") }
            markers.append(line)
        }
        if let block = language.blockComment {
            if block.open == "/*" {
                markers += ["/**", "/*", "*/", "*"]
            } else {
                markers += [block.open, block.close]
            }
        }
        return markers
    }

    private let grammar: Grammar
    private let parser = Parser()

    /// Creates a highlighter for `language`, or nil when no grammar is loaded
    /// for it (check with ``supports(_:)``; fall back to ``SyntaxHighlighter``).
    public init?(language: CodeLanguage.Language) {
        guard let g = Self.grammars[language] else { return nil }
        grammar = g
        try? parser.setLanguage(g.language)
    }

    /// Reparses the whole buffer and recolors the lines that intersect
    /// `editedRange` (expanded to whole lines), including injected languages.
    /// Colors are applied diff-aware (see `applyResolved`): only ranges whose
    /// color actually changes are written, so unchanged regions cost TextKit
    /// nothing to reconcile.
    /// - Note: Must be called on the main thread (the resolving query cursor is
    ///   main-actor-isolated). Only `.foregroundColor` is touched, never `.font`.
    public func highlight(_ storage: NSTextStorage, in editedRange: NSRange) {
        let full = NSRange(location: 0, length: storage.length)
        let ns = storage.string as NSString
        let range = ns.length == 0 ? full
            : ns.lineRange(for: NSRange(location: min(editedRange.location, ns.length), length: 0))
                .union(ns.lineRange(for: NSRange(location: min(NSMaxRange(editedRange), ns.length), length: 0)))

        guard let tree = parser.parse(storage.string) else { return }

        // ResolvingQueryCursor is main-actor-isolated; highlight() only runs on main.
        MainActor.assumeIsolated {
            var base = 0
            var hits = Self.collectHits(grammar.highlights, tree: tree, source: ns,
                                        offset: 0, clip: range, nextBase: &base)
            hits += Self.collectInjectionHits(grammar, tree: tree, source: ns,
                                              offset: 0, clip: range, depth: 0, nextBase: &base)
            Self.applyResolved(hits: hits, clip: NSIntersectionRange(range, full),
                               defaultColor: HighlightTheme.colors.foreground, into: storage)
        }
    }

    /// Whether hosts should draw a small color swatch beside hex color literals.
    /// A rendering preference for the host editor — this class never draws chips itself.
    public static var showColorChips = true

    /// Matches `#RGB` / `#RRGGBB` / `#RRGGBBAA` hex color literals, for hosts
    /// locating chip positions.
    public static let colorRegex = try? NSRegularExpression(
        pattern: "#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})\\b")

    /// Parses a `#RGB` / `#RRGGBB` / `#RRGGBBAA` literal (leading `#` optional)
    /// into an sRGB color; nil when the string isn't a valid hex color.
    public static func colorFromHex(_ hex: String) -> NSColor? {
        var s = Substring(hex)
        if s.hasPrefix("#") { s = s.dropFirst() }
        if s.count == 3 { s = Substring(s.map { "\($0)\($0)" }.joined()) }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b: CGFloat
        var a: CGFloat = 1
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xFF) / 255; g = CGFloat((v >> 16) & 0xFF) / 255
            b = CGFloat((v >> 8) & 0xFF) / 255;  a = CGFloat(v & 0xFF) / 255
        } else {
            r = CGFloat((v >> 16) & 0xFF) / 255; g = CGFloat((v >> 8) & 0xFF) / 255; b = CGFloat(v & 0xFF) / 255
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// One resolved capture hit: an absolute storage range, its precedence key,
    /// and the color it paints. `pattern` is the capture's patternIndex plus the
    /// pass's base (see `collectHits`), so hits from several query passes sort
    /// into the same later-wins order the old sequential application produced.
    typealias Hit = (range: NSRange, pattern: Int, color: NSColor)

    /// Runs a highlights query over `tree` (parsed from `source`), resolving
    /// predicates, and returns the colored capture hits offset into storage
    /// coordinates by `offset`, clipped to `clip`.
    ///
    /// The query cursor is **bounded to the clip** (translated into source
    /// coordinates; bytes = UTF-16 index × 2 — the load-bearing SwiftTreeSitter
    /// rule), so match iteration is O(viewport), not O(document). Unbounded, a
    /// per-viewport pass on a multi-megabyte file iterated every match in the
    /// file (~2.4 s on a 2.8 MB Swift file) only to clip them at paint time.
    /// `ts_query_cursor_set_byte_range` keeps every match that *intersects* the
    /// range, so edge-straddling tokens still arrive and the paint-time clipping
    /// trims them exactly as before.
    ///
    /// Each call consumes one precedence window from `nextBase`: returned hit
    /// `pattern`s start at the current base, and `nextBase` advances so a later
    /// pass (an injection) always outranks this one — exactly the "applied
    /// afterwards, overwrites on overlap" behavior of sequential application.
    @MainActor
    static func collectHits(_ query: Query, tree: MutableTree, source ns: NSString,
                            offset: Int, clip: NSRange, nextBase: inout Int) -> [Hit] {
        let base = nextBase
        nextBase += 1_000_000
        guard clip.length > 0 else { return [] }   // nothing can paint inside an empty clip
        let cursor = query.execute(in: tree)
        // Clip in source (query) coordinates, clamped to the source bounds.
        let lower = min(max(0, clip.location - offset), ns.length)
        let upper = min(max(lower, NSMaxRange(clip) - offset), ns.length)
        guard upper > lower else { return [] }     // the clip lies wholly outside this source
        cursor.setRange(NSRange(location: lower, length: upper - lower))
        let resolving = ResolvingQueryCursor(cursor: cursor)
        resolving.prepare(with: { r, _ in NSMaxRange(r) <= ns.length ? ns.substring(with: r) : nil })
        var hits: [Hit] = []
        while let match = resolving.next() {
            for capture in match.captures {
                guard let name = capture.name, let color = color(for: name) else { continue }
                let r = capture.range
                guard r.length > 0, NSMaxRange(r) <= ns.length else { continue }
                hits.append((NSRange(location: offset + r.location, length: r.length),
                             base + capture.patternIndex, color))
            }
        }
        return hits
    }

    /// Query-then-paint in one call — the pre-collect pipeline, kept as the
    /// hand-built-query seam for tests (`dumpCaptures` has its own loop and the
    /// product paths use `collectHits` + `applyResolved`).
    @MainActor
    static func applyQuery(_ query: Query, tree: MutableTree, source ns: NSString,
                           offset: Int, clip: NSRange, into storage: NSTextStorage) {
        var base = 0
        apply(hits: collectHits(query, tree: tree, source: ns, offset: offset,
                                clip: clip, nextBase: &base),
              clip: clip, into: storage)
    }

    /// Applies the RESOLVED highlight state of `clip` — `defaultColor` overlaid
    /// by `hits`, higher `pattern` winning on overlap — as the MINIMAL set of
    /// attribute writes: desired colors are computed first, then compared run by
    /// run against what the storage already holds, and only differing ranges are
    /// written. Post-state is identical to the old "blanket foreground reset +
    /// one addAttribute per hit" pipeline, but a pass over an already-settled
    /// viewport produces ZERO writes — so `endEditing` never fires processEditing,
    /// TextKit 2 invalidates nothing, and no fragment re-layout follows. That
    /// reconcile was the single largest cost of every scroll re-highlight
    /// (~19–41 ms per pass measured on a 2.8 MB file, scaling with hit density).
    ///
    /// Returns the number of attribute writes performed — 0 means the pass was
    /// a no-op for TextKit (nothing invalidated), which hosts use to skip their
    /// post-pass layout settle entirely.
    @discardableResult
    static func applyResolved(hits: [Hit], clip: NSRange, defaultColor: NSColor,
                              into storage: NSTextStorage) -> Int {
        let clipped = NSIntersectionRange(clip, NSRange(location: 0, length: storage.length))
        guard clipped.length > 0 else { return 0 }

        // Desired color per position, painted in ascending precedence so later
        // patterns overwrite earlier ones — same math as sequential application.
        var desired = ContiguousArray<NSColor?>(repeating: nil, count: clipped.length)
        for hit in hits.sorted(by: { $0.pattern < $1.pattern }) {
            let r = NSIntersectionRange(hit.range, clipped)
            guard r.length > 0 else { continue }
            for i in (r.location - clipped.location)..<(NSMaxRange(r) - clipped.location) {
                desired[i] = hit.color
            }
        }

        // Diff desired runs against the storage's existing colors; collect only
        // the mismatching ranges. Runs are merged by object identity (theme
        // colors are stable per role), with isEqual deciding an actual rewrite.
        var writes: [(range: NSRange, color: NSColor)] = []
        storage.enumerateAttribute(.foregroundColor, in: clipped, options: []) { value, range, _ in
            let existing = value as? NSColor
            var i = range.location
            while i < NSMaxRange(range) {
                let want = desired[i - clipped.location] ?? defaultColor
                var j = i + 1
                while j < NSMaxRange(range), (desired[j - clipped.location] ?? defaultColor) === want { j += 1 }
                if !(existing === want), !(existing?.isEqual(want) ?? false) {
                    if let last = writes.last, NSMaxRange(last.range) == i, last.color === want {
                        writes[writes.count - 1].range.length += j - i   // coalesce across run seams
                    } else {
                        writes.append((NSRange(location: i, length: j - i), want))
                    }
                }
                i = j
            }
        }
        for w in writes {
            storage.addAttribute(.foregroundColor, value: w.color, range: w.range)
            writeObserver?(w.range)
        }
        return writes.count
    }

    /// Diagnostic seam: invoked once per ACTUAL attribute write (the minimal
    /// diff-aware ranges), so hosts/probes can verify the zero-write contract
    /// over settled text. Nil (and free) in production. Main-thread only,
    /// like `highlight` itself.
    public static var writeObserver: ((NSRange) -> Void)?

    /// Applies collected capture hits: later `patternIndex` wins (hits are applied
    /// in ascending pattern order so later patterns overwrite earlier ones), and
    /// every range is clipped to `clip` — a hit partially outside is trimmed, one
    /// fully outside is dropped. Internal (not private) so tests can exercise the
    /// precedence + clamping math with precomputed hits.
    static func apply(hits: [(range: NSRange, pattern: Int, color: NSColor)],
                      clip: NSRange, into storage: NSTextStorage) {
        for hit in hits.sorted(by: { $0.pattern < $1.pattern }) {
            let r = NSIntersectionRange(hit.range, clip)
            if r.length > 0 { storage.addAttribute(.foregroundColor, value: hit.color, range: r) }
        }
    }

    /// All injection sites in `tree`, grouped by injected language and merged into
    /// ascending, non-overlapping ranges. Grouping lets every chunk of the same
    /// language parse as ONE document via `Parser.includedRanges`, so constructs
    /// split across chunks (e.g. `<section>`…`</section>` around a PHP block, whose
    /// HTML arrives as separate `text` nodes) still pair instead of parsing as errors.
    ///
    /// When `clip` is non-nil the cursor is bounded to it (source coordinates),
    /// making per-viewport passes O(viewport): sites *intersecting* the clip are
    /// still collected whole, but sibling chunks entirely outside it no longer
    /// join the combined parse — for viewport-tier files (> ~100k chars) a
    /// construct split across an off-screen chunk may highlight slightly
    /// differently at the clip edge, an accepted trade (small files always pass
    /// whole-document clips). Whole-document callers (`dumpCaptures`) pass nil.
    ///
    /// Matches go through a `ResolvingQueryCursor` so injection PREDICATES are
    /// honored — a plain cursor ignores them, which turned e.g. lua's
    /// `((function_call …) (#eq? @_cdef_identifier "cdef"))` ffi.cdef rule into
    /// "inject C into EVERY single-string function call": whole Lua files had
    /// their ordinary string arguments parsed as C (garbage tokens), and the
    /// clip-dependent combined parse repainted those strings differently on
    /// every viewport pass — measured 18k chars of redundant attribute rewrites
    /// per scroll on a 100 KB Lua file, each one invalidating TK2 fragment
    /// layout mid-scroll.
    @MainActor
    private static func injectionSites(_ injQuery: Query, tree: MutableTree, ns: NSString,
                                       clip: NSRange? = nil) -> [(name: String, ranges: [NSRange])] {
        var grouped: [String: [NSRange]] = [:]
        var order: [String] = []
        let cursor = injQuery.execute(in: tree)
        if let clip {
            let lower = min(max(0, clip.location), ns.length)
            let upper = min(max(lower, NSMaxRange(clip)), ns.length)
            if upper > lower { cursor.setRange(NSRange(location: lower, length: upper - lower)) }
        }
        let resolving = ResolvingQueryCursor(cursor: cursor)
        resolving.prepare(with: { r, _ in NSMaxRange(r) <= ns.length ? ns.substring(with: r) : nil })
        while let match = resolving.next() {
            guard let named = match.injection(with: { r, _ in NSMaxRange(r) <= ns.length ? ns.substring(with: r) : nil }),
                  let content = match.captures(named: "injection.content").first else { continue }
            let r = content.range
            guard r.length > 0, NSMaxRange(r) <= ns.length else { continue }
            if grouped[named.name] == nil { order.append(named.name) }
            grouped[named.name, default: []].append(r)
        }
        return order.map { name in (name, mergeAscending(grouped[name]!)) }
    }

    /// Sorts `ranges` ascending and unions overlapping/adjacent ones — tree-sitter
    /// requires included ranges to be ascending and non-overlapping.
    static func mergeAscending(_ ranges: [NSRange]) -> [NSRange] {
        var merged: [NSRange] = []
        for r in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, NSMaxRange(last) >= r.location {
                merged[merged.count - 1] = last.union(r)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// Parses the whole of `ns` restricted to `ranges` — one combined document per
    /// injected language. Byte offsets are UTF-16 index × 2 (SwiftTreeSitter parses
    /// UTF-16LE); points come from a single forward newline scan (column in bytes).
    private static func combinedParse(_ sub: Grammar, ns: NSString, ranges: [NSRange]) -> MutableTree? {
        let p = Parser()
        try? p.setLanguage(sub.language)
        var row = 0, lastNL = -1, scan = 0
        func point(at idx: Int) -> Point {
            while scan < idx {
                if ns.character(at: scan) == 0x0A { row += 1; lastNL = scan }
                scan += 1
            }
            return Point(row: row, column: (idx - lastNL - 1) * 2)
        }
        p.includedRanges = ranges.map { r in
            let start = point(at: r.location), end = point(at: NSMaxRange(r))
            return TSRange(points: start..<end, bytes: UInt32(r.location * 2)..<UInt32(NSMaxRange(r) * 2))
        }
        return p.parse(ns as String)
    }

    /// Recursively collects hits for embedded languages (CSS in `<style>`, JS in
    /// `<script>`, HTML in PHP templates, …), depth-limited. All chunks of one
    /// injected language share a single combined parse (see `injectionSites`);
    /// capture ranges therefore stay absolute within `ns` and `offset` is unchanged.
    /// Visit order matches the old sequential-application order (site, then its
    /// nested injections, depth-first), and every pass takes a later `nextBase`
    /// window, so deeper/later passes win on overlap exactly as before.
    /// Internal (not private) so ``HighlightSession`` runs the same injection pass.
    @MainActor
    static func collectInjectionHits(_ g: Grammar, tree: MutableTree, source ns: NSString,
                                     offset: Int, clip: NSRange, depth: Int,
                                     nextBase: inout Int) -> [Hit] {
        guard depth < 3, let injQuery = g.injections else { return [] }
        var hits: [Hit] = []
        let sourceClip = NSRange(location: max(0, clip.location - offset), length: clip.length)
        for site in injectionSites(injQuery, tree: tree, ns: ns, clip: sourceClip) {
            guard let sub = grammarForInjection(site.name) else { continue }
            guard site.ranges.contains(where: {
                NSIntersectionRange(NSRange(location: offset + $0.location, length: $0.length), clip).length > 0
            }) else { continue }
            guard let subTree = combinedParse(sub, ns: ns, ranges: site.ranges) else { continue }
            hits += collectHits(sub.highlights, tree: subTree, source: ns,
                                offset: offset, clip: clip, nextBase: &nextBase)
            hits += collectInjectionHits(sub, tree: subTree, source: ns, offset: offset,
                                         clip: clip, depth: depth + 1, nextBase: &nextBase)
        }
        return hits
    }

    /// Strips top-level query patterns whose captures ALL map to nil colors
    /// (punctuation, brackets, operators, …) before the query is compiled.
    ///
    /// Those patterns can never paint anything — `color(for:)` drops their
    /// captures — but the query cursor still yields a match per occurrence.
    /// On symbol-dense grammars that is real scroll-time cost: the vendored
    /// Swift query spent ~1/3 of its per-viewport captures (365 of 1096 on a
    /// 30k-char pass, measured) on punctuation/operator patterns that were
    /// discarded at paint time. Removing whole patterns preserves precedence:
    /// later-pattern-wins is *relative* order, which pruning keeps intact.
    ///
    /// The parser understands the query grammar shallowly but safely: top-level
    /// forms (`(...)`, `[...]`, `"literal"`) with their trailing quantifiers and
    /// `@capture` chains are treated as one pattern; `;` comments are kept;
    /// anything unrecognized (bare tokens like a stray anchor) is copied
    /// verbatim, never pruned — unknown syntax can only be kept, not dropped.
    /// If pruning would leave nothing, the original source is returned.
    static func prunedQuerySource(_ src: String) -> String {
        let s = Array(src.unicodeScalars)
        let n = s.count
        var out = String.UnicodeScalarView()
        var kept = 0
        func isWS(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\n" || c == "\t" || c == "\r" }

        /// Consumes one balanced form starting at `i` (paren/bracket group or
        /// quoted string), honoring nested strings/comments; returns the index
        /// one past its end.
        func consumeForm(_ i: Int) -> Int {
            var i = i
            if s[i] == "\"" {
                i += 1
                while i < n {
                    if s[i] == "\\" { i += 2; continue }
                    if s[i] == "\"" { return i + 1 }
                    i += 1
                }
                return i
            }
            var depth = 0
            while i < n {
                switch s[i] {
                case "\"":
                    i += 1
                    while i < n, s[i] != "\"" { i += s[i] == "\\" ? 2 : 1 }
                case "(", "[": depth += 1
                case ")", "]":
                    depth -= 1
                    if depth == 0 { return i + 1 }
                case ";":
                    while i < n, s[i] != "\n" { i += 1 }
                default: break
                }
                i += 1
            }
            return i
        }

        var i = 0
        while i < n {
            let c = s[i]
            if isWS(c) {
                out.append(c); i += 1
            } else if c == ";" {                               // top-level comment line
                while i < n, s[i] != "\n" { out.append(s[i]); i += 1 }
            } else if c == "(" || c == "[" || c == "\"" {      // one pattern
                let start = i
                i = consumeForm(i)
                // Trailing quantifiers and capture chains belong to this pattern.
                while i < n {
                    var k = i
                    while k < n, isWS(s[k]) { k += 1 }
                    if k < n, s[k] == "?" || s[k] == "*" || s[k] == "+" {
                        i = k + 1
                    } else if k < n, s[k] == "@" {
                        k += 1
                        while k < n, !isWS(s[k]), s[k] != "(", s[k] != ")",
                              s[k] != "[", s[k] != "]", s[k] != ";" { k += 1 }
                        i = k
                    } else { break }
                }
                let chunk = String(String.UnicodeScalarView(s[start..<i]))
                if patternCanPaint(chunk) {
                    out.append(contentsOf: chunk.unicodeScalars)
                    kept += 1
                }
                out.append("\n")
            } else {                                           // unknown bare token: keep verbatim
                while i < n, !isWS(s[i]) { out.append(s[i]); i += 1 }
            }
        }
        return kept > 0 ? String(out) : src
    }

    /// Whether any `@capture` in one pattern's text maps to a colored role —
    /// i.e. whether the pattern can ever contribute a visible hit.
    private static func patternCanPaint(_ chunk: String) -> Bool {
        var scalars = Substring(chunk).unicodeScalars[...]
        while let at = scalars.firstIndex(of: "@") {
            var j = scalars.index(after: at)
            var name = ""
            while j < scalars.endIndex {
                let c = scalars[j]
                if c == " " || c == "\n" || c == "\t" || c == "\r" || c == "(" || c == ")"
                    || c == "[" || c == "]" || c == ";" || c == "\"" { break }
                name.unicodeScalars.append(c)
                j = scalars.index(after: j)
            }
            if role(for: name) != nil { return true }
            scalars = scalars[j...]
        }
        return false
    }

    /// The semantic role for a tree-sitter capture (first dotted component), e.g.
    /// "function.method" → "function", "variable.parameter" → "variable".
    ///
    /// The BARE `variable`/`identifier` captures map to nil (default text) on
    /// purpose: most vendored queries carry an nvim-convention catch-all like
    /// `(identifier) @variable` that captures *every* plain identifier, which
    /// painted whole files in the variable color (~39% of all tokens in a real
    /// Lua file — an "error wash", not highlighting). VS Code leaves plain
    /// identifier references at the default foreground; so do we. Qualified
    /// variable captures stay colored: `@variable.builtin` (self/this),
    /// `@variable.parameter` / `@parameter`, `@variable.member`. Sigiled
    /// variables that read as tokens in their own right ($VAR in bash, $var in
    /// PHP, --custom-props in CSS) are kept colored via `@property` captures in
    /// the vendored/`extra` queries instead.
    public static func role(for capture: String) -> String? {
        if capture == "variable" || capture == "identifier" { return nil }   // bare catch-alls
        switch capture.split(separator: ".").first.map(String.init) ?? capture {
        case "keyword", "conditional", "repeat", "include", "exception",
             "storageclass", "label", "tag":            return "keyword"
        case "string", "character", "escape":           return "string"
        case "comment", "spell":                        return "comment"
        case "number", "float":                         return "number"
        case "boolean", "constant":                     return "constant"
        case "type", "constructor", "namespace", "module", "class": return "type"
        case "function", "method":                      return "function"
        case "variable", "parameter":                   return "variable"
        case "property", "field", "member", "attribute", "annotation", "decorator":
            return "property"
        default:                                        return nil
        }
    }

    /// Maps a capture name to a theme color via its role.
    private static func color(for capture: String) -> NSColor? {
        switch role(for: capture) {
        case "keyword":            return HighlightTheme.colors.color(for: .keyword)
        case "string":             return HighlightTheme.colors.color(for: .string)
        case "comment":            return HighlightTheme.colors.color(for: .comment)
        case "number", "constant": return HighlightTheme.colors.color(for: .number)
        case "type":               return HighlightTheme.colors.color(for: .type)
        case "function":           return HighlightTheme.colors.color(for: .function)
        case "variable":           return HighlightTheme.colors.color(for: .variable)
        case "property":           return HighlightTheme.colors.color(for: .property)
        default:                   return nil
        }
    }

    /// Headless validation: prints every token → capture → role for a file so
    /// highlighting can be verified across languages without opening the app.
    /// Invoked via `Sidewatch --dump-captures <file>`.
    public static func dumpCaptures(path: String) {
        let url = URL(fileURLWithPath: path)
        let lang = CodeLanguage.Language.detect(for: url)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            print("!! cannot read \(path)"); return
        }
        guard let g = grammars[lang] else {
            print("!! no tree-sitter grammar for \(lang.displayName) (\(url.lastPathComponent))"); return
        }
        let ns = content as NSString
        print("== \(url.lastPathComponent)  [\(lang.displayName)] ==")
        MainActor.assumeIsolated {
            var winners: [String: (loc: Int, text: String, name: String, pattern: Int, lang: String)] = [:]
            collectWinners(g, source: content, ns: ns, offset: 0, lang: lang.displayName, depth: 0, into: &winners)
            for w in winners.values.sorted(by: { $0.loc < $1.loc }) {
                let role = Self.role(for: w.name) ?? "·default·"
                let tag = w.lang == lang.displayName ? "" : "   «\(w.lang)»"
                print("  \(w.text.padding(toLength: 20, withPad: " ", startingAt: 0))  @\(w.name.padding(toLength: 20, withPad: " ", startingAt: 0)) → \(role)\(tag)")
            }
        }
    }

    /// Collects the winning (highest-`patternIndex`) capture per token span,
    /// recursing into injections — the data behind `dumpCaptures`.
    @MainActor
    private static func collectWinners(_ g: Grammar, source: String, ns: NSString, offset: Int, lang: String, depth: Int,
                                       ranges: [NSRange]? = nil,
                                       into winners: inout [String: (loc: Int, text: String, name: String, pattern: Int, lang: String)]) {
        let tree: MutableTree?
        if let ranges {
            tree = combinedParse(g, ns: ns, ranges: ranges)
        } else {
            let parser = Parser()
            try? parser.setLanguage(g.language)
            tree = parser.parse(source)
        }
        guard let tree else { return }
        let cursor = g.highlights.execute(in: tree)
        let resolving = ResolvingQueryCursor(cursor: cursor)
        resolving.prepare(with: { r, _ in NSMaxRange(r) <= ns.length ? ns.substring(with: r) : nil })
        while let match = resolving.next() {
            for cap in match.captures {
                guard let name = cap.name, NSMaxRange(cap.range) <= ns.length else { continue }
                let text = ns.substring(with: cap.range).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= 30 else { continue }
                let absLoc = offset + cap.range.location
                let key = "\(absLoc):\(cap.range.length)"
                if let ex = winners[key], ex.pattern >= cap.patternIndex { continue }
                winners[key] = (absLoc, text, name, cap.patternIndex, lang)
            }
        }
        guard depth < 3, let injQuery = g.injections else { return }
        for site in injectionSites(injQuery, tree: tree, ns: ns) {
            guard let sub = grammarForInjection(site.name) else { continue }
            collectWinners(sub, source: source, ns: ns, offset: offset,
                           lang: site.name, depth: depth + 1, ranges: site.ranges, into: &winners)
        }
    }
}

extension NSRange {
    /// The smallest range covering both `self` and `other` (`NSUnionRange`).
    func union(_ other: NSRange) -> NSRange { NSUnionRange(self, other) }
}
