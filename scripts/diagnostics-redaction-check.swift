import Foundation

#if DIAGNOSTICS_CHECK_LINKED
func expect(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let rawInput = """
OPENAI=sk-proj-fakeKey1234567890abcdef
ANTHROPIC=sk-ant-api03-fakeAnthropic9876543210
GOOGLE=AIzaSyFakeGoogleKey1234567890abcdefgh
GITHUB=ghp_1234567890abcdefghijklmnop
GITHUB_PAT=github_pat_11ABCDEFG_0123456789abcdefghij
SLACK=xoxb-123456789012-1234567890123-fakeSlackTok
AWS=AKIAIOSFODNN7EXAMPLE
JWT=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signatureFakeValue123
AUTH=Bearer super_secret_bearer_token_987
BASIC=Basic dXNlcjpwYXNzMTIz
GIT_URL=https://alice:hunter2secret@github.com/org/repo.git
api_key=my_fake_key_999
token="quoted_secret_token_42"
password=TopSecretPass123!
"client_secret": "shh_client_999"
KEEP_LINE=token-ratchet.py: line 12
EMAIL=dev.user+test@example.com
KEEP_MOD=golang.org/x/tools/gopls@latest
HOME_LOCAL=\(NSHomeDirectory())/Documents/project/main.go
HOME_OTHER=/Users/someoneelse/workspace/foo.go
EXTRA=customSecretValue991122
PROJECT=/Volumes/Work/client-project/internal/api.go
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
DB_PASS=plainpw999
STRIPE=sk_live_51ABCDEFGHIJKLMNOPQRSTUV
DSN=postgres://admin:s3cretPW@db.internal:5432/app
"""

let redacted = DiagnosticsRedactor.redact(rawInput, extraSecrets: ["customSecretValue991122"], projectPaths: ["/Volumes/Work/client-project"])

let forbiddenSubstrings = [
    "sk-proj-fakeKey1234567890abcdef",
    "sk-ant-api03-fakeAnthropic9876543210",
    "AIzaSyFakeGoogleKey1234567890abcdefgh",
    "ghp_1234567890abcdefghijklmnop",
    "github_pat_11ABCDEFG_0123456789abcdefghij",
    "xoxb-123456789012-1234567890123-fakeSlackTok",
    "AKIAIOSFODNN7EXAMPLE",
    "signatureFakeValue123",
    "super_secret_bearer_token_987",
    "dXNlcjpwYXNzMTIz",
    "hunter2secret",
    "my_fake_key_999",
    "quoted_secret_token_42",
    "TopSecretPass123!",
    "shh_client_999",
    "dev.user+test@example.com",
    "/Users/someoneelse",
    NSHomeDirectory(),
    "customSecretValue991122",
    "client-project",
    "wJalrXUtnFEMI",
    "plainpw999",
    "sk_live_51ABCDEFGHIJKLMNOPQRSTUV",
    "s3cretPW"
]

for needle in forbiddenSubstrings {
    expect(!redacted.contains(needle), "secret leaked: \(needle)")
}

expect(redacted.contains("Bearer [REDACTED]"), "bearer marker present")
expect(redacted.contains("https://[REDACTED]@github.com/org/repo.git"), "url userinfo redacted")
expect(redacted.contains("[REDACTED_EMAIL]"), "email redacted")
expect(redacted.contains("~/Documents/project/main.go"), "NSHomeDirectory mapped to tilde")
expect(redacted.contains("~/workspace/foo.go"), "/Users/<name> mapped to tilde")
expect(redacted.contains("PROJECT=[Project]/internal/api.go"), "project path replaced")
expect(redacted.contains("token-ratchet.py: line 12"), "filename containing token word preserved")
expect(redacted.contains("golang.org/x/tools/gopls@latest"), "go module @latest preserved")
expect(DiagnosticsRedactor.redact(redacted) == redacted, "redaction is idempotent")

let fm = FileManager.default
let tempDir = fm.temporaryDirectory.appendingPathComponent("golens-redaction-check-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tempDir) }

let sysItem = DiagnosticItem(
    id: "system",
    title: "App & System",
    filename: "system-info.txt",
    summary: "System",
    content: "Workspace: /Users/alice/code\nKey: sk-proj-exportSecretCheck9999",
    isIncluded: true
)
let uncheckedItem = DiagnosticItem(
    id: "logs",
    title: "GoLens Logs",
    filename: "golens-logs.txt",
    summary: "Logs",
    content: "SHOULD_NOT_EXPORT_UNCHECKED",
    isIncluded: false
)
let toolchainItem = DiagnosticItem(
    id: "toolchain",
    title: "Go & gopls Toolchain",
    filename: "toolchain-health.txt",
    summary: "Toolchain",
    content: "Go Version: go1.26.0",
    isIncluded: true
)

let zipURL = tempDir.appendingPathComponent("diag.zip")
try DiagnosticsArchiveExporter.exportArchive(items: [sysItem, uncheckedItem, toolchainItem], to: zipURL)
expect(fm.fileExists(atPath: zipURL.path), "archive file written")

func runOutput(_ launchPath: String, _ args: [String]) -> (Int32, String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: launchPath)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    try! proc.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

let (listStatus, zipListing) = runOutput("/usr/bin/unzip", ["-l", zipURL.path])
expect(listStatus == 0, "unzip -l succeeded")
expect(zipListing.contains("system-info.txt"), "included system-info.txt present in zip")
expect(zipListing.contains("toolchain-health.txt"), "included toolchain-health.txt present in zip")
expect(!zipListing.contains("golens-logs.txt"), "unchecked golens-logs.txt excluded from zip")

let (catStatus, sysContents) = runOutput("/usr/bin/unzip", ["-p", zipURL.path, "system-info.txt"])
expect(catStatus == 0, "unzip -p system-info.txt succeeded")
expect(!sysContents.contains("sk-proj-exportSecretCheck9999"), "archived file has secret redacted")
expect(!sysContents.contains("/Users/alice"), "archived file has home path redacted")
expect(sysContents.contains("~/code"), "archived file keeps redacted tilde path")

var didThrowEmpty = false
do {
    try DiagnosticsArchiveExporter.exportArchive(items: [uncheckedItem], to: tempDir.appendingPathComponent("empty.zip"))
} catch {
    didThrowEmpty = true
}
expect(didThrowEmpty, "exportArchive rejects all-unchecked list")

print("diagnostics-redaction-check: ALL PASSED")
#else
let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let fm = FileManager.default
let tempDir = fm.temporaryDirectory.appendingPathComponent("golens-diag-runner-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tempDir) }

let mainSwift = tempDir.appendingPathComponent("main.swift")
try fm.copyItem(at: scriptURL, to: mainSwift)
let binary = tempDir.appendingPathComponent("diag-check")

let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = [
    "-DDIAGNOSTICS_CHECK_LINKED",
    repoRoot.appendingPathComponent("desktop/Diagnostics/DiagnosticsRedactor.swift").path,
    repoRoot.appendingPathComponent("desktop/Diagnostics/DiagnosticsArchive.swift").path,
    mainSwift.path,
    "-o",
    binary.path
]
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else {
    exit(compile.terminationStatus)
}

let run = Process()
run.executableURL = binary
try run.run()
run.waitUntilExit()
exit(run.terminationStatus)
#endif
