// swift-tools-version:5.9
import PackageDescription
// Upstream (tree-sitter-grammars/tree-sitter-xml) ships TWO grammars, xml + dtd;
// only the xml one is vendored here (src/scanner.h is upstream's common/scanner.h).
let package = Package(name: "TreeSitterXML", products: [ .library(name: "TreeSitterXML", targets: ["TreeSitterXML"]) ], targets: [ .target(name: "TreeSitterXML", path: ".", exclude: ["src/grammar.json", "src/node-types.json", "LICENSE"], sources: ["src/parser.c", "src/scanner.c"], resources: [ .copy("queries") ], publicHeadersPath: "bindings/swift", cSettings: [ .headerSearchPath("src") ]) ])
