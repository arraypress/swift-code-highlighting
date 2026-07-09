// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "TreeSitterRust",
    products: [ .library(name: "TreeSitterRust", targets: ["TreeSitterRust"]) ],
    targets: [ .target(name: "TreeSitterRust", path: ".", exclude: ["src/grammar.json", "src/node-types.json"], sources: ["src/parser.c", "src/scanner.c"], resources: [ .copy("queries") ], publicHeadersPath: "bindings/swift", cSettings: [ .headerSearchPath("src") ]) ]
)
