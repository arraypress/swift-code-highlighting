// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "TreeSitterGo",
    products: [ .library(name: "TreeSitterGo", targets: ["TreeSitterGo"]) ],
    targets: [ .target(name: "TreeSitterGo", path: ".", exclude: ["src/grammar.json", "src/node-types.json"], sources: ["src/parser.c"], resources: [ .copy("queries") ], publicHeadersPath: "bindings/swift", cSettings: [ .headerSearchPath("src") ]) ]
)
