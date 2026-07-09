# Swift Code Highlighting

A dependency-light regex syntax highlighter for macOS `NSTextStorage` — per-language rules with a family-based fallback, so **every** language [`CodeLanguage`](https://github.com/arraypress/swift-code-language) recognizes gets sensible coloring. No tree-sitter, no C grammars.

## Features

- 🎨 **Regex highlighting** — `SyntaxHighlighter` colors an `NSTextStorage` in place, per line
- 🧩 **Tuned rules + family fallback** — dedicated rule sets for common languages (Swift, Python, JS/TS, Go, Rust, …) and family-level rules (c-like, ruby-like, lisp-like, ml-like, shell, markup, config, sql, tex, data) for everything else
- 🖌️ **Theme-agnostic** — you supply colors via `TokenColorProviding`; colors are read live, so a theme change just needs a re-highlight
- 🔌 **Pluggable** — `CodeHighlighter` is a protocol, so a tree-sitter backend can slot in behind the same interface
- 🪶 **Light deps** — Foundation/AppKit + `CodeLanguage`; no C, no grammars

## Requirements

- macOS 10.15+
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
