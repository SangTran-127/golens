import Foundation

public struct DocsSourceLocation: Equatable, Sendable {
    public let file: String
    public let line: Int
    public let column: Int

    public init(file: String, line: Int = 1, column: Int = 1) {
        self.file = file
        self.line = line
        self.column = column
    }
}

public enum DocsSourceLocator {
    public static func resolve(for page: DocsPackageDocDTO?, index: DocsIndexDTO?) -> DocsSourceLocation? {
        guard let page else { return nil }
        let positions: [DocsPositionDTO] = (page.types ?? []).map(\.position)
            + (page.funcs ?? []).map(\.position)
            + (page.consts ?? []).map(\.position)
            + (page.vars ?? []).map(\.position)
            + (page.examples ?? []).map(\.position)
            + (page.excluded ?? []).map(\.position)
        if let first = positions.first(where: { isRegularGoFile($0.file) }) {
            return DocsSourceLocation(file: first.file, line: max(1, first.line), column: max(1, first.column))
        }
        guard let dir = page.dir, !dir.isEmpty else { return nil }
        if let pkg = (index?.packages ?? []).first(where: { $0.importPath == page.importPath }),
           let candidate = firstGoFileName(in: pkg.goFiles ?? []) {
            let path = (dir as NSString).appendingPathComponent(candidate)
            if isRegularGoFile(path) {
                return DocsSourceLocation(file: path, line: 1, column: 1)
            }
        }
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir),
           let candidate = firstGoFileName(in: names) {
            let path = (dir as NSString).appendingPathComponent(candidate)
            if isRegularGoFile(path) {
                return DocsSourceLocation(file: path, line: 1, column: 1)
            }
        }
        return nil
    }

    public static func firstGoFileName(in names: [String]) -> String? {
        let nonTest = names.filter { $0.hasSuffix(".go") && !$0.hasSuffix("_test.go") }.sorted()
        if nonTest.contains("doc.go") { return "doc.go" }
        if let first = nonTest.first { return first }
        return names.filter { $0.hasSuffix(".go") }.sorted().first
    }

    public static func isRegularGoFile(_ path: String) -> Bool {
        guard !path.isEmpty, path.hasSuffix(".go") else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }
}
