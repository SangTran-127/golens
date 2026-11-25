// Self-check for the refs and history parsers (top-level code, so compile it as main.swift):
//   T=$(mktemp -d) && cp scripts/git-history-check.swift $T/main.swift && swiftc desktop/Utilities/GitStatusParser.swift desktop/Utilities/GitHistoryParser.swift desktop/Utilities/GitGraphLayout.swift $T/main.swift -o $T/ghc && $T/ghc
// Builds a throwaway repository with branches, a remote, annotated and lightweight tags and odd commit subjects, then
// parses `for-each-ref`, `remote -v` and `log -z` the way GoLens runs them, and lays out the commit graph.
import Foundation

func expect(_ ok: Bool, _ what: String) {
    if !ok {
        print("FAIL:", what)
        exit(1)
    }
}

let base = FileManager.default.temporaryDirectory.appendingPathComponent("git-history-check-\(UUID().uuidString)").path
let repo = base + "/repo"
let remote = base + "/remote.git"
try! FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: base) }

@discardableResult
func git(_ args: [String], in dir: String = repo) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = URL(fileURLWithPath: dir)
    process.arguments = ["-c", "user.name=Ann Lee", "-c", "user.email=ann@example.com"] + args
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try! process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    expect(process.terminationStatus == 0, "git \(args.joined(separator: " ")) exited \(process.terminationStatus)")
    return String(decoding: data, as: UTF8.self)
}

git(["init", "-q", "-b", "main"])
git(["commit", "-q", "--allow-empty", "-m", "first\twith a tab"])
git(["commit", "-q", "--allow-empty", "-m", "second: «unicode» | pipes", "-m", "body line"])
git(["tag", "light"])
git(["tag", "-a", "v1.0", "-m", "release"])
git(["branch", "feature/x"])
git(["init", "-q", "--bare", remote], in: base)
git(["remote", "add", "origin", remote])
git(["push", "-q", "-u", "origin", "main", "feature/x"])

let refs = GitHistoryParser.refs(git(["for-each-ref", "--format=\(GitHistoryParser.refFormat)", "refs/heads", "refs/remotes", "refs/tags"]))
let byName = Dictionary(grouping: refs, by: \.kind)
expect(byName[.branch]?.map(\.name).sorted() == ["feature/x", "main"], "local branches: \(refs)")
expect(byName[.remoteBranch(remote: "origin")]?.map(\.name).sorted() == ["feature/x", "main"], "remote branches keep slashes and skip HEAD")
expect(byName[.tag]?.map(\.name).sorted() == ["light", "v1.0"], "annotated and lightweight tags")
expect(refs.first { $0.kind == .branch && $0.name == "main" }?.upstream == "origin/main", "upstream of main")
expect(refs.allSatisfy { !$0.shortHash.isEmpty && $0.date != nil }, "hash and date on every ref")

let remotes = GitHistoryParser.remotes(git(["remote", "-v"]))
expect(remotes == [GitRemoteInfo(name: "origin", url: remote)], "remote -v lists each remote once: \(remotes)")

let commits = GitHistoryParser.commits(git(["log", "-z", "--format=\(GitHistoryParser.logFormat)", "-n", "10", "main", "--"]))
expect(commits.count == 2, "two commits: \(commits)")
expect(commits[0].subject == "second: «unicode» | pipes" && commits[1].subject == "first\twith a tab", "subjects keep tabs and symbols")
expect(commits[0].author == "Ann Lee" && commits[0].email == "ann@example.com", "author and email")
expect(commits[0].refs.contains("tag: v1.0") && commits[0].refs.contains { $0.contains("main") }, "decorations: \(commits[0].refs)")
expect(commits[0].hash.count == 40 && commits[0].shortHash.count >= 7, "hashes")

expect(commits[0].parents == [commits[1].hash] && commits[1].parents.isEmpty, "parents: \(commits.map(\.parents))")

func commit(_ hash: String, _ parents: [String]) -> GitHistoryCommit {
    GitHistoryCommit(hash: hash, shortHash: hash, author: "", email: "", date: Date(), refs: [], subject: hash, parents: parents)
}
let merged = GitGraphLayout.rows(for: [
    commit("M", ["B2", "F2"]), commit("F2", ["F1"]), commit("B2", ["B1"]),
    commit("F1", ["B1"]), commit("B1", ["A"]), commit("A", []),
])
expect(merged.map(\.column) == [0, 1, 0, 1, 0, 0], "graph columns: \(merged.map(\.column))")
expect(merged.map(\.isMerge) == [true, false, false, false, false, false], "merge rows")
expect(merged.map(\.width) == [2, 2, 2, 2, 1, 1], "graph widths: \(merged.map(\.width))")
expect(merged[0].segments.contains(GitGraphSegment(fromColumn: 0, fromTop: false, toColumn: 1, toBottom: true, color: merged[1].color)), "merge edge opens a lane")
expect(merged[3].segments.contains { !$0.fromTop && $0.fromColumn == 1 && $0.toColumn == 0 }, "branch joins its base lane")
expect(merged[3].segments.contains { !$0.fromTop && $0.fromColumn == 0 && $0.toColumn == 0 }, "base lane continues past the join")
expect(merged[5].segments.allSatisfy { $0.fromTop }, "root commit ends every lane")
expect(merged[0].color != merged[1].color && merged[2].color == merged[0].color, "lanes keep their colors")

let tips = GitGraphLayout.rows(for: [commit("X", ["A"]), commit("Y", ["A"]), commit("A", [])])
expect(tips.map(\.column) == [0, 1, 0], "two tips on one parent: \(tips.map(\.column))")
expect(tips[1].segments.contains { !$0.fromTop && $0.fromColumn == 1 && $0.toColumn == 0 }, "the second tip joins the lane of the shared parent")

git(["checkout", "-q", "-b", "topic"])
git(["commit", "-q", "--allow-empty", "-m", "topic work"])
git(["checkout", "-q", "main"])
git(["commit", "-q", "--allow-empty", "-m", "main work"])
git(["merge", "-q", "--no-ff", "--no-edit", "topic"])
let real = GitHistoryParser.commits(git(["log", "-z", "--date-order", "--format=\(GitHistoryParser.logFormat)", "-n", "10", "main", "--"]))
let realRows = GitGraphLayout.rows(for: real)
expect(real.first?.parents.count == 2 && realRows.first?.isMerge == true, "real merge commit has two parents")
expect(realRows.map(\.width).max() == 2 && realRows.last?.column == 0, "real graph uses two lanes: \(realRows.map(\.column))")

print("git-history-check: all checks passed")
