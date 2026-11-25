// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GopilotRuntime",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "GopilotRuntime", targets: ["GopilotRuntime"]),
        .library(name: "GopilotProvider", targets: ["GopilotProvider"]),
        .library(name: "GopilotPolicy", targets: ["GopilotPolicy"]),
        .library(name: "GopilotStore", targets: ["GopilotStore"]),
        .library(name: "GopilotAnalysis", targets: ["GopilotAnalysis"]),
        .library(name: "GopilotTools", targets: ["GopilotTools"]),
        .library(name: "GopilotCompletion", targets: ["GopilotCompletion"])
    ],
    targets: [
        .target(name: "GopilotRuntime"),
        .testTarget(name: "GopilotRuntimeTests", dependencies: ["GopilotRuntime"]),
        .target(name: "GopilotProvider", dependencies: ["GopilotRuntime"]),
        .testTarget(name: "GopilotProviderTests", dependencies: ["GopilotProvider"]),
        .target(name: "GopilotPolicy", dependencies: ["GopilotRuntime"]),
        .testTarget(name: "GopilotPolicyTests", dependencies: ["GopilotPolicy"]),
        .target(name: "GopilotStore", dependencies: ["GopilotRuntime"]),
        .testTarget(name: "GopilotStoreTests", dependencies: ["GopilotStore"]),
        .target(name: "GopilotAnalysis", dependencies: ["GopilotRuntime"]),
        .testTarget(name: "GopilotAnalysisTests", dependencies: ["GopilotAnalysis"]),
        .target(name: "GopilotTools", dependencies: ["GopilotRuntime", "GopilotPolicy", "GopilotStore", "GopilotAnalysis"]),
        .testTarget(name: "GopilotToolsTests", dependencies: ["GopilotTools", "GopilotPolicy", "GopilotStore", "GopilotAnalysis", "GopilotRuntime"]),
        .target(name: "GopilotCompletion", dependencies: ["GopilotRuntime", "GopilotProvider", "GopilotPolicy"]),
        .testTarget(name: "GopilotCompletionTests", dependencies: ["GopilotCompletion", "GopilotProvider", "GopilotPolicy"])
    ]
)
