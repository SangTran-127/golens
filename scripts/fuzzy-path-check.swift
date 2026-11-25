// Self-check for Open Quickly's file matcher (top-level code, so compile it as main.swift):
//   cp scripts/fuzzy-path-check.swift /tmp/main.swift && swiftc -O desktop/Utilities/FuzzyPathMatcher.swift /tmp/main.swift -o /tmp/fpc && /tmp/fpc [root-to-time]
import Foundation

func expect(_ ok: Bool, _ what: String) { if !ok { print("FAIL:", what); exit(1) } }
let paths = ["internal/maintenance/go.mod", "cmd/server/main.go", "main_test.go", "docs/website_style.css",
             "desktop/State/WorkspaceState.swift", "desktop/State/WorkspaceState+Search.swift", "README.md"]
let cands = paths.map(FuzzyPathMatcher.Candidate.init)
func top(_ q: String) -> String? { FuzzyPathMatcher.rank(q, cands, limit: 10).first }

expect(top("main.go") == "cmd/server/main.go", "exact file name beats a scattered match")
expect(top("wss") == "desktop/State/WorkspaceState.swift", "word starts: W-S-S, shorter path first")
expect(top("WorkspaceState+s") == "desktop/State/WorkspaceState+Search.swift", "longer name prefix wins")
expect(top("srv/main") == "cmd/server/main.go", "path segments match")
expect(top("readme") == "README.md", "case-insensitive")
expect(FuzzyPathMatcher.rank("zzz", cands, limit: 10).isEmpty, "no match → no result")
expect(FuzzyPathMatcher.rank("", cands, limit: 3).count == 3, "empty query keeps the limit")

if CommandLine.arguments.count > 1 {
    let root = CommandLine.arguments[1]
    let files = FileManager.default.enumerator(atPath: root)!.compactMap { $0 as? String }
    let big = files.map(FuzzyPathMatcher.Candidate.init)
    for q in ["s", "http", "srvgo", "net/http/server.go"] {
        let t = Date()
        let r = FuzzyPathMatcher.rank(q, big, limit: 50)
        print(String(format: "%@ over %d files: %.1f ms, top %@", q, big.count, Date().timeIntervalSince(t) * 1000, r.first ?? "-"))
    }
}
print("ok")
