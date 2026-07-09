// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "TreeSitterCPP", products: [ .library(name: "TreeSitterCPP", targets: ["TreeSitterCPP"]) ], targets: [ .target(name: "TreeSitterCPP", path: ".", exclude: ["src/grammar.json", "src/node-types.json"], sources: ["src/parser.c", "src/scanner.c"], resources: [ .copy("queries") ], publicHeadersPath: "bindings/swift", cSettings: [ .headerSearchPath("src") ]) ])
