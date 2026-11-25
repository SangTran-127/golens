# Technical Debt

Known structural problems that are deferred on purpose. Each entry states the problem, the evidence, what is already mitigated, and what must be researched before anyone builds a fix.

## Usage counts depend on gopls references

Recorded 2026-11-10. Status: resolved on 2026-11-11. The usage and implementation lenses now read from a type-checked index in `core/usageindex`; the gopls requests described below are sent only when that index is unavailable. The research found that the parse-only index proposed below is not exact for methods, so it was not built. The rest of this entry is kept as the record of the original problem.

### Problem

The editor shows "N usages" above each declaration. For every visible declaration, `WorkspaceState.codeLens(for:inPath:author:)` in `desktop/State/WorkspaceState.swift` sends gopls `textDocument/references` and `textDocument/implementation`. Each references query for an exported symbol makes gopls type-check the declaring package and search its reverse dependencies.

In the optional Linux VM execution mode, gopls runs in a 512 MB Linux VM. During the 2026-11-10 stress run, gopls heap with 60 files open was about 490 MB with the usage lens on, against about 210 MB without it. RSS did not come back down after the files were closed.

### Mitigated

These cheap fixes ship separately:

- Send `implementation` only for types, interfaces and methods.
- Cancel in-flight lens requests on edit, and recompute after a typing pause or a save.
- In the VM, fetch lenses one at a time, and pause while gopls is near its memory limit.
- A Settings toggle for usage counts.

### Deferred: a host-side usage index

The idea is to work the way GoLand does: the Go core keeps its own index of the workspace on the host, built from a syntax parse without type checking and updated per edited file. The lens reads counts from that index instead of from gopls.

It is deferred because a wrong count is worse than no count, and the accuracy and cost are unproven. Before any code is written, research must answer:

1. **How existing tools do it.**
   - IntelliJ and GoLand: word and stub indexes, how candidate files are narrowed, and how Code Vision cancels work when the user types.
   - gopls: its xrefs and methodsets indexes, and why it still type-checks the declaring package.
   - The gopls team's position in golang/go#40862 and #56695.
2. **Which symbol kinds a parse-only index counts exactly.**
   - Package-level funcs, types, vars and consts are likely exact.
   - Methods and fields are ambiguous across types.
   - Embedding, promoted methods, interface implementations, dot imports, aliases, generics, build tags, test files, cgo and generated code each need a decision: show an exact count, show no lens, or ask gopls on click.
3. **Measured cost on a real workspace.** Use the lms copy. Measure full build time, memory, index size and incremental re-index time per file.
4. **Measured accuracy against gopls references.** Use a stated sample and pass criteria, and run it on a quiet machine.
5. **Design and fit.**
   - Where the index lives in `core/`.
   - How it gets file contents: disk plus open editor buffers.
   - Invalidation on edit, save, branch switch and go.mod change.
   - Sandbox file access, the memory budget, typing-latency impact, and the UI while the index builds.

### Sources found so far

- golang/go#40862, the gopls references code lens request: https://github.com/golang/go/issues/40862
- golang/go#56695: https://golang.org/issue/56695
- gopls xrefs index commit: https://go.googlesource.com/tools/+/2be9d05fe891b194b2e099acbf48899748e292cc
- vscode-go removal of its references code lens: https://go.googlesource.com/vscode-go/+/203717d7d3a151c74ce1ba9ad63aafd6473fa535%5E%21/
- IntelliJ Platform threading rules (cancel background reads when the user types): https://plugins.jetbrains.com/docs/intellij/general-threading-rules.html

## Safety checks rebuilt with precision rules in `core/analysis/pipeline.go`

Recorded 2026-11-17. Status: resolved. Background analysis runs through `core/analysis/pipeline.go` (`RunPackageAnalyzersJSON`), avoiding overlap with `gopls` built-in modernizers (`MODERN_ANY` removed from background emission while preserving AST contextual quick fixes) and eliminating noisy heuristics.

### Rebuilt high-precision checks

- **Path traversal** (`core/analysis/safety_checks.go`): tracks dynamic function parameters, HTTP request inputs (`Query`, `PathValue`, `FormValue`, Gin/Chi params), and struct fields joined via `filepath.Join`, `path.Join`, or path-separator `+` concatenation into `os.Open`, `os.OpenFile`, `os.ReadFile`, `os.WriteFile`, `os.Create`, `os.Remove`, `os.RemoveAll`, `os.MkdirAll`, `ioutil.ReadFile`/`WriteFile`, and `http.ServeFile` without a `filepath.Rel`, `filepath.IsLocal`, `strings.HasPrefix`/`CutPrefix` containment guard, or containment predicate helper. Excludes string literals, numeric/UUID/hex-digest helpers, `fmt.Sprintf` with safe numeric/prefix + `filepath.Base`, non-HTTP `filepath.IsAbs` relative-resolution fallbacks, and `_test.go` fixtures.
- **Timing-unsafe MAC and digest comparison** (`core/analysis/crypto_inspector.go`): tracks intra-function `hmac.New` and `.Sum(...)` / encoded digest provenance alongside security-sensitive identifiers, flagging `bytes.Equal`, `strings.EqualFold`, and `==`/`!=` with guidance recommending `hmac.Equal` or `subtle.ConstantTimeCompare`. Excludes `go/token` selectors (`token.*`), AST metadata and identifier-name fields (`.Tok`, `.Kind`, `.Op`, `.Name`), import alias variables (`*Alias`), local lookup keys built by `+` concatenation from non-sensitive parts (`path + "#" + sym`) unless they carry HMAC digest provenance, constant literals and `[]byte("...")` magic-header casts, `Default*` config sentinels, `strings.TrimPrefix` unchanged checks, and non-crypto content/cache hashes (`SourceHash`, `ContentHash`, `OriginalHash`, `CurrentHash`).
- **Unfinished SQL transactions** (`core/analysis/safety_checks.go`): checks `Begin` and `BeginTx` variables across statement control flow after the initial `Begin` error guard, flagging early `return` paths before `Commit()` when neither `defer tx.Rollback()` (direct or closure wrapper) nor an explicit branch `tx.Rollback()` precedes the return. Ignores factory helpers returning `tx` directly and non-SQL `Begin` methods.
- **`testing/synctest` bubble boundary capture** (`core/analysis/testing_inspector.go` + `core/analysis/pipeline.go`): on `_test.go` files importing `testing/synctest`, builds a lexical scope model to flag outer-scope `chan`, `*time.Timer`, and `*time.Ticker` bindings referenced inside `synctest.Test` or `synctest.Run` closures (including nested goroutines/closures and aliased imports) while respecting inner shadowing and skipping unrelated `context_background_in_func` / `unbounded_goroutine` warnings on `_test.go` files.

### Dual-corpus accuracy and latency benchmark

Measured on 2026-11-18 with `RunPackageAnalyzersJSON` across all non-vendor Go packages, and re-measured on 2026-11-20 after removing the remaining identifier-name false positives (every directory with `.go` files, skipping hidden, `vendor` and `testdata` directories):

| Corpus | Packages | Baseline Total Diags | Rebuilt Total Diags | Total Time | Median / Pkg | p95 / Pkg | Max / Pkg | Audited Findings (New/Refined Rules) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `velo/core` | 27 | 628 | 247 | 150.5 ms | 4.97 ms | 14.20 ms | 18.48 ms | 0 Path Traversal (0 FP), 0 Timing MAC (0 FP, down from 245 baseline FPs), 0 SQL Tx (0 FP), 0 Synctest (0 FP) |
| `lms-saas/backend` | 60 | 681 | 248 | 111.0 ms | 1.01 ms | 9.77 ms | 11.93 ms | 0 Path Traversal (0 FP), 2 Timing MAC/Digest true positives (`internal/features/auth/handler.go:1380`, `internal/features/speaking/chat_audio_share.go:59`; 0 FP), 0 SQL Tx (0 FP), 0 Synctest (0 FP), 0 redundant modernization (down from 355) |

Both corpora complete far under the 200 ms/package median budget with 0 false positives audited across the 4 rebuilt checks and 2/2 true security hits in `lms-saas/backend`.
