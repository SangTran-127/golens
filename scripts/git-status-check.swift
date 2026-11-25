// Self-check for the git status parser (top-level code, so compile it as main.swift):
//   T=$(mktemp -d) && cp scripts/git-status-check.swift $T/main.swift && swiftc desktop/Utilities/GitStatusParser.swift $T/main.swift -o $T/gsc && $T/gsc
// Builds a throwaway repository with awkward names, renames, partly staged, unmerged and untracked files, then parses
// `git status --porcelain=v2 --branch -z`, `diff --numstat -z` and `show --name-status -z` the way GoLens runs them.
import Foundation

func expect(_ ok: Bool, _ what: String) {
    if !ok {
        print("FAIL:", what)
        exit(1)
    }
}

let base = FileManager.default.temporaryDirectory.appendingPathComponent("git-status-check-\(UUID().uuidString)").path
let remote = base + "/remote.git"
let repo = base + "/repo"
try! FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: base) }

@discardableResult
func git(_ args: [String], in dir: String = repo, ok: Set<Int32> = [0]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = URL(fileURLWithPath: dir)
    process.arguments = args
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try! process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    expect(ok.contains(process.terminationStatus), "git \(args.joined(separator: " ")) exited \(process.terminationStatus)")
    return String(decoding: data, as: UTF8.self)
}

func write(_ rel: String, _ text: String) {
    let path = repo + "/" + rel
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! text.write(toFile: path, atomically: true, encoding: .utf8)
}

func status(in dir: String = repo) -> GitStatusSnapshot {
    GitStatusParser.parse(git(["--no-optional-locks", "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all", "--", "."], in: dir))
}

git(["init", "-q", "-b", "main"])
git(["config", "user.email", "check@example.com"])
git(["config", "user.name", "Check"])

var s = status()
expect(!s.hasCommits && s.head == "main" && s.entries.isEmpty, "empty repository: \(s)")

write("app/old.go", "package app\n")
write("app/p.go", "package app\n")
write("app/conflict.go", "base\n")
git(["add", "."])
git(["commit", "-qm", "init"])

git(["mv", "app/old.go", "app/new name.go"])
write("app/p.go", "package app\n\nvar a = 1\n")
git(["add", "app/p.go"])
write("app/p.go", "package app\n\nvar a = 1\nvar b = 2\n")
write("app/é x.go", "package app\n")
write("app/tab\there.go", "package app\n")
write("app/quote\"d.go", "package app\n")
write("other/outside.go", "package other\n")

s = status()
expect(s.hasCommits && s.head == "main" && s.upstream == nil, "branch header: \(s)")
let byPath = Dictionary(uniqueKeysWithValues: s.entries.map { ($0.path, $0) })
expect(byPath["app/new name.go"]?.x == "R" && byPath["app/new name.go"]?.originalPath == "app/old.go", "rename keeps both names")
expect(byPath["app/p.go"]?.x == "M" && byPath["app/p.go"]?.y == "M", "partly staged is MM")
for name in ["app/é x.go", "app/tab\there.go", "app/quote\"d.go", "other/outside.go"] {
    expect(byPath[name]?.isUntracked == true, "untracked, unquoted: \(name)")
}

let rows = GitStatusParser.rows(from: s, workspacePrefix: "app/")
expect(rows.filter { $0.repoPath == "app/p.go" }.map { "\($0.status)\($0.isStaged)" } == ["Mtrue", "Mfalse"], "partly staged gives a staged and an unstaged row")
expect(rows.first { $0.repoPath == "app/new name.go" }.map { $0.status == "R" && $0.isStaged && $0.relativePath == "new name.go" } == true, "rename row, workspace prefix stripped")
expect(rows.first { $0.repoPath == "app/new name.go" }?.originalPath == "old.go", "rename row carries the old path, workspace prefix stripped")
expect(rows.first { $0.repoPath == "app/new name.go" }?.originalRepoPath == "app/old.go", "rename row preserves unstripped originalRepoPath")
expect(rows.first { $0.repoPath == "app/é x.go" }.map { $0.status == "??" && !$0.isStaged } == true, "untracked row")
expect(rows.first { $0.repoPath == "other/outside.go" }?.relativePath == "other/outside.go", "a path outside the prefix keeps its repo path")

write("app/\u{301}accent.go", "package app\n")
git(["add", "-N", "app/\u{301}accent.go"])
let intent = status().entries.first { $0.path == "app/\u{301}accent.go" }
expect(intent?.x == " " && intent?.y == "A", "intent-to-add file named with a leading combining mark: \(String(describing: intent))")
let intentRow = GitStatusParser.rows(from: status(), workspacePrefix: "").first { $0.repoPath == "app/\u{301}accent.go" }
expect(intentRow?.status == "A" && intentRow?.isStaged == false, "intent-to-add row is an unstaged A")
git(["rm", "-q", "--cached", "app/\u{301}accent.go"])
try! FileManager.default.removeItem(atPath: repo + "/app/\u{301}accent.go")

let sub = status(in: repo + "/app")
expect(sub.entries.allSatisfy { $0.path.hasPrefix("app/") } && sub.entries.count == s.entries.count - 1, "pathspec . from a subfolder leaves other/ out")

let stats = GitStatusParser.numstat(git(["diff", "--numstat", "-z", "--no-renames", "HEAD", "--", "."]))
expect(stats["app/p.go"]?.added == 3 && stats["app/p.go"]?.removed == 0, "numstat p.go: \(stats)")
expect(stats["app/new name.go"]?.added == 1, "numstat with a space")

git(["add", "-A"])
git(["commit", "-qm", "rename and add"])
let changes = GitStatusParser.nameStatus(git(["show", "--name-status", "-z", "--format=", "-M", "HEAD"]))
expect(changes.contains(GitPathChange(status: "R", path: "app/new name.go", originalPath: "app/old.go")), "name-status rename: \(changes)")
expect(changes.contains(GitPathChange(status: "A", path: "app/é x.go", originalPath: nil)), "name-status non-ASCII")
let renameStats = GitStatusParser.numstat(git(["show", "--numstat", "-z", "--format=", "-M", "HEAD"]))
expect(renameStats["app/new name.go"] != nil && renameStats["app/old.go"] == nil, "numstat rename keyed by the new path: \(renameStats)")

git(["checkout", "-q", "-b", "side"])
write("app/conflict.go", "side\n")
git(["commit", "-qam", "side"])
git(["checkout", "-q", "main"])
write("app/conflict.go", "main\n")
git(["commit", "-qam", "main"])
git(["merge", "side"], ok: [1])
s = status()
expect(s.entries.first { $0.path == "app/conflict.go" }?.isUnmerged == true, "unmerged entry")
let unmergedRow = GitStatusParser.rows(from: s, workspacePrefix: "").first { $0.repoPath == "app/conflict.go" }
expect(unmergedRow?.status == "U" && unmergedRow?.unmergedXY == "UU", "unmerged UU row keeps unmergedXY: \(String(describing: unmergedRow))")
let syntheticUnmerged = GitStatusParser.parse([
    "# branch.oid 0123456789abcdef0123456789abcdef01234567",
    "# branch.head main",
    "u UD N... 100644 100644 000000 100644 aaaa bbbb 0000 app/deleted_by_them.go",
    "u DU N... 100644 000000 100644 100644 aaaa 0000 bbbb app/deleted_by_us.go",
    ""
].joined(separator: "\0"))
let syntheticRows = GitStatusParser.rows(from: syntheticUnmerged, workspacePrefix: "app/")
expect(syntheticRows.map { "\($0.relativePath):\($0.status):\($0.unmergedXY ?? "")" } == ["deleted_by_them.go:U:UD", "deleted_by_us.go:U:DU"], "UD and DU tree conflicts preserve unmergedXY")
git(["merge", "--abort"])

git(["init", "-q", "--bare", remote], in: base)
git(["remote", "add", "origin", remote])
git(["push", "-q", "-u", "origin", "main"])
write("app/p.go", "package app\n// ahead\n")
git(["commit", "-qam", "ahead"])
s = status()
expect(s.upstream == "origin/main" && s.hasUpstream && s.ahead == 1 && s.behind == 0, "ahead/behind: \(s)")

let clone = base + "/clone"
git(["clone", "-q", remote, clone], in: base)
try! "package app\n".write(toFile: clone + "/remote.go", atomically: true, encoding: .utf8)
git(["add", "remote.go"], in: clone)
git(["-c", "user.email=c@example.com", "-c", "user.name=C", "commit", "-q", "-m", "remote"], in: clone)
git(["push", "-q", "origin", "main"], in: clone)
git(["fetch", "-q"])
s = status()
expect(s.ahead == 1 && s.behind == 1 && s.hasUpstream, "ahead and behind: \(s)")

git(["checkout", "-q", "-b", "feat"])
git(["push", "-q", "-u", "origin", "feat"])
expect(status().hasUpstream, "feat tracks origin/feat")
git(["push", "-q", "origin", "--delete", "feat"])
git(["fetch", "-q", "--prune"])
s = status()
expect(s.upstream == "origin/feat" && !s.hasUpstream, "an upstream deleted on the remote is not an upstream: \(s)")

git(["checkout", "-q", "main"])
git(["merge", "-q", "--no-edit", "origin/main"])
let mergeChanges = GitStatusParser.nameStatus(git(["show", "--name-status", "-z", "-M", "--diff-merges=first-parent", "--format=", "HEAD"]))
expect(mergeChanges == [GitPathChange(status: "A", path: "remote.go", originalPath: nil)], "a merge commit lists what it brought in: \(mergeChanges)")

git(["checkout", "-q", "--detach"])
s = status()
expect(s.head == nil && s.hasCommits, "detached head")

print("git-status-check: all checks passed")
