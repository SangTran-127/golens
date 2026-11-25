// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TreeSitterGrammars",
    products: [
        .library(name: "TreeSitterGrammars", targets: ["TreeSitterGrammars"])
    ],
    targets: [
        .target(
            name: "TreeSitterGrammars",
            path: "Sources/TreeSitterGrammars",
            publicHeadersPath: "include"
        )
    ]
)
