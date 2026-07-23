// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TreeSitterMarkdown",
    products: [ .library(name: "TreeSitterMarkdown", targets: ["TreeSitterMarkdown", "TreeSitterMarkdownInline"]) ],
    targets: [
        // Upstream is a DUAL parser: this target is the BLOCK-structure grammar
        // (headings, fences, lists, quotes); its injections.scm tags every
        // `(inline)` node "markdown_inline" for the inline grammar below.
        .target(
            name: "TreeSitterMarkdown",
            path: "tree-sitter-markdown",
            exclude: ["src/grammar.json", "src/node-types.json"],
            sources: ["src/parser.c", "src/scanner.c"],
            resources: [ .copy("queries") ],
            publicHeadersPath: "bindings/swift",
            cSettings: [ .headerSearchPath("src") ]
        ),
        // The INLINE grammar (emphasis, code spans, links) only ever runs over
        // the injection ranges the block grammar reports — it is not routed as
        // a language of its own. It has its OWN queries bundle: unlike TSX
        // (which shares the TypeScript queries) the inline highlights are a
        // different file from the block ones.
        .target(
            name: "TreeSitterMarkdownInline",
            path: "tree-sitter-markdown-inline",
            exclude: ["src/grammar.json", "src/node-types.json"],
            sources: ["src/parser.c", "src/scanner.c"],
            resources: [ .copy("queries") ],
            publicHeadersPath: "bindings/swift",
            cSettings: [ .headerSearchPath("src") ]
        ),
    ]
)
