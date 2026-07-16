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
            // `extra` is a Sidewatch supplementary query appended last → wins under
            // later-pattern-wins precedence (e.g. distinguishing JSON keys from values).
            let own = (queryText(product) ?? "") + (extra.isEmpty ? "" : "\n" + extra)
            let combined = inherits.compactMap { queryText($0) }.joined(separator: "\n") + "\n" + own
            guard let highlights = build(combined) ?? build(own) else { return nil }
            var injSrc = queryText(product, "injections.scm") ?? ""
            if injectHTMLText { injSrc += "\n((text) @injection.content (#set! injection.language \"html\"))\n" }
            return Grammar(language: language, highlights: highlights, injections: injSrc.isEmpty ? nil : build(injSrc))
        }
        var m: [CodeLanguage.Language: Grammar] = [:]
        m[.json]       = g(tree_sitter_json(),       "TreeSitterJSON",
                           extra: "(pair key: (string) @property)\n((number) @number)\n[(true) (false)] @boolean\n(null) @constant.builtin")
        m[.css]        = g(tree_sitter_css(),        "TreeSitterCSS")
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
        m[.php]        = g(tree_sitter_php(),         "TreeSitterPHP", injectHTMLText: true)
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
    public static func enclosingNodeRange(selection: NSRange, text: String, language: CodeLanguage.Language) -> NSRange? {
        guard let node = nodeSpanning(selection, text: text, language: language) else { return nil }
        var n = node
        while n.range.length <= selection.length {
            guard let p = n.parent else { return nil }
            n = p
        }
        return n.range
    }

    /// Range of the next/previous named sibling of the node at `selection`.
    public static func siblingRange(of selection: NSRange, text: String, language: CodeLanguage.Language, forward: Bool) -> NSRange? {
        guard let node = nodeSpanning(selection, text: text, language: language) else { return nil }
        return (forward ? node.nextNamedSibling : node.previousNamedSibling)?.range
    }

    /// The smallest syntax node covering `selection` (a fresh parse of `text`).
    private static func nodeSpanning(_ selection: NSRange, text: String, language: CodeLanguage.Language) -> Node? {
        guard let g = grammars[language] else { return nil }
        let parser = Parser()
        try? parser.setLanguage(g.language)
        guard let tree = parser.parse(text), let root = tree.rootNode else { return nil }
        let ns = text as NSString
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
    public static func symbols(in text: String, language: CodeLanguage.Language) -> [Symbol] {
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
        let parser = Parser()
        try? parser.setLanguage(g.language)
        guard let tree = parser.parse(text) else { return [] }
        let ns = text as NSString
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
    public static func breadcrumbs(at offset: Int, text: String, language: CodeLanguage.Language) -> [String] {
        guard let g = grammars[language] else { return [] }
        let parser = Parser()
        try? parser.setLanguage(g.language)
        guard let tree = parser.parse(text), let root = tree.rootNode else { return [] }
        let ns = text as NSString
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
    /// - Note: Must be called on the main thread (the resolving query cursor is
    ///   main-actor-isolated). Only `.foregroundColor` is touched, never `.font`.
    public func highlight(_ storage: NSTextStorage, in editedRange: NSRange) {
        let full = NSRange(location: 0, length: storage.length)
        let ns = storage.string as NSString
        let range = ns.length == 0 ? full
            : ns.lineRange(for: NSRange(location: min(editedRange.location, ns.length), length: 0))
                .union(ns.lineRange(for: NSRange(location: min(NSMaxRange(editedRange), ns.length), length: 0)))

        guard let tree = parser.parse(storage.string) else { return }

        storage.addAttribute(.foregroundColor, value: HighlightTheme.colors.foreground,
                             range: NSIntersectionRange(range, full))

        // ResolvingQueryCursor is main-actor-isolated; highlight() only runs on main.
        MainActor.assumeIsolated {
            Self.applyQuery(grammar.highlights, tree: tree, source: ns, offset: 0, clip: range, into: storage)
            Self.applyInjections(grammar, tree: tree, source: ns, offset: 0, clip: range, into: storage, depth: 0)
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

    /// Runs a highlights query over `tree` (parsed from `source`), resolving
    /// predicates and applying colors offset into `storage` by `offset`, clipped
    /// to `clip`. Later query patterns win over generic catch-alls.
    /// Internal (not private) so tests can drive it with a hand-built query.
    @MainActor
    static func applyQuery(_ query: Query, tree: MutableTree, source ns: NSString,
                           offset: Int, clip: NSRange, into storage: NSTextStorage) {
        let cursor = query.execute(in: tree)
        let resolving = ResolvingQueryCursor(cursor: cursor)
        resolving.prepare(with: { r, _ in NSMaxRange(r) <= ns.length ? ns.substring(with: r) : nil })
        var hits: [(range: NSRange, pattern: Int, color: NSColor)] = []
        while let match = resolving.next() {
            for capture in match.captures {
                guard let name = capture.name, let color = color(for: name) else { continue }
                let r = capture.range
                guard r.length > 0, NSMaxRange(r) <= ns.length else { continue }
                hits.append((NSRange(location: offset + r.location, length: r.length), capture.patternIndex, color))
            }
        }
        apply(hits: hits, clip: clip, into: storage)
    }

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
    private static func injectionSites(_ injQuery: Query, tree: MutableTree, ns: NSString) -> [(name: String, ranges: [NSRange])] {
        var grouped: [String: [NSRange]] = [:]
        var order: [String] = []
        let cursor = injQuery.execute(in: tree)
        while let match = cursor.next() {
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

    /// Recursively highlights embedded languages (CSS in `<style>`, JS in
    /// `<script>`, HTML in PHP templates, …), depth-limited. All chunks of one
    /// injected language share a single combined parse (see `injectionSites`);
    /// capture ranges therefore stay absolute within `ns` and `offset` is unchanged.
    /// Internal (not private) so ``HighlightSession`` runs the same injection pass.
    @MainActor
    static func applyInjections(_ g: Grammar, tree: MutableTree, source ns: NSString,
                                offset: Int, clip: NSRange, into storage: NSTextStorage, depth: Int) {
        guard depth < 3, let injQuery = g.injections else { return }
        for site in injectionSites(injQuery, tree: tree, ns: ns) {
            guard let sub = grammarForInjection(site.name) else { continue }
            guard site.ranges.contains(where: {
                NSIntersectionRange(NSRange(location: offset + $0.location, length: $0.length), clip).length > 0
            }) else { continue }
            guard let subTree = combinedParse(sub, ns: ns, ranges: site.ranges) else { continue }
            applyQuery(sub.highlights, tree: subTree, source: ns, offset: offset, clip: clip, into: storage)
            applyInjections(sub, tree: subTree, source: ns, offset: offset, clip: clip, into: storage, depth: depth + 1)
        }
    }

    /// The semantic role for a tree-sitter capture (first dotted component), e.g.
    /// "function.method" → "function", "variable.parameter" → "variable".
    public static func role(for capture: String) -> String? {
        switch capture.split(separator: ".").first.map(String.init) ?? capture {
        case "keyword", "conditional", "repeat", "include", "exception",
             "storageclass", "label", "tag":            return "keyword"
        case "string", "character", "escape":           return "string"
        case "comment", "spell":                        return "comment"
        case "number", "float":                         return "number"
        case "boolean", "constant":                     return "constant"
        case "type", "constructor", "namespace", "module", "class": return "type"
        case "function", "method":                      return "function"
        case "variable", "parameter", "identifier":     return "variable"
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
