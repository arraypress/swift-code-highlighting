// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "TreeSitterPython",
    products: [ .library(name: "TreeSitterPython", targets: ["TreeSitterPython"]) ],
    targets: [ .target(name: "TreeSitterPython", path: ".", exclude: ["src/grammar.json", "src/node-types.json"], sources: ["src/parser.c", "src/scanner.c"], resources: [ .copy("queries") ], publicHeadersPath: "bindings/swift", cSettings: [ .headerSearchPath("src") ]) ]
)
