import Foundation
import SwiftUI

enum ConsoleLinks {
    static let scheme = "golens-source"
    private static let pattern = try! NSRegularExpression(pattern: #"((?:[A-Za-z]:)?[A-Za-z0-9_@.\-/~]*(?:[A-Za-z0-9_\-]\.(?:go|ya?ml|json|sql|proto|sh|md|toml|env)|Makefile|Dockerfile)):(\d+)(?::(\d+))?"#)

    struct Match: Equatable {
        let range: NSRange
        let path: String
        let line: Int
        let column: Int
    }

    static func matches(in text: String) -> [Match] {
        guard text.contains(":") else { return [] }
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).prefix(8).compactMap { m in
            guard let line = Int(ns.substring(with: m.range(at: 2))) else { return nil }
            let col = m.range(at: 3).location != NSNotFound ? Int(ns.substring(with: m.range(at: 3))) ?? 1 : 1
            return Match(range: m.range, path: ns.substring(with: m.range(at: 1)), line: line, column: col)
        }
    }

    static func attributed(_ text: String) -> AttributedString? {
        let found = matches(in: text)
        guard !found.isEmpty else { return nil }
        var out = AttributedString(text)
        for m in found {
            guard let r = Range(m.range, in: text), let ar = Range(r, in: out) else { continue }
            var comps = URLComponents()
            comps.scheme = scheme
            comps.host = "open"
            comps.queryItems = [URLQueryItem(name: "path", value: m.path), URLQueryItem(name: "line", value: String(m.line)), URLQueryItem(name: "col", value: String(m.column))]
            out[ar].link = comps.url
            out[ar].underlineStyle = .single
        }
        return out
    }

    static func resolve(_ path: String, workspace: String, runDirectory: String?, files: [String]) -> String? {
        let fm = FileManager.default
        if path.hasPrefix("/") { return fm.fileExists(atPath: path) ? path : nil }
        for base in [runDirectory, workspace].compactMap({ $0 }) where !base.isEmpty {
            let candidate = (base as NSString).appendingPathComponent(path)
            if fm.fileExists(atPath: candidate) { return (candidate as NSString).standardizingPath }
        }
        let suffix = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
        let hits = files.filter { $0.hasSuffix(suffix) }
        return hits.count == 1 ? hits[0] : hits.min { $0.count < $1.count }
    }

    static func open(_ url: URL, in workspace: WorkspaceState) -> Bool {
        guard url.scheme == scheme, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "path" })?.value,
              let line = items.first(where: { $0.name == "line" })?.value.flatMap(Int.init) else { return false }
        let col = items.first(where: { $0.name == "col" })?.value.flatMap(Int.init) ?? 1
        return openLocation(path: path, line: line, column: col, in: workspace, preferredDirectory: nil)
    }

    @discardableResult
    static func openLocation(
        path: String,
        line: Int,
        column: Int = 1,
        in workspace: WorkspaceState,
        preferredDirectory: String? = nil
    ) -> Bool {
        var runDir: String? = preferredDirectory
        if runDir == nil || runDir?.isEmpty == true {
            if let selectedId = workspace.selectedRunSessionId,
               let session = workspace.runSessions.first(where: { $0.id == selectedId }),
               !session.dir.isEmpty {
                runDir = session.dir
            } else if let lastDir = workspace.runSessions.last?.dir, !lastDir.isEmpty {
                runDir = lastDir
            } else if let wd = workspace.activeRunConfiguration?.workingDirectory, !wd.isEmpty {
                runDir = wd.hasPrefix("/") ? wd : (workspace.activeWorkspacePath as NSString).appendingPathComponent(wd)
            }
        }
        let allFiles = workspace.allWorkspaceRelativeFilePaths().map {
            (workspace.activeWorkspacePath as NSString).appendingPathComponent($0)
        }
        guard let resolved = resolve(path, workspace: workspace.activeWorkspacePath, runDirectory: runDir, files: allFiles) else {
            workspace.appendLog("Cannot find \(path) in the project.")
            workspace.presentCommandFeedback(
                "Couldn’t find \((path as NSString).lastPathComponent) in this project.",
                title: "File Not Found",
                tone: .warning
            )
            return false
        }
        workspace.jumpTo(filePath: resolved, line: line, column: column)
        return true
    }
}
