# Swift Code Highlighting

Syntax highlighting for macOS `NSTextStorage`, with two backends behind one `CodeHighlighter` protocol: a tree-sitter engine driving 22 grammars — 21 vendored as local SwiftPM C targets under `Grammars/` (Bash, C, C++, C#, CSS, Dart, Dockerfile, Go, HTML, Java, JavaScript, Kotlin, Lua, PHP, Python, Ruby, Rust, Swift, TOML, TypeScript, YAML) plus JSON from the upstream package, queries shipped as `.bundle` resources — and a dependency-light regex fallback so **every** language [`CodeLanguage`](https://github.com/arraypress/swift-code-language) recognizes gets sensible coloring. Beyond coloring, the tree-sitter side powers symbol outlines, a project-wide definition index, hover docs, breadcrumbs, and structural selection. Depends on [SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter) and `CodeLanguage`; AppKit-only (`NSColor`/`NSTextStorage`).

## Features

- 🌳 **Tree-sitter highlighting** — `TreeSitterHighlighter` parses the whole buffer and applies each grammar's `highlights.scm` (later-pattern-wins precedence, `#eq?`/`#match?` predicates resolved), with recursive injection highlighting for embedded languages (CSS/JS in HTML, HTML in PHP, …)
- ⚡ **Incremental sessions** — `HighlightSession` keeps the parsed tree alive between highlight passes: the document parses **once**, viewport re-highlights while scrolling run the query against the cached tree (no re-parse), and `noteEdit(range:replacementLength:newText:)` re-parses **incrementally** via tree-sitter's `tree.edit`; `invalidate()` forces one fresh parse after a reload (injected sub-languages still re-parse per pass)
- 🎨 **Regex fallback** — `SyntaxHighlighter` colors an `NSTextStorage` in place with per-language rule tables plus family-level rules (c-like, ruby-like, lisp-like, ml-like, shell, markup, config, sql, tex, data) for everything else; strings and comments are resolved in one left-to-right scan so neither can repaint the other
- 🔎 **Symbol extraction** — `TreeSitterHighlighter.symbols(in:language:)` returns every definition (`Symbol`: name, `SymbolKind`, range, line) via the hand-written `SymbolQueries`, for outlines and Go-to-Symbol
- 🗂️ **Project-wide index** — `ProjectSymbolIndex` builds a name → `DefLocation` map over a whole tree on a background queue (skips `.git`/`node_modules`/…, 500 KB and 5000-file caps), with incremental `updateFile(_:)` and superseding rebuilds, for cross-file Go-to-Definition
- 💬 **Hover docs + breadcrumbs** — `hoverInfo(for:in:language:)` returns a highlighted signature plus the doc comment above it (markers derived from the language's own comment tokens); `breadcrumbs(at:text:language:)` returns the enclosing definition path
- 🧭 **Structural selection** — `enclosingNodeRange(selection:text:language:)` (Expand Selection) and `siblingRange(of:text:language:forward:)` walk the syntax tree
- 🖌️ **Theme-agnostic** — you supply colors via `TokenColorProviding`; the process-wide `HighlightTheme.colors` feeds the tree-sitter engine, and colors are read live so a theme change just needs a re-highlight
- 🎯 **Color-chip helpers** — `colorRegex` finds `#RGB`/`#RRGGBB`/`#RRGGBBAA` literals and `colorFromHex(_:)` parses them, for editors that draw inline swatches
- 🔬 **Headless validation** — `dumpCaptures(path:)` prints every token → capture → role for a file, so highlighting can be verified without a GUI
- 🧪 **Tested** — unit tests cover the regex backend, capture-role mapping, hit precedence/clipping, doc-comment extraction, symbol queries (compiled against the real grammars), and the index's path canonicalization

## Requirements

- macOS 13+
- Swift 5.9+

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/arraypress/swift-code-highlighting.git", from: "1.0.0")
]
```

> **Bundles note:** the grammar query files are SwiftPM resource bundles — the host app must ship the built `.bundle`s next to its executable (Sidewatch's `bundle.sh` does this) or `TreeSitterHighlighter` loads no grammars and `supports(_:)` is false for everything; fall back to `SyntaxHighlighter`.

## Usage

```swift
import CodeHighlighting
import CodeLanguage

// Your theme: a color per token role.
struct MyColors: TokenColorProviding {
    func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .comment:   return .systemGreen
        case .string:    return .systemRed
        case .keyword:   return .systemPurple
        case .type:      return .systemTeal
        case .number:    return .systemOrange
        case .function:  return .systemBlue
        case .attribute: return .systemTeal
        case .variable:  return .labelColor
        case .property:  return .systemIndigo
        }
    }
    var foreground: NSColor { .textColor }
}

// The tree-sitter engine reads the process-wide provider; set it once at launch.
HighlightTheme.colors = MyColors()

// Prefer tree-sitter when a grammar is bundled; fall back to regex.
let language = CodeLanguage.Language.detect(for: fileURL)
let highlighter: CodeHighlighter = TreeSitterHighlighter(language: language)
    ?? SyntaxHighlighter(language: language, colors: MyColors())
highlighter.highlight(textView.textStorage!, in: editedRange)   // main thread
```

### Incremental highlighting for large files

`TreeSitterHighlighter.highlight` re-parses the whole buffer every call. For big documents that are re-highlighted per viewport while scrolling, hold a `HighlightSession` per open file instead — it parses once and then only runs the query:

```swift
// One session per (document, language); nil when no grammar is bundled.
let session = HighlightSession(language: language)

// First call parses the document once; every later call reuses the tree.
session?.highlight(in: storage, text: storage.string, clip: viewportRange)   // main thread

// After each storage mutation, describe the edit (old-text coordinates) and
// hand over the full new text — tree-sitter re-parses only what changed.
session?.noteEdit(range: replacedRange, replacementLength: insertedLength, newText: storage.string)

// On reload / external change / language switch: drop the tree.
session?.invalidate()
```

### Symbols, hover docs, breadcrumbs

```swift
// Every definition in a file (for an outline / Go-to-Symbol).
let symbols = TreeSitterHighlighter.symbols(in: text, language: .python)
for s in symbols { print(s.kind.label, s.name, "line", s.line) }

// Signature + doc comment for a hovered word.
if let hover = TreeSitterHighlighter.hoverInfo(for: word, in: text, language: .go) {
    print(hover.kind, hover.signature.string, hover.doc)
}

// Enclosing definition names at a cursor offset, outermost → innermost.
let path = TreeSitterHighlighter.breadcrumbs(at: offset, text: text, language: .typescript)
// e.g. ["UserRepository", "findById"]
```

### Project-wide Go-to-Definition

```swift
let index = ProjectSymbolIndex()
index.build(root: projectURL) {          // background build; completion on main
    let defs = index.definitions(of: "parseConfig")   // [DefLocation]
}
index.updateFile(changedURL)              // incremental: re-index or drop one file
index.invalidate()                        // e.g. on project switch
```

### Structural selection

```swift
// Expand Selection: smallest node strictly larger than the current selection.
let bigger = TreeSitterHighlighter.enclosingNodeRange(selection: sel, text: text, language: .rust)

// Jump to the next named sibling.
let next = TreeSitterHighlighter.siblingRange(of: sel, text: text, language: .rust, forward: true)
```

## License

MIT
