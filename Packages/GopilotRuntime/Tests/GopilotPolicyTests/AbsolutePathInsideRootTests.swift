import Foundation
import Testing
@testable import GopilotPolicy

@Suite("Absolute paths inside the project root")
struct AbsolutePathInsideRootTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gopilot-abs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pkg"), withIntermediateDirectories: true)
        try "package pkg\n".write(to: root.appendingPathComponent("pkg/a.go"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func absolutePathInsideRootIsTreatedAsRelative() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = PathPolicy(workspaceRoots: [root])
        let inside = root.resolvingSymlinksInPath().appendingPathComponent("pkg/a.go").path
        let decision = policy.evaluate(relativePath: inside)
        #expect(decision.resolved?.relativePath == "pkg/a.go")
    }

    @Test func absolutePathOutsideRootStaysDenied() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = PathPolicy(workspaceRoots: [root])
        #expect(policy.evaluate(relativePath: "/etc/passwd").denial == .absolutePath)
    }

    @Test func traversalThroughTheRootStaysDenied() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = PathPolicy(workspaceRoots: [root])
        let escape = root.resolvingSymlinksInPath().path + "/../outside.txt"
        #expect(policy.evaluate(relativePath: escape).denial != nil)
    }

    @Test func rootItselfIsAllowedWhereRootsAreAllowed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = PathPolicy(workspaceRoots: [root])
        #expect(policy.evaluate(relativePath: root.resolvingSymlinksInPath().path, allowsRoot: true).resolved != nil)
    }
}
