// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "TreeSitterSwift", products: [ .library(name: "TreeSitterSwift", targets: ["TreeSitterSwift"]) ], targets: [ .target(name: "TreeSitterSwift", path: ".", exclude: ["src/grammar.json", "src/node-types.json", "LICENSE"], sources: ["src/parser.c", "src/scanner.c"], resources: [ .copy("queries") ], publicHeadersPath: "bindings/swift", cSettings: [ .headerSearchPath("src") ]) ])
