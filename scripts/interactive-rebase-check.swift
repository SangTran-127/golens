// Self-check for the interactive rebase plan (top-level code, so compile it as main.swift):
//   T=$(mktemp -d) && cp scripts/interactive-rebase-check.swift $T/main.swift && swiftc desktop/Utilities/GitStatusParser.swift desktop/Utilities/GitHistoryParser.swift desktop/Utilities/InteractiveRebasePlan.swift $T/main.swift -o $T/irc && $T/irc
// Builds throwaway repositories and runs `git rebase -i` with the todo GoLens writes, the way GoLens runs it:
// reorder, drop, squash, fixup, reword and stop to edit.
import Foundation

func expect(_ ok: Bool, _ what: String) {
    if !ok {
        print("FAIL:", what)
        exit(1)
    }
}

let base = FileManager.default.temporaryDirectory.appendingPathComponent("interactive-rebase-check-\(UUID().uuidString)").path
defer { try? FileManager.default.removeItem(atPath: base) }

@discardableResult
func git(_ args: [String], in dir: String, allowFailure: Bool = false) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = URL(fileURLWithPath: dir)
    process.arguments = ["-c", "user.name=Ann Lee", "-c", "user.email=ann@example.com", "-c", "commit.gpgsign=false"] + args
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "GIT_EDITOR")
    env.removeValue(forKey: "GIT_SEQUENCE_EDITOR")
    env["EDITOR"] = "false"
    process.environment = env
    let out = Pipe()
    process.standardOutput = out
    process.standardError = out
    try! process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    if !allowFailure { expect(process.terminationStatus == 0, "git \(args.joined(separator: " ")) exited \(process.terminationStatus): \(text)") }
    return text
}

func makeRepo(_ name: String) -> String {
    let repo = base + "/" + name
    try! FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    git(["init", "-q", "-b", "main"], in: repo)
    for (index, word) in ["one", "two", "three", "four"].enumerated() {
        try! "\(word)\n".write(toFile: repo + "/\(word).txt", atomically: true, encoding: .utf8)
        git(["add", "-A"], in: repo)
        git(["commit", "-q", "-m", "add \(word)", "-m", "body \(index)"], in: repo)
    }
    return repo
}

func steps(_ repo: String, from revision: String) -> [InteractiveRebaseStep] {
    let commits = GitHistoryParser.commits(git(["log", "-z", "--reverse", "--format=\(GitHistoryParser.logFormat)", "\(revision)^..HEAD"], in: repo))
    return commits.map { InteractiveRebaseStep(commit: $0, message: git(["show", "-s", "--format=%B", $0.hash], in: repo)) }
}

func run(_ repo: String, _ plan: [InteractiveRebaseStep], onto revision: String) -> String {
    let gitDir = git(["rev-parse", "--absolute-git-dir"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
    let (todo, messages) = InteractiveRebasePlan.todo(plan)
    try! todo.write(toFile: gitDir + "/" + InteractiveRebasePlan.todoFileName, atomically: true, encoding: .utf8)
    for (name, text) in messages {
        try! text.write(toFile: gitDir + "/" + name, atomically: true, encoding: .utf8)
    }
    return git(["-c", "sequence.editor=\(InteractiveRebasePlan.sequenceEditor)", "-c", "core.editor=true", "rebase", "-i", "--autostash", revision + "^"], in: repo, allowFailure: true)
}

func subjects(_ repo: String) -> [String] {
    git(["log", "--format=%s", "--reverse"], in: repo).split(separator: "\n").map(String.init)
}

let repo = makeRepo("main")
var plan = steps(repo, from: "HEAD~2")
let original = plan.map(\.commit.hash)
expect(plan.map(\.commit.subject) == ["add two", "add three", "add four"], "range is oldest first: \(plan.map(\.commit.subject))")
expect(InteractiveRebasePlan.problem(plan, original: original) == "Change an action, a message or the order to rebase.", "an unchanged plan is not run")
plan[0].action = .squash
expect(InteractiveRebasePlan.problem(plan, original: original)?.contains("no earlier commit to fold into") == true, "squash needs an earlier commit")
plan[0].action = .reword
plan[0].message = "  "
expect(InteractiveRebasePlan.problem(plan, original: original)?.hasPrefix("Write a message") == true, "reword needs a message")

plan[0].message = "add two, reworded\n\nnew body"
plan.swapAt(1, 2)
plan[2].action = .fixup
expect(InteractiveRebasePlan.problem(plan, original: original) == nil, "reword, reorder and fixup is a valid plan")
let output = run(repo, plan, onto: "HEAD~2")
expect(subjects(repo) == ["add one", "add two, reworded", "add four"], "reword, reorder and fixup: \(subjects(repo)) \(output)")
expect(git(["show", "-s", "--format=%B", "HEAD~1"], in: repo).contains("new body"), "the reworded message keeps its body")
expect(FileManager.default.fileExists(atPath: repo + "/three.txt"), "the fixup kept the change of add three")
expect(git(["show", "--stat", "--format=", "HEAD"], in: repo).contains("three.txt"), "add three was folded into add four")

let second = makeRepo("second")
var squash = steps(second, from: "HEAD~2")
squash[1].action = .squash
squash[2].action = .drop
_ = run(second, squash, onto: "HEAD~2")
expect(subjects(second) == ["add one", "add two"], "squash and drop: \(subjects(second))")
let squashed = git(["show", "-s", "--format=%B", "HEAD"], in: second)
expect(squashed.contains("add two") && squashed.contains("add three") && !squashed.contains("#"), "squash keeps both messages without comments: \(squashed)")
expect(!FileManager.default.fileExists(atPath: second + "/four.txt"), "drop removed the change")

let third = makeRepo("third")
try! "dirty\n".write(toFile: third + "/one.txt", atomically: true, encoding: .utf8)
var edit = steps(third, from: "HEAD~1")
edit[0].action = .edit
_ = run(third, edit, onto: "HEAD~1")
let gitDir = git(["rev-parse", "--absolute-git-dir"], in: third).trimmingCharacters(in: .whitespacesAndNewlines)
expect(FileManager.default.fileExists(atPath: gitDir + "/rebase-merge"), "stop to edit leaves the rebase in progress")
expect(FileManager.default.fileExists(atPath: gitDir + "/rebase-merge/amend"), "the stop is marked as an edit stop")
git(["-c", "core.editor=true", "rebase", "--continue"], in: third)
expect(subjects(third) == ["add one", "add two", "add three", "add four"], "continue finishes the rebase")
expect((try? String(contentsOfFile: third + "/one.txt", encoding: .utf8)) == "dirty\n", "autostash restores uncommitted changes")

print("interactive-rebase-check: all checks passed")
