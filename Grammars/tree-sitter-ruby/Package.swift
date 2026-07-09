// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "TreeSitterRuby",
    products: [ .library(name: "TreeSitterRuby", targets: ["TreeSitterRuby"]) ],
    targets: [ .target(name: "TreeSitterRuby", path: ".", exclude: ["src/grammar.json", "src/node-types.json"], sources: ["src/parser.c", "src/scanner.c"], resources: [ .copy("queries") ], publicHeadersPath: "bindings/swift", cSettings: [ .headerSearchPath("src") ]) ]
)
