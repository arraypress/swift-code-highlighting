# Swift Code Highlighting

Syntax highlighting for macOS `NSTextStorage`, with two backends behind one `CodeHighlighter` protocol:

- **`TreeSitterHighlighter`** — tree-sitter parsing via ~20 vendored grammars (local SwiftPM C targets under `Grammars/`, with their `highlights.scm`/`injections.scm` queries shipped as `.bundle` resources). Handles language injections (CSS/JS in HTML, HTML in PHP, …), symbol extraction, hover signatures + doc comments, and breadcrumbs.
- **`SyntaxHighlighter`** — a dependency-light regex fallback with per-language rules and a family-based fallback, so **every** language [`CodeLanguage`](https://github.com/arraypress/swift-code-language) recognizes gets sensible coloring, even without a grammar.

## Features

- 🌳 **Tree-sitter highlighting** — `TreeSitterHighlighter` parses the whole buffer and applies grammar queries (later-pattern-wins precedence, `#eq?`/`#match?` predicates resolved), with recursive injection highlighting for embedded languages
- 🎨 **Regex highlighting** — `SyntaxHighlighter` colors an `NSTextStorage` in place, per line
- 🧩 **Tuned rules + family fallback** — dedicated rule sets for common languages (Swift, Python, JS/TS, Go, Rust, …) and family-level rules (c-like, ruby-like, lisp-like, ml-like, shell, markup, config, sql, tex, data) for everything else
- 🔎 **Symbol indexes** — `SymbolIndex`/`SymbolQueries` extract definitions per file; `ProjectSymbolIndex` builds a project-wide name → definition map (background build, incremental per-file updates) for cross-file Go-to-Definition and hover docs
- 🖌️ **Theme-agnostic** — you supply colors via `TokenColorProviding`; colors are read live, so a theme change just needs a re-highlight
- 🔌 **Pluggable** — `CodeHighlighter` is a protocol; both backends slot in behind the same interface

> Note: the grammar query files are SwiftPM resource bundles — the host app must ship the built `.bundle`s next to its executable (Sidewatch's `bundle.sh` does this) or `TreeSitterHighlighter` falls back gracefully to no grammars.

## Requirements

- macOS 13+
- Swift 5.9+

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/arraypress/swift-code-highlighting.git", from: "1.0.0")
]
```

## Usage

```swift
import CodeHighlighting
import CodeLanguage

struct MyColors: TokenColorProviding {
    func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .comment:  return .systemGreen
        case .string:   return .systemRed
        case .keyword:  return .systemPurple
        case .type:     return .systemTeal
        case .number:   return .systemOrange
        case .function: return .systemBlue
        case .attribute:return .systemTeal
        }
    }
    var foreground: NSColor { .textColor }
}

let highlighter = SyntaxHighlighter(language: .swift, colors: MyColors())
highlighter.highlight(textView.textStorage!, in: editedRange)
```

## License

MIT
