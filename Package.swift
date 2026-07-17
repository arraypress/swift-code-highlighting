// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodeHighlighting",
    platforms: [
        // Uses AppKit (NSColor / NSTextStorage), so macOS-only.
        .macOS(.v13)
    ],
    products: [
        .library(name: "CodeHighlighting", targets: ["CodeHighlighting"]),
    ],
    dependencies: [
        .package(path: "../swift-code-language"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter.git", from: "0.8.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json.git", from: "0.20.0"),
        .package(path: "Grammars/tree-sitter-css"),
        .package(path: "Grammars/tree-sitter-javascript"),
        .package(path: "Grammars/tree-sitter-python"),
        .package(path: "Grammars/tree-sitter-rust"),
        .package(path: "Grammars/tree-sitter-go"),
        .package(path: "Grammars/tree-sitter-html"),
        .package(path: "Grammars/tree-sitter-bash"),
        .package(path: "Grammars/tree-sitter-c"),
        .package(path: "Grammars/tree-sitter-java"),
        .package(path: "Grammars/tree-sitter-ruby"),
        .package(path: "Grammars/tree-sitter-typescript"),
        .package(path: "Grammars/tree-sitter-cpp"),
        .package(path: "Grammars/tree-sitter-csharp"),
        .package(path: "Grammars/tree-sitter-php"),
        .package(path: "Grammars/tree-sitter-yaml"),
        .package(path: "Grammars/tree-sitter-toml"),
        .package(path: "Grammars/tree-sitter-lua"),
        .package(path: "Grammars/tree-sitter-kotlin"),
        .package(path: "Grammars/tree-sitter-dart"),
        .package(path: "Grammars/tree-sitter-dockerfile"),
        .package(path: "Grammars/tree-sitter-swift"),
        .package(path: "Grammars/tree-sitter-scala"),
        .package(path: "Grammars/tree-sitter-xml"),
        .package(path: "Grammars/tree-sitter-sql"),
    ],
    targets: [
        .target(
            name: "CodeHighlighting",
            dependencies: [
                .product(name: "CodeLanguage", package: "swift-code-language"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
                .product(name: "TreeSitterJava", package: "tree-sitter-java"),
                .product(name: "TreeSitterRuby", package: "tree-sitter-ruby"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
                .product(name: "TreeSitterCSharp", package: "tree-sitter-csharp"),
                .product(name: "TreeSitterPHP", package: "tree-sitter-php"),
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
                .product(name: "TreeSitterTOML", package: "tree-sitter-toml"),
                .product(name: "TreeSitterLua", package: "tree-sitter-lua"),
                .product(name: "TreeSitterKotlin", package: "tree-sitter-kotlin"),
                .product(name: "TreeSitterDart", package: "tree-sitter-dart"),
                .product(name: "TreeSitterDockerfile", package: "tree-sitter-dockerfile"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterScala", package: "tree-sitter-scala"),
                .product(name: "TreeSitterXML", package: "tree-sitter-xml"),
                .product(name: "TreeSitterSQL", package: "tree-sitter-sql"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "CodeHighlightingTests",
            dependencies: [
                "CodeHighlighting",
                // Tests compile hand-written queries (Query/Parser) to exercise
                // the tree-sitter path without the app's resource bundles.
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
            ],
            path: "Tests",
            resources: [
                // Reference custom-language definition (JSFX) used by the
                // CustomLanguageDefinition decode/highlight tests.
                .copy("CodeHighlightingTests/Resources/jsfx.json"),
            ]
        ),
    ]
)
