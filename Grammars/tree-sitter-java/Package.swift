// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "TreeSitterJava",
    products: [ .library(name: "TreeSitterJava", targets: ["TreeSitterJava"]) ],
    targets: [ .target(name: "TreeSitterJava", path: ".", exclude: ["src/grammar.json", "src/node-types.json"], sources: ["src/parser.c"], resources: [ .copy("queries") ], publicHeadersPath: "bindings/swift", cSettings: [ .headerSearchPath("src") ]) ]
)
