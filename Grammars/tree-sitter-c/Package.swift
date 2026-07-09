// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "TreeSitterC",
    products: [ .library(name: "TreeSitterC", targets: ["TreeSitterC"]) ],
    targets: [ .target(name: "TreeSitterC", path: ".", exclude: ["src/grammar.json", "src/node-types.json"], sources: ["src/parser.c"], resources: [ .copy("queries") ], publicHeadersPath: "bindings/swift", cSettings: [ .headerSearchPath("src") ]) ]
)
