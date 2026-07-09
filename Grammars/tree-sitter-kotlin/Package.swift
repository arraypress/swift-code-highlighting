// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "TreeSitterKotlin", products: [ .library(name: "TreeSitterKotlin", targets: ["TreeSitterKotlin"]) ], targets: [ .target(name: "TreeSitterKotlin", path: ".", exclude: ["src/grammar.json", "src/node-types.json"], sources: ["src/parser.c", "src/scanner.c"], resources: [ .copy("queries") ], publicHeadersPath: "bindings/swift", cSettings: [ .headerSearchPath("src") ]) ])
