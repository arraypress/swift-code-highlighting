// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "TreeSitterSQL", products: [ .library(name: "TreeSitterSQL", targets: ["TreeSitterSQL"]) ], targets: [ .target(name: "TreeSitterSQL", path: ".", exclude: ["src/grammar.json", "src/node-types.json", "LICENSE"], sources: ["src/parser.c", "src/scanner.c"], resources: [ .copy("queries") ], publicHeadersPath: "bindings/swift", cSettings: [ .headerSearchPath("src") ]) ])
