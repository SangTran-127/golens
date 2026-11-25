// Self-check for large, binary and untracked-folder detection and for the untracked=normal status form:
//   T=$(mktemp -d) && swiftc -parse-as-library -emit-library -emit-module -module-name GoLensFoundation Sources/GoLensFoundation/*.swift -emit-module-path $T/GoLensFoundation.swiftmodule -o $T/libGoLensFoundation.dylib \
//     && cp scripts/git-diff-notice-check.swift $T/main.swift && swiftc -I $T -L $T -lGoLensFoundation desktop/Utilities/GitDiffNotice.swift desktop/Utilities/GitStatusParser.swift desktop/Utilities/UserMessage.swift $T/main.swift -o $T/gdn && DYLD_LIBRARY_PATH=$T $T/gdn
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

func git(_ args: [String], in dir: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-c", "user.name=check", "-c", "user.email=check@example.com"] + args
    process.currentDirectoryURL = URL(fileURLWithPath: dir)
    var env = ProcessInfo.processInfo.environment
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    process.environment = env
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gdn-\(UUID().uuidString)").path
try! FileManager.default.createDirectory(atPath: dir + "/output/run/checkpoint", withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: dir) }

let small = dir + "/small.txt"
try! "hello\n".write(toFile: small, atomically: true, encoding: .utf8)
check(GitDiffNotice.untrackedNotice(forPath: small) == nil, "a small text file is diffed normally")

let large = dir + "/output/run/checkpoint/tokenizer.json"
let line = String(repeating: "x", count: 63) + "\n"
try! String(repeating: line, count: 20_000).write(toFile: large, atomically: true, encoding: .utf8)
let largeNotice = GitDiffNotice.untrackedNotice(forPath: large).flatMap { GitDiffNotice.message(in: $0) }
check(largeNotice?.contains("too large") == true, "a 1.3 MB text file gets the too-large notice, got \(String(describing: largeNotice))")

let binary = dir + "/blob.bin"
FileManager.default.createFile(atPath: binary, contents: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]))
let binaryNotice = GitDiffNotice.untrackedNotice(forPath: binary).flatMap { GitDiffNotice.message(in: $0) }
check(binaryNotice?.hasPrefix("Binary file") == true, "a file with NUL bytes is binary, got \(String(describing: binaryNotice))")

let folderNotice = GitDiffNotice.untrackedNotice(forPath: dir + "/output").flatMap { GitDiffNotice.message(in: $0) }
check(folderNotice?.contains("untracked folder") == true, "a folder gets the folder notice")
check(GitDiffNotice.message(in: "diff --git a/x b/x\n") == nil, "a real diff is not a notice")
check(GitDiffNotice.headerOnlyMessage(in: "diff --git a/a.png b/a.png\nBinary files a/a.png and b/a.png differ\n") == "Binary files differ and can’t be compared as text.", "binary diff header notice")
check(GitDiffNotice.headerOnlyMessage(in: "diff --git a/a.png b/a.png\nGIT binary patch\nliteral 4\n") == "Binary files differ and can’t be compared as text.", "git binary patch header notice")
check(GitDiffNotice.headerOnlyMessage(in: "diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n") == "File permissions changed from 100644 to 100755.", "permission mode change header notice")
check(GitDiffNotice.headerOnlyMessage(in: "diff --git a/old.go b/new.go\nsimilarity index 100%\nrename from old.go\nrename to new.go\n") == "Renamed from old.go to new.go with no content changes.", "pure rename header notice")
check(GitDiffNotice.headerOnlyMessage(in: "diff --git a/old.go b/copy.go\nsimilarity index 100%\ncopy from old.go\ncopy to copy.go\n") == "Copied from old.go to copy.go with no content changes.", "pure copy header notice")
check(GitDiffNotice.headerOnlyMessage(in: "diff --git a/empty.txt b/empty.txt\nnew file mode 100644\nindex 0000000..e69de29\n") == "Empty file added.", "empty added file header notice")
check(GitDiffNotice.headerOnlyMessage(in: "diff --git a/empty.txt b/empty.txt\ndeleted file mode 100644\nindex e69de29..0000000\n") == "Empty file deleted.", "empty deleted file header notice")
check(GitDiffNotice.headerOnlyMessage(in: "diff --git a/sub b/sub\nindex 1111111..2222222 160000\n--- a/sub\n+++ b/sub\n-Subproject commit 1111111\n+Subproject commit 2222222\n") == "Submodule commit changed.", "submodule commit header notice")
check(GitDiffNotice.headerOnlyMessage(in: "diff --git a/a.go b/a.go\n--- a/a.go\n+++ b/a.go\n@@ -1 +1 @@\n-old\n+new\n") == nil, "normal hunk diff returns nil headerOnlyMessage")

_ = git(["init", "-q"], in: dir)
try! "tracked\n".write(toFile: dir + "/tracked.txt", atomically: true, encoding: .utf8)
_ = git(["add", "tracked.txt"], in: dir)
_ = git(["commit", "-qm", "base"], in: dir)
try! "tracked changed\n".write(toFile: dir + "/tracked.txt", atomically: true, encoding: .utf8)
_ = git(["add", "tracked.txt"], in: dir)

let normal = GitStatusParser.parse(git(["--no-optional-locks", "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal", "--", "."], in: dir))
let all = GitStatusParser.parse(git(["--no-optional-locks", "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all", "--", "."], in: dir))
let normalUntracked = normal.entries.filter(\.isUntracked).map(\.path).sorted()
check(normalUntracked == ["blob.bin", "output/", "small.txt"], "untracked=normal folds the folder, got \(normalUntracked)")
check(all.entries.filter(\.isUntracked).count == 3, "untracked=all lists every file")
let rows = GitStatusParser.rows(from: normal, workspacePrefix: "")
check(rows.contains { $0.relativePath == "output/" && $0.status == "??" }, "the folded folder keeps its trailing slash")
let tracked = normal.entries.first { $0.path == "tracked.txt" }
let indexObject = git(["rev-parse", ":tracked.txt"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines)
check(tracked?.indexObject == indexObject, "the index object id is kept per entry")

if failures == 0 {
    print("git-diff-notice-check: all checks passed")
} else {
    print("git-diff-notice-check: \(failures) failure(s)")
    exit(1)
}
