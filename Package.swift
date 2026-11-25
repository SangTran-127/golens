// swift-tools-version: 5.9
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #file).deletingLastPathComponent().path

let package = Package(
    name: "GoLens",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", revision: "9655a1c4869e9bf0265654ab8d4915a1bc313f87"),
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter.git", from: "0.9.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go.git", revision: "1547678a9da59885853f5f5cc8a99cc203fa2e2c"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
        .package(path: "Packages/GopilotRuntime")
    ],
    targets: [
        .target(
            name: "GoLensFoundation",
            path: "Sources/GoLensFoundation"
        ),
        .executableTarget(
            name: "GoLensApp",
            dependencies: [
                "GoLensFoundation",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "GopilotRuntime", package: "GopilotRuntime"),
                .product(name: "GopilotProvider", package: "GopilotRuntime"),
                .product(name: "GopilotPolicy", package: "GopilotRuntime"),
                .product(name: "GopilotStore", package: "GopilotRuntime"),
                .product(name: "GopilotAnalysis", package: "GopilotRuntime"),
                .product(name: "GopilotTools", package: "GopilotRuntime"),
                .product(name: "GopilotCompletion", package: "GopilotRuntime"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "desktop",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .unsafeFlags(["-import-objc-header", "\(packageDir)/desktop/App/GoLens-Bridging-Header.h"])
            ],
            linkerSettings: [
                .unsafeFlags(["-L", "\(packageDir)/core", "-Xlinker", "-rpath", "-Xlinker", "\(packageDir)/core", "-lgoagent"]),
                .linkedFramework("Virtualization")
            ]
        ),
        .testTarget(
            name: "GoLensDesktopTests",
            dependencies: ["GoLensFoundation"],
            path: "tests/GoLensDesktopTests"
        )
    ]
)
