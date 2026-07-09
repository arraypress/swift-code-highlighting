// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "TreeSitterTypeScript", products: [ .library(name: "TreeSitterTypeScript", targets: ["TreeSitterTypeScript"]) ], targets: [ .target(name: "TreeSitterTypeScript", path: ".", exclude: ["typescript/src/grammar.json", "typescript/src/node-types.json"], sources: ["typescript/src/parser.c", "typescript/src/scanner.c"], resources: [ .copy("queries") ], publicHeadersPath: "bindings/swift/typescript", cSettings: [ .headerSearchPath("typescript/src") ]) ])
