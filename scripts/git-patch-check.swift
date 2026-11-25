// Self-check for partial staging (top-level code, so compile it as main.swift):
//   T=$(mktemp -d) && cp scripts/git-patch-check.swift $T/main.swift && swiftc desktop/Utilities/GitPatchBuilder.swift $T/main.swift -o $T/gpc && $T/gpc
// Builds patches with GitPatchBuilder against a throwaway git repository, applies them the way GoLens does
// (`git apply --cached`, `-R` to unstage, patch on stdin) and checks the index with `git diff --cached` / `git show :path`.
import Foundation

func expect(_ ok: Bool, _ what: String) {
    if !ok {
        print("FAIL:", what)
        exit(1)
    }
}

let repo = FileManager.default.temporaryDirectory.appendingPathComponent("git-patch-check-\(UUID().uuidString)").path
try! FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: repo) }

@discardableResult
func git(_ args: [String], input: String? = nil, ok: Set<Int32> = [0]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = URL(fileURLWithPath: repo)
    process.arguments = args
    let out = Pipe()
    let err = Pipe()
    let inPipe = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = inPipe
    try! process.run()
    inPipe.fileHandleForWriting.write(Data((input ?? "").utf8))
    try! inPipe.fileHandleForWriting.close()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if !ok.contains(process.terminationStatus) {
        print("FAIL: git \(args.joined(separator: " ")) exited \(process.terminationStatus): \(String(decoding: errData, as: UTF8.self))")
        exit(1)
    }
    return String(decoding: data, as: UTF8.self)
}

func applyStatus(_ patch: String, reverse: Bool, cached: Bool = true) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = URL(fileURLWithPath: repo)
    process.arguments = ["apply"] + (cached ? ["--cached"] : []) + ["--whitespace=nowarn"] + (reverse ? ["-R"] : []) + ["-"]
    let inPipe = Pipe()
    process.standardInput = inPipe
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try! process.run()
    inPipe.fileHandleForWriting.write(Data(patch.utf8))
    try! inPipe.fileHandleForWriting.close()
    process.waitUntilExit()
    return process.terminationStatus
}

func write(_ path: String, _ text: String) {
    let url = URL(fileURLWithPath: repo).appendingPathComponent(path)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
}

func index(_ path: String) -> String { git(["show", ":\(path)"]) }
func numbered(_ range: ClosedRange<Int>) -> String { range.map { "line \($0)\n" }.joined() }

func unstagedPatch(_ path: String, context: String = "-U3") -> GitFilePatch {
    let tracked = !git(["ls-files", "--", path]).isEmpty
    let diff = tracked
        ? git(["diff", context, "--no-renames", "--no-color", "--no-ext-diff", "--", path])
        : git(["diff", "--no-index", context, "--no-color", "--", "/dev/null", path], ok: [1])
    guard let patch = GitPatchBuilder.parse(diff).first else {
        print("FAIL: no unstaged diff for \(path)")
        exit(1)
    }
    return patch
}

func stagedPatch(_ path: String) -> GitFilePatch {
    guard let patch = GitPatchBuilder.parse(git(["diff", "--cached", "-U3", "--no-renames", "--no-color", "--no-ext-diff", "--", path])).first else {
        print("FAIL: no staged diff for \(path)")
        exit(1)
    }
    return patch
}

func refs(_ patch: GitFilePatch, where match: (GitPatchLine) -> Bool) -> Set<GitPatchLineRef> {
    var result = Set<GitPatchLineRef>()
    for (h, hunk) in patch.hunks.enumerated() {
        for (l, line) in hunk.lines.enumerated() where line.kind != .context && match(line) {
            result.insert(GitPatchLineRef(hunk: h, line: l))
        }
    }
    return result
}

func line(_ kind: GitPatchLine.Kind, _ text: String) -> (GitPatchLine) -> Bool {
    { $0.kind == kind && $0.text == text }
}

func any(_ matchers: (GitPatchLine) -> Bool...) -> (GitPatchLine) -> Bool {
    { l in matchers.contains { $0(l) } }
}

func stage(_ path: String, _ patch: GitFilePatch, _ selection: Set<GitPatchLineRef>, reverse: Bool = false, _ what: String) {
    let text: String
    do {
        text = try GitPatchBuilder.build(patch, path: path, selecting: selection, reverse: reverse)
    } catch {
        print("FAIL: \(what): build threw \(error)")
        exit(1)
    }
    let status = applyStatus(text, reverse: reverse)
    if status != 0 {
        print("FAIL: \(what): git apply rejected the patch:\n\(text)")
        exit(1)
    }
}

git(["init", "-q"])
git(["config", "user.email", "check@example.com"])
git(["config", "user.name", "Check"])
git(["config", "core.autocrlf", "false"])
git(["config", "commit.gpgsign", "false"])

write("a.txt", numbered(1...20))
write("eof.txt", "x\ny")
write("crlf.txt", "a\r\nb\r\nc\r\n")
write("gone.txt", "1\n2\n3\n")
write("dash.sql", "select 1;\n-- comment\nselect 2;\n")
write("dir with space/ü file.txt", "one\ntwo\n")
git(["add", "-A"])
git(["commit", "-q", "-m", "base"])

// Parser: a removed line that starts with "-- " is a body line, not a file header.
write("dash.sql", "select 1;\nselect 2;\n")
let dash = unstagedPatch("dash.sql")
expect(dash.hunks.count == 1 && dash.hunks[0].lines.contains(GitPatchLine(kind: .removed, text: "-- comment")), "removed '-- ' line parses as body")
stage("dash.sql", dash, refs(dash) { _ in true }, "stage dash.sql")
expect(index("dash.sql") == "select 1;\nselect 2;\n", "dash.sql staged")

// Whole hunk: two separated changes, stage only the first.
var a = numbered(1...20).replacingOccurrences(of: "line 2\n", with: "LINE 2\n").replacingOccurrences(of: "line 18\n", with: "LINE 18\n")
write("a.txt", a)
var p = unstagedPatch("a.txt")
expect(p.hunks.count == 2, "two hunks")
let runs = GitPatchBuilder.runs(in: p)
expect(runs.count == 2 && runs[0].newStart == 2 && runs[0].newCount == 1 && runs[1].newStart == 18, "runs map to new line numbers")
stage("a.txt", p, Set(runs[0].refs), "stage first hunk")
var cached = git(["diff", "--cached", "--", "a.txt"])
expect(cached.contains("+LINE 2") && !cached.contains("LINE 18"), "git diff --cached has only the first hunk")
expect(git(["diff", "--", "a.txt"]).contains("+LINE 18"), "second hunk still unstaged")

// Unstage that hunk again.
p = stagedPatch("a.txt")
stage("a.txt", p, refs(p) { _ in true }, reverse: true, "unstage first hunk")
expect(git(["diff", "--cached", "--", "a.txt"]).isEmpty, "nothing staged after unstage")

// Full-file context (the diff view's Full File mode): stage only the second change.
p = unstagedPatch("a.txt", context: "-U99999")
expect(p.hunks.count == 1, "one hunk with full context")
stage("a.txt", p, Set(GitPatchBuilder.runs(in: p)[1].refs), "stage second change from full-context diff")
expect(index("a.txt") == numbered(1...20).replacingOccurrences(of: "line 18\n", with: "LINE 18\n"), "only line 18 staged")
git(["reset", "-q", "--", "a.txt"])

// Line subset: unselected '-' lines become context, unselected '+' lines are dropped.
a = numbered(1...4) + "five\nsix\nextra\n" + numbered(7...20)
write("a.txt", a)
p = unstagedPatch("a.txt")
stage("a.txt", p, refs(p, where: any(line(.removed, "line 5"), line(.added, "five"))), "stage a line subset")
expect(index("a.txt") == numbered(1...4) + "five\n" + numbered(6...20), "subset staged into the index")
cached = git(["diff", "--cached", "--", "a.txt"])
expect(cached.contains("-line 5") && cached.contains("+five") && !cached.contains("six") && !cached.contains("-line 6"), "git diff --cached shows only the selected lines")

// Unstage a subset: unselected '+' lines stay in the index, unselected '-' lines stay out.
git(["add", "a.txt"])
p = stagedPatch("a.txt")
stage("a.txt", p, refs(p, where: any(line(.removed, "line 5"), line(.added, "five"))), reverse: true, "unstage a line subset")
expect(index("a.txt") == numbered(1...4) + "line 5\nsix\nextra\n" + numbered(7...20), "subset unstaged")
p = stagedPatch("a.txt")
stage("a.txt", p, refs(p, where: line(.added, "extra")), reverse: true, "unstage one added line")
expect(index("a.txt") == numbered(1...4) + "line 5\nsix\n" + numbered(7...20), "added line unstaged")
git(["reset", "-q", "--", "a.txt"])

// Deleted lines at the start and end of a file, staged separately and together.
write("a.txt", numbered(3...18))
p = unstagedPatch("a.txt")
expect(p.hunks.count == 2, "start and end deletions are separate hunks")
let deletionRuns = GitPatchBuilder.runs(in: p)
expect(deletionRuns[0].newCount == 0 && deletionRuns[0].newStart == 0, "deletion at file start anchors before line 1")
stage("a.txt", p, Set(deletionRuns[1].refs), "stage end deletion")
expect(index("a.txt") == numbered(1...18), "end deletion staged")
git(["reset", "-q", "--", "a.txt"])
p = unstagedPatch("a.txt")
stage("a.txt", p, refs(p) { _ in true }, "stage both deletions")
expect(index("a.txt") == numbered(3...18), "both deletions staged")
git(["reset", "-q", "--", "a.txt"])

// Second hunk start must account for the first hunk's selected delta.
write("a.txt", "new top\n" + numbered(1...4) + numbered(6...20) + "new bottom\n")
p = unstagedPatch("a.txt")
stage("a.txt", p, refs(p, where: any(line(.added, "new top"), line(.added, "new bottom"))), "stage top and bottom additions")
expect(index("a.txt") == "new top\n" + numbered(1...20) + "new bottom\n", "additions staged around an unselected deletion")
git(["reset", "-q", "--", "a.txt"])

// No newline at end of file.
write("eof.txt", "x\nY\nz")
p = unstagedPatch("eof.txt")
do {
    _ = try GitPatchBuilder.build(p, path: "eof.txt", selecting: refs(p, where: line(.added, "z")), reverse: false)
    expect(false, "adding after a line without newline must be refused")
} catch {
    expect(error as? GitPatchError == .incompleteLastLine, "incomplete last line error")
}
stage("eof.txt", p, refs(p, where: line(.removed, "y")), "stage removal of the last line")
expect(index("eof.txt") == "x\n", "last line removed")
git(["reset", "-q", "--", "eof.txt"])
p = unstagedPatch("eof.txt")
stage("eof.txt", p, refs(p) { _ in true }, "stage whole hunk without trailing newline")
expect(index("eof.txt") == "x\nY\nz", "no-newline file staged byte for byte")
p = stagedPatch("eof.txt")
stage("eof.txt", p, refs(p) { _ in true }, reverse: true, "unstage no-newline hunk")
expect(index("eof.txt") == "x\ny", "no-newline file unstaged")

// CRLF line endings survive byte for byte.
write("crlf.txt", "a\r\nB\r\nc\r\nd\r\n")
p = unstagedPatch("crlf.txt")
stage("crlf.txt", p, refs(p, where: any(line(.removed, "b\r"), line(.added, "B\r"))), "stage CRLF subset")
expect(index("crlf.txt") == "a\r\nB\r\nc\r\n", "CRLF subset staged")

// New (untracked) file: stage a subset, unstage part, then unstage the rest.
write("new.txt", "a\nb\nc\n")
p = unstagedPatch("new.txt")
expect(p.isNewFile, "untracked diff is a new file")
stage("new.txt", p, refs(p, where: any(line(.added, "a"), line(.added, "c"))), "stage part of a new file")
expect(index("new.txt") == "a\nc\n", "new file subset staged")
p = stagedPatch("new.txt")
stage("new.txt", p, refs(p, where: line(.added, "c")), reverse: true, "unstage part of a new file")
expect(index("new.txt") == "a\n", "new file partly unstaged")
p = stagedPatch("new.txt")
stage("new.txt", p, refs(p) { _ in true }, reverse: true, "unstage the rest of a new file")
expect(git(["ls-files", "--", "new.txt"]).isEmpty, "new file removed from the index")

// Deleted file: stage a subset of the deletion, then the rest; unstage part of a staged deletion.
try! FileManager.default.removeItem(atPath: (repo as NSString).appendingPathComponent("gone.txt"))
p = unstagedPatch("gone.txt")
expect(p.isDeletedFile, "deletion diff")
stage("gone.txt", p, refs(p, where: line(.removed, "2")), "stage one deleted line")
expect(index("gone.txt") == "1\n3\n", "partial deletion staged")
p = unstagedPatch("gone.txt")
stage("gone.txt", p, refs(p) { _ in true }, "stage the rest of the deletion")
expect(git(["ls-files", "--", "gone.txt"]).isEmpty, "file deleted from the index")
p = stagedPatch("gone.txt")
stage("gone.txt", p, refs(p, where: line(.removed, "2")), reverse: true, "unstage one line of a deletion")
expect(index("gone.txt") == "2\n", "deleted line restored in the index")

// Quoted paths (spaces and non-ASCII).
write("dir with space/ü file.txt", "one\nTWO\n")
p = unstagedPatch("dir with space/ü file.txt")
stage("dir with space/ü file.txt", p, refs(p) { _ in true }, "stage a path that needs quoting")
expect(index("dir with space/ü file.txt") == "one\nTWO\n", "quoted path staged")

// A stale patch is rejected and leaves the index untouched.
write("a.txt", numbered(1...20).replacingOccurrences(of: "line 10\n", with: "ten\n"))
p = unstagedPatch("a.txt")
git(["add", "a.txt"])
let before = git(["ls-files", "-s"])
let stale = try! GitPatchBuilder.build(p, path: "a.txt", selecting: refs(p) { _ in true }, reverse: false)
expect(applyStatus(stale, reverse: false) != 0, "stale patch rejected")
expect(git(["ls-files", "-s"]) == before, "rejected patch changes nothing")

do {
    _ = try GitPatchBuilder.build(p, path: "a.txt", selecting: [], reverse: false)
    expect(false, "empty selection must throw")
} catch {
    expect(error as? GitPatchError == .emptySelection, "empty selection error")
}

// Discard Change: the unstaged hunk is reverse-applied to the work tree, anchored at its work tree position.
// A duplicated block below a hunk that adds lines must not make git revert the wrong copy.
let block = "ctx a\nctx b\nctx c\nTARGET\nctx d\nctx e\nctx f\n"
let changedBlock = block.replacingOccurrences(of: "TARGET", with: "CHANGED")
let filler = { (n: Int) in (1...n).map { "filler \($0)\n" }.joined() }
write("dup.txt", filler(3) + block + filler(10) + block + filler(3))
git(["add", "dup.txt"])
git(["commit", "-q", "-m", "dup"])
write("dup.txt", numbered(1...12) + filler(3) + changedBlock + filler(10) + changedBlock + filler(3))
p = unstagedPatch("dup.txt")
expect(p.hunks.count == 2, "duplicated block diff has two hunks")
let discardSelection = refs(p) { _ in true }.filter { $0.hunk == 1 }
let discardPatch = try! GitPatchBuilder.build(p, path: "dup.txt", selecting: discardSelection, reverse: true)
expect(applyStatus(discardPatch, reverse: true, cached: false) == 0, "discard patch applies to the work tree")
let discarded = try! String(contentsOfFile: (repo as NSString).appendingPathComponent("dup.txt"), encoding: .utf8)
expect(discarded == numbered(1...12) + filler(3) + changedBlock + filler(10) + block + filler(3), "only the second hunk is discarded")

print("ok")
