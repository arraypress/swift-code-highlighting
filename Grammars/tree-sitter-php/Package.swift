// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "TreeSitterPHP", products: [ .library(name: "TreeSitterPHP", targets: ["TreeSitterPHP"]) ], targets: [ .target(name: "TreeSitterPHP", path: ".", exclude: ["php/src/grammar.json", "php/src/node-types.json"], sources: ["php/src/parser.c", "php/src/scanner.c"], resources: [ .copy("queries") ], publicHeadersPath: "bindings/swift", cSettings: [ .headerSearchPath("php/src") ]) ])
