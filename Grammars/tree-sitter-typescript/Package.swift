// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "TreeSitterTypeScript", products: [ .library(name: "TreeSitterTypeScript", targets: ["TreeSitterTypeScript", "TreeSitterTSX"]) ], targets: [ .target(name: "TreeSitterTypeScript", path: ".", exclude: ["typescript/src/grammar.json", "typescript/src/node-types.json"], sources: ["typescript/src/parser.c", "typescript/src/scanner.c"], resources: [ .copy("queries") ], publicHeadersPath: "bindings/swift/typescript", cSettings: [ .headerSearchPath("typescript/src") ]),
    // TSX is upstream's second grammar in the same repo (a TypeScript superset that parses JSX).
    // No `queries` resource here: it shares the TypeScript queries, loaded from the
    // TreeSitterTypeScript bundle — a second copy would just double-ship identical .scm files.
    .target(name: "TreeSitterTSX", path: ".", exclude: ["tsx/src/grammar.json", "tsx/src/node-types.json"], sources: ["tsx/src/parser.c", "tsx/src/scanner.c"], publicHeadersPath: "bindings/swift/tsx", cSettings: [ .headerSearchPath("tsx/src") ]) ])
