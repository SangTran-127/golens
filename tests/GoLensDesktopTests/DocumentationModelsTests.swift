import Foundation
import XCTest
import GoLensFoundation

final class DocumentationModelsTests: XCTestCase {
    func testDocLinkParserRoundTrip() {
        let url = DocsDocLinkParser.url(importPath: "example.com/single/shapes", symbol: "Box.Get")
        XCTAssertEqual(url?.absoluteString, "golens-doc:example.com/single/shapes#Box.Get")
        XCTAssertEqual(
            url.flatMap(DocsDocLinkParser.parse),
            .package(importPath: "example.com/single/shapes", symbol: "Box.Get")
        )

        let pkgOnly = URL(string: "golens-doc:net/http")!
        XCTAssertEqual(DocsDocLinkParser.parse(pkgOnly), .package(importPath: "net/http", symbol: nil))
        XCTAssertNil(DocsDocLinkParser.parse(URL(string: "https://pkg.go.dev/strings")!))
    }

    func testPublicPkgGoDevExcludesPrivateAndLocalModules() {
        XCTAssertNil(DocsDocLinkParser.publicPkgGoDevURL(importPath: "example.com/app/pkg", version: "v1.0.0", source: "workspace", origin: "project"))
        XCTAssertNil(DocsDocLinkParser.publicPkgGoDevURL(importPath: "corp.internal/lib", version: "v1.2.0", source: "module-cache", origin: "dependency"))
        XCTAssertNil(DocsDocLinkParser.publicPkgGoDevURL(importPath: "github.com/acme/dep", version: "v1.0.0", source: "local-replace", origin: "dependency"))

        let exact = DocsDocLinkParser.publicPkgGoDevURL(
            importPath: "go.mongodb.org/mongo-driver/v2/mongo",
            version: "v2.9.3",
            source: "module-cache",
            origin: "dependency",
            symbol: "Collection.FindOne"
        )
        XCTAssertEqual(exact?.url.absoluteString, "https://pkg.go.dev/go.mongodb.org/mongo-driver/v2/mongo@v2.9.3#Collection.FindOne")
        XCTAssertEqual(exact?.hasExactVersion, true)

        let pseudo = DocsDocLinkParser.publicPkgGoDevURL(
            importPath: "github.com/acme/tool",
            version: "v0.0.0-20261101120000-abcdef123456",
            source: "module-cache",
            origin: "dependency",
            symbol: "Run"
        )
        XCTAssertEqual(pseudo?.url.absoluteString, "https://pkg.go.dev/github.com/acme/tool#Run")
        XCTAssertEqual(pseudo?.hasExactVersion, false)
    }

    func testHistoryStackStoresScrollTargetAndCapsAtMaxEntries() {
        var stack = DocsHistoryStack()
        XCTAssertFalse(stack.canGoBack)
        XCTAssertFalse(stack.canGoForward)

        stack.push(.module(path: "go.mongodb.org/mongo-driver/v2"))
        stack.push(.package(importPath: "go.mongodb.org/mongo-driver/v2/mongo", symbol: nil))
        stack.updateCurrentScrollTarget("Collection.FindOne")
        stack.push(.package(importPath: "strings", symbol: "Cut"))

        XCTAssertTrue(stack.canGoBack)
        let back = stack.goBack()
        XCTAssertEqual(back?.route, .package(importPath: "go.mongodb.org/mongo-driver/v2/mongo", symbol: nil))
        XCTAssertEqual(back?.scrollTarget, "Collection.FindOne")
        XCTAssertTrue(stack.canGoForward)

        let fwd = stack.goForward()
        XCTAssertEqual(fwd?.route, .package(importPath: "strings", symbol: "Cut"))

        for i in 0..<(DocsHistoryStack.maxEntries + 25) {
            stack.push(.package(importPath: "pkg/\(i)", symbol: nil))
        }
        XCTAssertEqual(stack.entries.count, DocsHistoryStack.maxEntries)
        XCTAssertEqual(stack.currentEntry?.route, .package(importPath: "pkg/\(DocsHistoryStack.maxEntries + 24)", symbol: nil))
    }

    func testHoverResolverExtractsPkgGoDevAndSignatures() {
        let md = "```go\nfunc (coll *Collection) FindOne(ctx context.Context, filter any) *SingleResult\n```\n\n[mongo.Collection.FindOne on pkg.go.dev](https://pkg.go.dev/go.mongodb.org/mongo-driver/v2/mongo@v2.9.3#Collection.FindOne)"
        let resolved = DocsHoverResolver.resolve(
            rawMarkdown: md,
            signature: "func (coll *Collection) FindOne(ctx context.Context, filter any) *SingleResult"
        )
        XCTAssertEqual(resolved.importPath, "go.mongodb.org/mongo-driver/v2/mongo")
        XCTAssertEqual(resolved.symbolName, "Collection.FindOne")

        let local = DocsHoverResolver.resolve(
            rawMarkdown: "```go\nfunc NewBox[T any](v T) *Box[T]\n```",
            signature: "func NewBox[T any](v T) *Box[T]",
            activeFileDirPackage: "example.com/single/shapes"
        )
        XCTAssertEqual(local.importPath, "example.com/single/shapes")
        XCTAssertEqual(local.symbolName, "NewBox")
    }

    func testRequestGuardRejectsStaleRootTargetAndGeneration() {
        XCTAssertTrue(DocsRequestGuard.accepts(
            expectedRoot: "/ws/a",
            expectedTargetKey: "darwin|arm64|",
            expectedSerial: 4,
            activeRoot: "/ws/a",
            activeTargetKey: "darwin|arm64|",
            activeSerial: 4,
            responseRoot: "/ws/a",
            responseGeneration: 3,
            minimumGeneration: 3,
            cancelled: false
        ))
        XCTAssertFalse(DocsRequestGuard.accepts(
            expectedRoot: "/ws/a",
            expectedTargetKey: "darwin|arm64|",
            expectedSerial: 4,
            activeRoot: "/ws/b",
            activeTargetKey: "darwin|arm64|",
            activeSerial: 4,
            responseRoot: "/ws/a",
            responseGeneration: 3,
            minimumGeneration: 3,
            cancelled: false
        ))
        XCTAssertFalse(DocsRequestGuard.accepts(
            expectedRoot: "/ws/a",
            expectedTargetKey: "darwin|arm64|",
            expectedSerial: 4,
            activeRoot: "/ws/a",
            activeTargetKey: "linux|amd64|pro",
            activeSerial: 4,
            responseRoot: "/ws/a",
            responseGeneration: 3,
            minimumGeneration: 3,
            cancelled: false
        ))
        XCTAssertFalse(DocsRequestGuard.accepts(
            expectedRoot: "/ws/a",
            expectedTargetKey: "darwin|arm64|",
            expectedSerial: 4,
            activeRoot: "/ws/a",
            activeTargetKey: "darwin|arm64|",
            activeSerial: 4,
            responseRoot: "/ws/a",
            responseGeneration: 2,
            minimumGeneration: 3,
            cancelled: false
        ))
    }

    func testRequestGuardAcceptsPrivateVarEquivalentResponseRoot() throws {
        XCTAssertTrue(DocsRequestGuard.accepts(
            expectedRoot: "/var/folders/ab/ws",
            expectedTargetKey: "darwin|arm64|",
            expectedSerial: 1,
            activeRoot: "/var/folders/ab/ws",
            activeTargetKey: "darwin|arm64|",
            activeSerial: 1,
            responseRoot: "/private/var/folders/ab/ws",
            responseGeneration: 1,
            minimumGeneration: 0,
            cancelled: false
        ))
        XCTAssertFalse(DocsRequestGuard.accepts(
            expectedRoot: "/var/folders/ab/ws",
            expectedTargetKey: "darwin|arm64|",
            expectedSerial: 1,
            activeRoot: "/var/folders/ab/ws",
            activeTargetKey: "darwin|arm64|",
            activeSerial: 1,
            responseRoot: "/private/var/folders/ab/other",
            responseGeneration: 1,
            minimumGeneration: 0,
            cancelled: false
        ))
        let realTmp = FileManager.default.temporaryDirectory.appendingPathComponent("golens-docs-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: realTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: realTmp) }
        let stdPath = WorkspacePathCanonicalizer.canonical(realTmp.path)
        let privPath = stdPath.hasPrefix("/private/") ? stdPath : "/private" + stdPath
        XCTAssertTrue(DocsRequestGuard.accepts(
            expectedRoot: stdPath,
            expectedTargetKey: "darwin|arm64|",
            expectedSerial: 2,
            activeRoot: stdPath,
            activeTargetKey: "darwin|arm64|",
            activeSerial: 2,
            responseRoot: privPath,
            responseGeneration: 1,
            minimumGeneration: 0,
            cancelled: false
        ))
    }

    func testChannelGenerationsIsolateIndexPageAndSearchFloors() {
        var floors = DocsChannelGenerations()
        floors.record(11, for: .index)

        XCTAssertTrue(DocsRequestGuard.accepts(
            expectedRoot: "/ws/a",
            expectedTargetKey: "darwin|arm64|",
            expectedSerial: 1,
            activeRoot: "/ws/a",
            activeTargetKey: "darwin|arm64|",
            activeSerial: 1,
            responseRoot: "/ws/a",
            responseGeneration: 10,
            minimumGeneration: floors.floor(for: .page),
            cancelled: false
        ))
        floors.record(10, for: .page)
        XCTAssertFalse(DocsRequestGuard.accepts(
            expectedRoot: "/ws/a",
            expectedTargetKey: "darwin|arm64|",
            expectedSerial: 1,
            activeRoot: "/ws/a",
            activeTargetKey: "darwin|arm64|",
            activeSerial: 1,
            responseRoot: "/ws/a",
            responseGeneration: 9,
            minimumGeneration: floors.floor(for: .page),
            cancelled: false
        ))
        XCTAssertEqual(floors.floor(for: .search), 0)
    }

    func testSourceLocatorPrefersSymbolPositionThenDocGoThenSortedGoFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("golens-loc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let alpha = dir.appendingPathComponent("alpha.go").path
        let docGo = dir.appendingPathComponent("doc.go").path
        FileManager.default.createFile(atPath: alpha, contents: Data("package p\n".utf8))
        FileManager.default.createFile(atPath: docGo, contents: Data("// Package p.\npackage p\n".utf8))

        let decoder = JSONDecoder()
        let noSymbolsJSON = """
        {"root":\(jsonEscaped(dir.path)),"importPath":"example.com/p","name":"p","dir":\(jsonEscaped(dir.path)),"origin":"project","source":"workspace","doc":"Package p.","target":{"goos":"darwin","goarch":"arm64"}}
        """
        let noSymbolsPage = try decoder.decode(DocsPackageDocDTO.self, from: Data(noSymbolsJSON.utf8))
        XCTAssertEqual(DocsSourceLocator.resolve(for: noSymbolsPage, index: nil), DocsSourceLocation(file: docGo, line: 1, column: 1))

        let symbolJSON = """
        {"root":\(jsonEscaped(dir.path)),"importPath":"example.com/p","name":"p","dir":\(jsonEscaped(dir.path)),"origin":"project","source":"workspace","target":{"goos":"darwin","goarch":"arm64"},"funcs":[{"name":"Run","anchorName":"Run","kind":"func","signature":"func Run()","position":{"file":\(jsonEscaped(alpha)),"line":12,"column":6}}]}
        """
        let symbolPage = try decoder.decode(DocsPackageDocDTO.self, from: Data(symbolJSON.utf8))
        XCTAssertEqual(DocsSourceLocator.resolve(for: symbolPage, index: nil), DocsSourceLocation(file: alpha, line: 12, column: 6))

        let missingDir = dir.appendingPathComponent("missing").path
        let emptyDirJSON = """
        {"root":\(jsonEscaped(dir.path)),"importPath":"example.com/empty","name":"empty","dir":\(jsonEscaped(missingDir)),"origin":"project","source":"workspace","missingDoc":true,"target":{"goos":"darwin","goarch":"arm64"}}
        """
        let emptyDirPage = try decoder.decode(DocsPackageDocDTO.self, from: Data(emptyDirJSON.utf8))
        XCTAssertNil(DocsSourceLocator.resolve(for: emptyDirPage, index: nil))
    }

    private func jsonEscaped(_ s: String) -> String {
        let data = try! JSONEncoder().encode([s])
        let str = String(data: data, encoding: .utf8)!
        return String(str.dropFirst().dropLast())
    }

    func testErrorSanitizerRedactsCredentials() {
        let raw = "git fetch https://alice:glpat-secret123@git.example.com/org/repo.git failed; Authorization: Bearer tok999 token=abc"
        let clean = DocsErrorSanitizer.redact(raw)
        XCTAssertFalse(clean.contains("glpat-secret123"))
        XCTAssertFalse(clean.contains("tok999"))
        XCTAssertFalse(clean.contains("=abc"))
        XCTAssertTrue(clean.contains("https://***@git.example.com"))
    }
}
