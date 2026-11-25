# GoLens Memory Model

Status: proposal for owner review · Audit date: 2026-10-30 (Asia/Saigon) · Scope: GoLensApp process (Swift/AppKit + embedded Go runtime via `libgoagent.dylib`) and its `gopls` child.

Goal: GoLens uses memory deliberately. Every byte has one owner, every cache has a number, and every per-keystroke path costs O(edit), not O(document). The comparison point is GoLand (JVM `-Xmx2048m`, 512 MB code cache, typically 1.5–3 GB RSS, figures supplied by the owner).

Legend used in every table:
- **[M]**: measured in this audit (the command and machine are in §4.1 and Appendix A).
- **[E]**: estimate derived from code reading. Verify it before using it as a gate.
- **[S]**: taken from an external source (URL in §8).

Line numbers refer to the tree as of 2026-10-30. `WorkspaceState.swift` was being edited at the same time, so its references give the function name as well as the line.

---

## 1. Baseline

| Item | Value | Kind |
|---|---|---|
| GoLensApp `phys_footprint`, small project (`~/GolandProjects/GoLensGoApp`, 5 `.go` files), 1 file open | 70 MB steady, 140 MB peak | [M] owner |
| Same process today, read with `footprint -p` | 67 MB: MALLOC_SMALL 40 MB dirty, untagged VM_ALLOCATE 5.9 MB (Go heap/arenas live here), CG image 4.2 MB, MALLOC_LARGE 3.1 MB, `__DATA*` 5.5 MB, CoreAnimation 1.8 MB | [M] |
| `gopls serve` child | 73 MB RSS | [M] owner |
| `gopls ** telemetry **` grandchild (x/telemetry crash monitor, started unless the user's telemetry mode is `off`) | 6–9 MB RSS | [M] + source `x/telemetry/start.go:144-176` |
| `gopls stats`, GoLensGoApp (74 packages, 622 compiled files incl. deps) | peak footprint 124 MiB; HeapAlloc 150 MiB transient | [M] |
| `gopls stats`, gopls v0.24.0 module (660 files, 178 workspace / 878 total packages) | cold: 697 MiB peak (731 MB); warm cache: 179–275 MiB; `GOMEMLIMIT=256MiB`: 142 MiB; `128MiB`: 115 MiB (+60 % wall time) | [M] |

Takeaway: steady-state GoLens is small. The **140 MB peak and the per-keystroke churn** are what need fixing. Both come from O(document) work on hot paths (§2). gopls is the dominant consumer on anything bigger than a toy project, and today it runs with no limit at all.

---

## 2. Current-state audit

### 2.1 What happens on one keystroke today (active file, N bytes)

```
NSTextView edit
 ├─ textDidChange (MacTextView.swift:453)
 │   ├─ parent.text = textView.string             → writes WorkspaceState.openFilesContent[path] (NativeEditorView.swift:32)
 │   │     └─ @Observable invalidation → NativeEditorView.body → MacTextView.updateNSView (MacTextView.swift:75)
 │   │           ├─ textView.string != text         full compare, up to 4.5 ms @100 KB [M]   (:95)
 │   │           ├─ remove + re-add underline attrs over the WHOLE document                  (:173-199)
 │   │           └─ diagnosticsForPath → resolvingSymlinksInPath per key on miss  (WorkspaceState.diagnosticsForPath ~:396)
 │   ├─ lspQueue: text.withCString → NotifyFullChange   UTF-16→UTF-8 transcode: N-byte malloc, 1.4 ms @100 KB [M] (:460-468)
 │   │     Go: C.GoString(N) → []byte(N) → buildLineStarts([]byte(text)) (another N) → JSON didChange (escaped N) → pipe
 │   │         = 468 KB allocated, 120 µs @100 KB; 5.9 MB @1 MB [M]           (main.go:286, lsp/client.go:491-518)
 │   ├─ scheduleFoldableUpdate (+300 ms): components(separatedBy:) + Array(line) of Character (16 B/char) ≈ 16×N transient [E] (WorkspaceModels.swift:345-353)
 │   ├─ scheduleHighlight (+150 ms) → applyHighlighting (:247)
 │   │     ├─ text == lastHighlightedText, cachedSemanticHighlightsText == liveText, textView.string == textCopy:
 │   │     │     3 full compares, each up to 4.5 ms @100 KB / 45 ms @1 MB [M]           (:237, :275, :363)
 │   │     ├─ EnsureFileOpen(path, WHOLE TEXT) on every pass, even when already open: N transcode + N C.GoString copy (:254, main.go:357)
 │   │     ├─ tree-sitter parse(tree: oldTree, string:) with no tree.edit() → no incremental reuse (SyntaxHighlighter.swift:57-65)
 │   │     ├─ reloadCodeLens → findGoDeclarations (components) + `git blame` process + one textDocument/references PER func decl
 │   │     │     (WorkspaceState.reloadCodeLens ~:872, getGitAuthors ~:905)
 │   │     └─ GetSemanticTokens (full document): see 2.3
 │   └─ triggerCompletionQuery (+150 ms): substring(to: caret).components(separatedBy:) (WorkspaceState+LSP.swift:26-27)
 ├─ textViewDidChangeSelection → lineAndCol: substring(to:) + components(separatedBy: .newlines)
 │     up to 4 ms @100 KB, 43 ms @1 MB, one String per line [M]   (MacTextView.swift:564 → GoLensTextView.swift:452-460)
 │     + updateBracketHighlighting → findMatchingBracket: one NSString substring PER SCANNED CHARACTER (MacTextView.swift:769-822)
 └─ drawBackground (every frame): layoutManager.ensureLayout(for:) on the WHOLE container (GoLensTextView.swift:899)
       + substring(to: visibleCharRange.location) + utf8 walk of the prefix (:950)
```

The incremental-sync architecture rule is **not implemented**. `NotifyIncrementalChange` exists in Go (`lsp/client.go:440`), but Swift never calls it. Every edit goes through `NotifyFullChange` (MacTextView.swift:103, :465; WorkspaceState.saveActiveFileAndFormat). This is the largest single violation and also the largest hotspot.

Correction to a common assumption [M]: on macOS 26, reading `textView.string` is **not** an O(n) copy. Bridging takes about 0.2 µs, and holding a snapshot while editing retains only 10–18 KB (NSTextStorage's string storage is chunked and copy-on-write). The memory and CPU go elsewhere: into **walking** bridged strings (`==`, `components`, `withCString`, `utf8` iteration, `substring(to:)`), which costs about 15 ns per UTF-16 unit and allocates proportionally.

### 2.2 Inventory: everywhere text or large data is copied or retained

**A. Swift document text and rendering**

| # | Location | What | Kind |
|---|---|---|---|
| A1 | `WorkspaceState.swift` `openFilesContent: [String: String]` (~:238) | A Swift copy of every open file, held in an `@Observable` dictionary and rewritten on every keystroke (`NativeEditorView.swift:32`, `MacTextView.swift:455`). Background tabs hold a native UTF-8 String (N bytes). Each write invalidates every view that reads the dictionary. | retained + churn |
| A2 | `MacTextView.swift:63, :98` | `textView.string = text` replaces the whole NSTextStorage (UTF-16, 2N) on every tab switch, and also when SwiftUI pushes a stale binding. There is a single NSTextView per pane, reused across tabs. | churn, full relayout |
| A3 | `GoLensTextView.swift:899` | `ensureLayout(for: textContainer)` in `drawBackground` forces glyph and line-fragment layout for the **whole** document, which defeats non-contiguous layout. A full layout copy measured 0.9 MB @100 KB and 9 MB @1 MB at 2.5 pt [M]. | retained |
| A4 | `MinimapView.swift:194-237` | A second NSTextStorage and full layout of the same document, plus `setAttributes` over the full range on every sync (300 ms after each typing pause). | retained ≈ A3 again |
| A5 | `MacTextView.swift:214, 220`, `GoLensTextView.swift:48`, `SyntaxHighlighter.swift:13` | `lastHighlightedText`, `cachedSemanticHighlightsText`, `cachedLineStartsText` and `currentText` are four snapshots kept only for equality checks. Retention is small [M]; the cost is the O(N) compares in A6. | CPU |
| A6 | 44 `components(separatedBy:)` calls in desktop/. Hot ones: `GoLensTextView.swift:457` (caret), `:876` (getLineText), `WorkspaceState+LSP.swift:27` (completion), `WorkspaceModels.swift:349` (folding), `WorkspaceState.findGoDeclarations`, `WorkspaceState+FileSys.swift:100` (jumpTo) | Each call allocates one String per line, 1–2×N per call [E]. | churn |
| A7 | `MacTextView.swift:769-822`, `GoLensTextView.swift:463-479, 681-700` | One `NSString.substring` allocation per scanned character (bracket match, word range). Runs on the main thread with no autorelease pool. | churn |
| A8 | `SyntaxHighlighter.swift:180, 187` | `builtins` and `dockerKeywords` array literals plus an `uppercased()` String are allocated per identifier node. `textSubstring` uses `utf8.index(offsetBy:)`, which is O(N) per node. | churn |
| A9 | `SyntaxHighlighter.swift:204` vs SwiftTreeSitter `Encoding+Helpers.swift:29` | Tree-sitter parses UTF-16LE, so `byteRange` is in UTF-16 *bytes*. The code treats it as UTF-16 *units* (a 2× error), and builds `targetByteRange` in UTF-8 bytes (:43-51). Units are inconsistent, so the visible-range pruning of the walk does not prune. The first parse makes a full `string.data(using: .utf16)` copy (SwiftTreeSitter `Parser.swift:103`). | correctness + churn |
| A10 | `MacTextView.swift:46`, no `undoManager(for:)` anywhere | One NSTextView is shared by all tabs, so undo actions for file A survive a switch to file B. `NSUndoManager.levelsOfUndo` defaults to 0, which means unlimited [S]. | unbounded + wrong-document undo |
| A11 | `WorkspaceState.saveActiveFileAndFormat` (~:821) | `textView.string = finalText` replaces the whole storage after gofmt, then sends another full `NotifyFullChange`. | churn |

**B. CGO boundary**

| # | Location | What | Freq |
|---|---|---|---|
| B1 | `main.go:286` `NotifyFullChange` | Full text crosses the boundary on every keystroke (see 2.1). | per key |
| B2 | `main.go:357` `EnsureFileOpen` | Full text crosses the boundary on every highlight pass, only to check a map key. | per pause |
| B3 | `main.go:337-341` `GetSemanticTokens` | Returns JSON `[{"start","len","type"}]`: 33.5 B/token [M] (67 KB per 2k tokens, 690 KB per 20k). C.CString copies it again. In Swift it becomes `String(cString:)` → `Data` → `JSONDecoder`, and the token range is re-derived by walking UTF-8 (`MacTextView.swift:325-360`). | per pause |
| B4 | `main.go:327-335` `GetGoCompletions` | Raw LSP `result` JSON, documentation included for every item, with no cap. That is 4 copies: RawMessage→string→C.CString→String→Data (`WorkspaceState+LSP.swift:81-82`). Measured payload: 151 KB for 500 items [M]. | per key (150 ms) |
| B5 | `main.go:57-65`, `lsp/client.go:171-219` | Diagnostics: `map[string]any` tree → `[]map[string]any` → JSON → C.CString → Swift String → Data → `[DiagnosticData]`, which gets a fresh `UUID` per item on every publish. | per publish |
| B6 | `main.go:67-73` + `lsp/client.go:154` | Every server response that Go is not waiting for is forwarded whole to Swift, which re-parses it with `JSONSerialization` (`LSPClient.swift` `handleIncomingResponse`). | per Swift request |
| B7 | `agent.go:83`, `WorkspaceState.swift` `goTerminalCallback` (~:1087) | PTY bytes → C.CString (truncates at NUL, splits UTF-8 across 4 KB reads) → `String(cString:)` → `Array(utf8)` → `feed`, so 3 copies per chunk. | per PTY read |
| B8 | `main.go:47-55` `bridge.Log` | Each log line is a malloc/free round trip. `GOPLS (Raw)` logs every server notification body (`lsp/client.go:221`). dlv runs with `--log=true --log-output=dap` (`dap/client.go:90`), so every DAP message is mirrored into the log. | high under load |
| B9 | `C.CString` discipline | Every `char*` that Go returns is freed by Swift through `FreeGoCString`. Checked: the WorkspaceState+Build, +LSP and +Testing files, RenameSymbolPopupView and DebugSplitPane. No leak was found. The cost is churn, not leaks. | n/a |

**C. Go core (inside the app process)**

| # | Location | What |
|---|---|---|
| C1 | `lsp/client.go:440-461` | The incremental path allocates a new N-byte buffer and rebuilds all `LineStarts` (`[]int`, 8 B/line) on every edit: 33 µs and 120 KB @100 KB; 357 µs and 1.2 MB @1 MB [M]. An in-place splice with a LineStarts patch costs 0.7 µs and 0 B [M]. |
| C2 | `lsp/client.go:126` `readLSPOutput` | Every gopls message is decoded into `map[string]any` before routing. A 20k-token semantic response costs 14.6 MB and 200k allocations (11 ms); a typed envelope costs 2.2 MB and 31 allocations (3 ms) [M]. |
| C3 | `lsp/client.go:363, 498` | `buildLineStarts([]byte(text))` converts the text a second time. `fileBuffers[path] = []byte(text)` is a third copy after `C.GoString`. |
| C4 | `lsp/client.go:491-500` + `WorkspaceState+FileSys.swift:174-180` | **Leak race.** `NotifyFileClose` runs synchronously on the main thread, but `NotifyFullChange` is queued on `lspQueue`. A queued change that runs after the close executes `fileVersions[path]++` and `fileBuffers[path] = text`, which resurrects the buffer for a closed file permanently and sends `didChange` for a document gopls already closed. |
| C5 | `lsp/client.go:366-376` | `languageId: "go"` is hard-coded, and `openFile` sends **every non-binary file** (README.md, YAML, JSON) to gopls as Go source (`WorkspaceState+FileSys.swift:153-163`). gopls then builds bogus packages, diagnostics and caches for them. There is also no file-size cap. |
| C6 | `lsp/client.go:61-96, 248-319` | gopls is spawned in `InitEditor` at app start, even when no project is open. `OpenWorkspace` sends a **second `initialize`** to the same process when switching projects. gopls rejects it (`gopls/internal/server/general.go:57`), so the first workspace's view stays resident and the new project is served by ad-hoc views. gopls is never shut down. |
| C7 | `lsp/client.go:30, 556-585` / `LSPClient.swift:137-158` | Go request IDs start at 1, Swift IDs at 1000, and both share one gopls ID space. Responses and server→client requests are routed only by `id`. When IDs collide, a Swift continuation is never resumed. Swift continuations have **no timeout**, so they and their captured state leak forever. |
| C8 | `lsp/client.go:826-863` | `buf` is read before the request and `lineStarts` after it. An edit in between mixes two document versions (wrong offsets). |
| C9 | `agent.go:49-89, 118-131` | `CloseTerminal` closes the PTY but never `Wait()`s, which leaves a zombie per session. The reader goroutine blocks in `Read` until EOF. Swift **never calls `CloseTerminal`** (see D4). |
| C10 | `testutil/test_parser.go:31-50` | `DiscoverTests` walks the whole tree **in-process** and parses every `_test.go` with `ParseComments` into one shared FileSet. Position tables are retained for the whole walk, so the transient heap is O(total test bytes) inside the app [E]. |
| C11 | `dap/client.go:276-328` | On the `stopChan` path the `pending[seq]` entry is never deleted. This is minor. |
| C12 | `runner/runner.go:78-89` | `bufio.Scanner` uses the default 64 KB token limit. A longer output line stops the scanner silently, and the pipe then backs up (correctness). Each line is one bridge.Log FFI call (B8). |
| C13 | No `debug.SetMemoryLimit`, `runtime/metrics` or pprof hook anywhere in core | The embedded runtime cannot be observed from the app. |

**D. Swift observable state, caches, lifecycle**

| # | Location | What | Bound today |
|---|---|---|---|
| D1 | `WorkspaceState+Build.swift:165-171` | `logs` **and** `consoleOutput` hold the same lines in two arrays. The cap is 2,000 entries with no byte cap (a single gopls log line can be hundreds of KB). Trimming copies the array (`Array(suffix(1000))`). | 2,000 entries each |
| D2 | `WorkspaceState.diagnostics` + `updateFlatDiagnostics` (`+FileSys.swift:84-93`) | Diagnostics for every file gopls reports (workspace-wide, closed files included). `flatDiagnostics` is fully rebuilt and sorted on every publish. | none |
| D3 | `LSPState.completions` (`SubStates.swift:40`) | The full decoded list, documentation strings included. | none |
| D4 | `ConsoleView.swift:175-182` | Closing a terminal tab removes only the session. `terminalEngines[id]` (`WorkspaceState.swift` ~:278) keeps the SwiftTerm view and scrollback alive, and the zsh process, PTY, Go goroutine and 4 KB buffer all stay alive. **Leak per closed terminal.** SwiftTerm scrollback is left at its 500-line default (`TerminalOptions.swift:223`). | leak |
| D5 | `closeFile` (`+FileSys.swift:174-193`) | Clears `openFilesContent` and sets `diagnostics[path] = []`, which leaves the key behind. It never clears `codeLensCache`, `foldableRanges`, `foldedRanges`, `foldedCharRangesCache`, `fileEditorModes` or `markdownPreviewMode`. | grows with every file ever opened |
| D6 | `ImagePreviewView.swift:15, 56` | `NSImage(contentsOfFile:)` runs inside `body`, so the image is re-decoded on every SwiftUI re-render (the view observes all of WorkspaceState) and once more in `onAppear`. There is no downsampling. A 4000×3000 PNG is about 48 MB decoded [E]. | none |
| D7 | `WorkspaceState+Git.swift:186` | `git status --porcelain` output, `changedFiles`, `statusMap` and `changedFolderPaths` are uncapped. `resolvingSymlinksInPath` runs per line. | none |
| D8 | `WorkspaceState.swift:124` `navigationHistory` | Appended on every file switch. | none (recentFiles is capped at 50) |
| D9 | `WorkspaceState+Search.swift:138-238` | Bounded already (500 matches, 1 MB file limit). The long detached loop has no `autoreleasepool`, so Foundation temporaries accumulate until the search finishes. | good caps |
| D10 | `InlayHintManager.swift:22, 101-153` | Capped at 100 (good). It recreates up to 100 `NSTextField` subviews on every layout pass (50 ms after scroll), and each one calls `characterIndex(forLine:)`, which triggers the A5 compare. | 100 |
| D11 | `GoLensTextView.swift:130` | `boundsDidChangeNotification` is observed with `object: nil`, so every view bounds change in the app calls every editor (CPU). | n/a |
| D12 | Retain-cycle review | `activeTextView`, `minimapDelegate`, `InlayHintManager.textView` and the Sub-state `workspace` references are all `weak` (good). `FileSystemWatcher` uses `passUnretained` plus `[weak self]` (good). `codeLensLoadTask` captures `textView` strongly in a Task stored on the singleton, so the last editor is retained until the next reload (minor). `terminalEngines` is a strong dictionary (D4). No true cycles were found. | |

### 2.3 Ranked hotspots (bytes × frequency)

Scenario: one active 100 KB Go file (about 1,600 lines, about 2,000 semantic tokens), typing at 5 keys/s. Figures at 1 MB are in brackets.

| Rank | Hotspot | Cost per event | Event rate | Churn / retained | Evidence |
|---|---|---|---|---|---|
| 1 | Full-text sync per keystroke (B1, C3) | Go 468 KB + Swift 100 KB transcode + pipe ≥100 KB; 1.5 ms CPU [M] (1 MB: 5.9 MB + 1 MB, 16 ms) | 5/s | ≈3.5 MB/s churn (≈35 MB/s); drives Go GC cycles and gopls JSON decode | MacTextView.swift:460-468, lsp/client.go:491-518 |
| 2 | Highlight pass: 3 full compares + EnsureFileOpen + codelens (A5, B2, D-codelens) | 3×4.5 ms + 1.4 ms + 200 KB copies; `git blame` fork; K references requests (K = func decls) [M]/[E] | each pause (≈2/s while typing) | 0.5–1 MB/pass in GoLens; gopls references fan-out is the main gopls CPU and heap driver while editing [E] | MacTextView.swift:236-297, WorkspaceState.reloadCodeLens |
| 3 | Caret/line math via `components` (A6) + bracket scan (A7) | up to 4 ms and about 1.5×N allocations per caret move [M]/[E] | 5–30/s (typing, arrows) | 1–3 MB/s churn | GoLensTextView.swift:452-460, MacTextView.swift:769 |
| 4 | Folding parse with Character arrays (A6) | ≈16×N = 1.6 MB transient [E] (16 MB) | each pause | spike contributor to the 140 MB peak | WorkspaceModels.swift:345-353 |
| 5 | Forced full layout + minimap duplicate (A3, A4) | retained ≈9×N per copy [M]: 0.9 MB ×2 (9 MB ×2) | resident | largest **retained** per-document cost in GoLens | GoLensTextView.swift:899, MinimapView.swift:194 |
| 6 | Semantic tokens via JSON and `map[string]any` (B3, C2) | ≈1.5 MB envelope + 67 KB JSON ×3 copies + decoder (≈14.6 MB at 20k tokens) [M] | each pause | GC pressure in the embedded runtime | lsp/client.go:126, 826-929 |
| 7 | SwiftUI invalidation per keystroke (A1) | updateNSView: full compare + full-range attribute strip and reapply | 5/s | CPU; repeated attribute dictionaries | NativeEditorView.swift:27-33, MacTextView.swift:95-199 |
| 8 | Completions (B4, D3) | ~150 KB payload ×4 copies + decode 0.77 ms per 500 items [M] | per key (150 ms) | up to about 0.6 MB per request | WorkspaceState+LSP.swift:20-126 |
| 9 | Leaks: terminals (D4, C9), buffer resurrection (C4), Swift continuations (C7), stale gopls view (C6), per-path caches (D5) | 1–5 MB per closed terminal + a zsh process [E]; N per resurrected file; a whole gopls workspace per project switch | per user action | **unbounded growth over session length** | see rows |
| 10 | gopls fed non-Go files and unlimited (C5, C6) | bogus packages; unlimited heap; cold peak 731 MB for a 660-file module [M] | per open | dominant total-system cost | lsp/client.go:366, settings |

---

## 3. Target memory model

### 3.1 Ownership: one authoritative copy per document per layer

| Layer | Owns | Encoding | Lifetime |
|---|---|---|---|
| **Go `FileBuffer`** (core/lsp) | The **document model** for every open file: `Content []byte`, `LineStarts []int32`, `Version uint32`, `NonASCII bool` | UTF-8, `\n`-normalized per RULES §2 | didOpen → didClose. This is the only copy for background tabs. |
| **Swift NSTextStorage** | A **rendering copy** for *visible* editors only (one per pane), plus an optional MRU of 2 hidden tabs to make switching instant | UTF-16 (AppKit requirement) | Created when a tab becomes visible and freed when the tab leaves the MRU. Rebuilt from Go with one copy. |
| **gopls** | Its own file contents, ASTs and types (separate process, unavoidable) | UTF-8 | Fed only by incremental `didChange`. Released on `didClose`; the process ends at `shutdown`/`exit`. |
| Swift observable state | Metadata only: path, `version`, `isDirty`, caret, diagnostics summary | — | **Never** a `String` containing document text |

Edit flow, with no full-text copies:

```
NSTextStorage edit (textStorage(_:didProcessEditing:range:changeInLength:))
  → Swift: UTF-16 range → UTF-8 byte offsets via NonASCIIIndex (O(1) for ASCII files, O(log k) otherwise)
  → NotifyEdit(docID, startByte, endByte, ptr, len, baseVersion)        // only the replacement bytes cross
  → Go: FileBuffer.Splice in place (0 alloc, 0.7 µs @100 KB [M]) → patch LineStarts → version++
  → Go: didChange{range (UTF-16 line/char computed from LineStarts, gopls v0.24 is UTF-16-only), text}
```

- **NonASCIIIndex** (Swift, per visible document): a sorted `[Int32]` of the UTF-16 positions whose UTF-8 width differs, with prefix sums of the extra bytes. It is updated incrementally from the edit range and delta, and is empty for ASCII-only files, which is most Go code. It costs 8–12 B per non-ASCII character. This keeps RULES §1 intact: Swift sends byte offsets and never computes line or character numbers for sync.
- The reverse direction (byte → UTF-16, for semantic tokens and diagnostics coming from Go) uses the same index.
- Opening a file: Go reads it from disk (`os.ReadFile`), creates the FileBuffer and sends `didOpen`. Swift asks Go for the bytes once (`CopyDocument(docID, dst, cap)` into a Swift-allocated buffer) and builds the NSTextStorage. Today the file is read by Swift and then copied into Go; after the change, Swift makes 1 copy instead of Go making 3.
- Save: Go writes its own buffer to disk, so no text crosses the boundary. Formatting returns **edits** (a `textDocument/formatting` TextEdit list); Swift applies them as ranged `replaceCharacters` calls, which keeps undo and avoids a full relayout.

### 3.2 CGO boundary contract

1. **No full-document transfer** except open, reload-from-disk and explicit "replace all". Per-keystroke traffic is O(edit) bytes.
2. **Hot-path results are packed binary arrays, not JSON**:
   - Semantic tokens: `[start u32, len u32, type u16 | mods u16]` = 12 B/token, compared with 33.5 B JSON [M]. Encoding costs 0.78 µs and 0 allocations per 2k tokens, against 160 µs and 74 KB for JSON [M].
   - Diagnostics, folding ranges and inlay hints: a packed fixed-size record table plus one UTF-8 string arena (`offset u32, len u32` per message).
   - Low-frequency, schema-rich payloads (rename, code actions, DAP variables) may stay JSON.
3. **Ownership rules, documented per exported function** in a table next to `GoLens-Bridging-Header.h`:
   - *Swift → Go inputs*: `(const uint8_t* ptr, size_t len)` is valid **only for the duration of the call**. Go copies what it keeps (`C.GoBytes` or a copy into FileBuffer). There are no NUL-terminated strings for document or terminal data. Use `String.withUTF8` (zero-copy for native Swift strings).
   - *Go → Swift results, pattern A (caller buffer)*: Swift passes `(dst, cap)`. Go writes into it and returns the length needed; if `cap` was too small, Swift retries once. Swift owns the memory and can reuse it, with no free call.
   - *Go → Swift results, pattern B (callee buffer)*: Go returns a `GoLensBuf{ptr, len}` allocated with `C.malloc`. Swift wraps it as `Data(bytesNoCopy:count:deallocator: .custom { FreeGoBuffer($0) })`, so it is freed exactly once.
   - *Go → Swift callbacks*: Go passes `(ptr, len)` pointing to Go memory (allowed by cgo for the duration of the call if that memory contains no Go pointers [S]). Swift must copy or consume it **before returning** and never stores the pointer.
   - **Never hold a Go pointer in C beyond the call.** Use `runtime.Pinner` only if a buffer must outlive a call [S], and prefer C.malloc buffers when that is needed.
4. **C.CString churn**: `C.CString` costs 61 ns at 64 B and 33 µs at 1 MB [M]. Passing pinned Go memory costs about 15 ns at any size [M]. Paths are interned once: Swift gets a `docID uint32` from `OpenDocument` and passes it instead of the path string on every call.
5. **Buffer reuse**: Go keeps one reusable scratch buffer per result type (`[]uint32` tokens, `bytes.Buffer` for LSP framing) owned by the single LSP goroutine. `sync.Pool` is used only where buffers cross goroutines.
6. Every `char*`/`GoLensBuf` export has exactly one free path. A unit test lists exports and fails if a returning export has no documented free function.

### 3.3 Go runtime inside the app

- **Memory limit**: in `InitGoLensCore`, if `GOMEMLIMIT` is unset, call `debug.SetMemoryLimit(384 << 20)`; this is the only place the host core sets it. This is a guard, not a target: the steady Go heap budget is ≤ 16 MB. Keep `GOGC=100`; the live heap is small, so the default heap goal (2× live) is cheap. The guard sits well above the steady heap because transient bursts (for example large git output on a big repository) are live heap: a guard below them makes the GC run nonstop without freeing anything. Do not add periodic `debug.FreeOSMemory`; the runtime scavenger already returns memory. Two intentional exceptions trigger `debug.FreeOSMemory` once in the background: (1) `database.CloseResult` when closing a query result that spilled to disk, where the heap goal stays at its Fetch All peak until the next collection, and (2) `usageindex` when releasing retained `go/types` package trees after the 25 s idle period (`armIdleLocked`) or when `Service.Open`/`Close`/`SetEnabled` drops a workspace that still retains loaded types. Let `GODEBUG=gctrace=1 make run` override for diagnosis.
- **No `map[string]any` on hot paths.** Use a typed envelope `{id *json.RawMessage, method string, result/params json.RawMessage}`, then decode only the needed type (−85 % bytes, −72 % time measured for the token response).
- **string ↔ []byte**: the document lives as `[]byte`. Use `unsafe.String` only for read-only views that do not outlive the call (e.g. JSON encode of an edit fragment). Never retain views of C memory.
- **Capacity hygiene**: FileBuffer grows with 25 % headroom and shrinks when `cap > 2×len && cap > 64 KB`. LineStarts is `[]int32`, half of today's `[]int` (8 B/line).
- **Arena-like reuse** is justified for semantic token conversion and LSP frame encoding, because those are per-request scratch buffers. It is not justified for FileBuffer.
- **Goroutines**: each one has an owner and a stop path. Per child process that means one reader plus one `Wait()`. `runtime.NumGoroutine()` is exported in metrics.
- **Observability exports** (debug builds): `GoLensRuntimeStats(dst *C.uint64_t, n C.int)` reads `runtime/metrics` (`/memory/classes/total:bytes`, `/memory/classes/heap/objects:bytes`, `/gc/cycles/total:gc-cycles`, `/gc/heap/allocs:bytes`, `/sched/goroutines:goroutines`) [S]. `GoLensWriteHeapProfile(path)` uses `runtime/pprof`. There is no in-app HTTP server.

### 3.4 Swift

- **No document text in value-type state.** Remove `openFilesContent`. Make `isDirty`/`version` the observable signals. A `String` assigned into an `@Observable` property is a whole-object invalidation even when copy-on-write keeps the copy cheap.
- **NSTextStorage editing**: only ranged `replaceCharacters(in:with:)` inside `beginEditing`/`endEditing`. `textView.string =` is banned outside first load.
- **Lazy, visible-range work**: set `layoutManager.allowsNonContiguousLayout = true` [S] and remove `ensureLayout(for:)` from `drawBackground`. Gutter numbers come from an incremental `[Int32]` line-start index (UI-only, so it is not covered by the RULES §1 sync ban), shared by caret, gutter, inlay hints and jump-to-line.
- **Document version counters replace equality checks**: `lastHighlightedVersion == version`, never `text == lastHighlightedText`.
- **No `components(separatedBy:)`, `substring(to:)` or `Array(line)` on documents.** Scan `NSString` with `getCharacters(_:range:)` into a reused stack buffer, or use `enumerateSubstrings(in:options: .byLines)` over the dirty range only.
- **`autoreleasepool {}`** goes around every per-item body in long loops: project search per file, folding per chunk, git output parsing, minimap tile rendering [S].
- **Weak references**: keep the current `weak` discipline. Tasks stored on the singleton capture `[weak textView]`.
- **Bounded caches**: `NSCache` with a `totalCostLimit` [S] (cost = decoded bytes) for image previews, file icons and minimap tiles. Purge it on `NSApplication.didResignActive` when there is memory pressure (`DispatchSource.makeMemoryPressureSource`).
- **Per-tab state**: a single `DocumentSession` object per open path owns undo manager, folds, codelens, editor mode and diagnostics. `closeFile` drops the object. Background tabs past the MRU release their NSTextStorage and tree-sitter tree.
- **Undo**: one `UndoManager` per document through `NSTextViewDelegate.undoManager(for:)` [S], with `levelsOfUndo = 500` and typing coalesced. It is destroyed on close.
- **Images**: decode once with `CGImageSourceCreateThumbnailAtIndex` (max pixel size = 2× view size) [S], never in `body`.
- **Terminal**: on tab close call `CloseTerminal`, remove `terminalEngines[id]` and nil the delegate. The PTY callback delivers `(ptr,len)` bytes straight to `feed(byteArray:)`, with no String round trip.

### 3.5 gopls

| Policy | Setting / action | Source / rationale |
|---|---|---|
| Spawn lazily | Start gopls on workspace open, not in `InitEditor` | idle budget = 0 MB gopls |
| One per workspace | Switching projects sends `shutdown` → `exit`, waits ≤ 2 s, kills on timeout, then starts a new process with the new `rootUri` | gopls rejects a second `initialize` (`general.go:57`) |
| Shutdown on close | Same sequence on workspace close and app quit; `cmd.Wait()` reaps the process | no orphans (process rules) |
| Soft memory limit | `memoryLimit` setting (bytes): small 256 MiB, large 1 GiB. Fallback for gopls < v0.24: `GOMEMLIMIT` in `goplsCmd.Env` | gopls settings doc [S]. At 256 MiB, measured peak dropped from 179–275 MiB to 142 MiB with no time penalty; at 128 MiB it dropped to 115 MiB with +60 % time [M] |
| Workspace scope | `directoryFilters`: default `["-**/node_modules"]` plus user-configurable entries (e.g. `-**/bazel-*`, generated trees). `expandWorkspaceToModule: false` when a sub-directory of a large module is opened | gopls settings doc [S]: workspace packages are re-diagnosed after edits |
| Only Go documents | `languageId` by extension: `go`, `go.mod`, `go.work`, `go.sum`, `tmpl`. Never send other files | C5 |
| Semantic tokens | `textDocument/semanticTokens/range` for the visible range ± 1 screen (server support verified in `gopls/internal/server/semantic.go:22`). Keep `semanticTokens: true`, as RULES §2 requires Layer 2 | smaller responses |
| Completion payload | `completionDocumentation: false`; fetch docs through `completionItem/resolve` for the selected item (resolveSupport already advertised). Keep `completionBudget` at the 100 ms default | `gopls/internal/settings/settings.go:788-789, 1235` |
| Codelens/references | No per-declaration `references` fan-out on every pause. Compute usage counts lazily (hover or visible declarations only), cache them per document version, cap at 50 requests per file | rank 2 |
| Diagnostics | Defaults (`diagnosticsDelay` 1 s). Offer `diagnosticsTrigger: "Save"` for very large workspaces (experimental) | settings doc [S] |
| Telemetry child | Leave it alone. It is the user's global `gopls telemetry`/`go telemetry` choice (6–9 MB). Document it in the budgets | `x/telemetry/start.go:151` |
| Known characteristics | Since v0.12, memory is proportional to open packages plus their direct imports, and per-package results are kept in an on-disk cache. Typed syntax trees are about 30× source size. Cold loads and edits that invalidate widely-imported packages spike the heap, which is why the soft limit matters | go.dev/blog/gopls-scalability [S]; `memoryLimit` doc text [S] |
| Fix setting names | `ui.inlayHints` resolves to `inlayHints`, which is not a gopls setting; it must be `hints`. gopls uses only the last dotted segment (`settings.go:1031-1038`) | correctness |

### 3.6 Bounded structures (each cap has a number)

| Structure | Cap | Rationale |
|---|---|---|
| Console/log ring (one store, not two arrays) | 2,000 lines **and** 1 MiB; each line truncated at 4 KiB with a "…" marker | About 2 screens of history per KB. Prevents one gopls dump from pinning MBs |
| Program run output | 10,000 lines / 4 MiB ring; the full output can be streamed to a temp file on request | Long-running services |
| `GOPLS (Raw)` / DAP protocol logging | Off by default; on only behind a debug toggle | B8 |
| Terminal scrollback | 1,000 lines per session (set `TerminalOptions.scrollback`). At 120 columns × an estimated ~32 B/cell that is ≈3.8 MB [E]; verify `MemoryLayout<CharData>.stride` | Frugal default, user-raisable |
| Open terminal sessions | 8 | Each one is also a zsh process |
| Diagnostics stored | Open files plus the problems view: ≤ 500 per file, ≤ 5,000 total; message ≤ 1 KiB | gopls publishes workspace-wide |
| Completion list | ≤ 200 items after server-side filtering; documentation lazy | The popup shows about 12 rows |
| Inlay hints | 100 visible (keep) | existing |
| Semantic tokens | Visible range ± 1 screen; one packed array per visible editor | O(viewport) |
| Undo | 500 levels per document; dropped on close | Typing is coalesced, so 500 levels covers long sessions |
| Navigation history | 100 entries | Matches the scale of recent files (50) |
| Swift/Go pending LSP requests | 64 in flight; 5 s timeout, then the continuation resumes with an error | C7 |
| Code-lens references | ≤ 50 per file, cached per version | rank 2 |
| Git status | ≤ 5,000 entries rendered; summary count beyond that; `--untracked-files=normal` | Large monorepos |
| Project search (Go core `search` package) | ≤ 2,000 matches per query, ≤ 100 per file, files ≤ 1 MB, ≤ 100,000 files listed, matched line clipped to 300 bytes; ≤ 8 scan workers, each reusing one read buffer and one lowered copy (≤ 2 × 1 MB); results stream in 30 ms batches; a new query cancels the running scan | Parallel byte scan replaces the serial `String`/`components(separatedBy:)` walk |
| Test results (Swift) | ≤ 20,000 `importPath + test` statuses per workspace; ≤ 500 reported subtests per test; dropped on workspace switch; `go test -json` failure output ≤ 200 lines per test in the core | Last result per test for the navigator and gutter |
| Test marks per file | One `{line → test/row}` map per open `_test.go` document, ≤ 500 table rows per test; released on close | Gutter run/result marks |
| go.mod module notes | Cache ≤ 16 go.mod files (cleared when full), ≤ 500 notes each, keyed by go.mod mtime; errors (offline) are not cached | `go list -m -u` needs the network |
| Inline debug values | One `{line → text}` map for the stopped frame; each value clipped to 60 characters | Replaces per-line substring matching |
| Debugger watches | ≤ 50 expressions per app session (oldest dropped); one result string per watch for the selected frame, cleared on continue | Watch rows in the Debugger tab |
| Debugger variable outline | Children only for expanded rows, loaded on expand and dropped on every pause or frame change; expanded-row keys kept as a set of paths | Lazy `NSOutlineView` items |
| Open file size | > 10 MB: read-only, no LSP, tree-sitter only for the visible window. > 50 MB: refuse with a message (offer to open externally) | gopls and NSTextStorage costs scale with N |
| Hidden-tab NSTextStorage MRU | 2 | Instant switch versus about 2N+layout per tab |
| Image preview cache | NSCache `totalCostLimit` 32 MB; thumbnails ≤ 2× view pixels | D6 |
| Tree-sitter trees | One per visible editor plus the MRU (≤ 3) | |
| File-type icon cache (`FileIconResolver`) | ≤ 2,000 `(path, mtime) → icon` entries for the content/sibling/ancestor rules (cleared when full); content rules read ≤ 8 KB of files ≤ 256 KB; one template `NSImage` per glyph (46) | Rows resolve name/extension rules synchronously; only I/O rules are cached |
| Console run-failure scan | One pass over the console ring (≤ 2,000 lines) when a run exits with an error | Builds the "Build Failed" banner |
| Program run sessions (`WorkspaceState.runSessions`) | ≤ 8 sessions (`maxRunSessions = 8`); each session's output ring is capped at `maxLogLines` (2,000 lines) and `maxLogBytes` (1 MiB); finished sessions are evicted first when full; cleared on workspace switch/close | Supports concurrent multi-binary runs (e.g. server + CLI) with bounded per-session memory |
| Multi-cursor undo stack (`GoLensTextView.multiEditUndoStack`) | ≤ 32 entries per editor view; each entry stores `(union: NSRange, ranges: [NSRange])`; cleared on document switch | Restores individual multi-cursor selections on Undo without leaking across edits |
| Document symbol occurrence highlights (`MacTextView.Coordinator.documentHighlightRanges`) | ≤ 200 `NSRange` entries (`maxDocumentHighlights = 200`); debounced 150 ms on caret move; cancelled and cleared immediately on edit, selection change, or document switch | `textDocument/documentHighlight` read/write occurrence highlighting under caret |
| Code coverage (`WorkspaceState.fileCoverage`, `core/testutil.ParseCoverProfile`) | ≤ 500 files (`maxCoverageFiles = 500`), ≤ 2,000 lines per coverprofile block; cleared on `Clear Coverage` or workspace switch | `go test -covermode=atomic -coverprofile` line and package coverage |
| Time-layout & regex string token highlighting (`SyntaxHighlighter`) | Viewport `targetRange` only, string literals ≤ 2,048 UTF-16 units, zero regex compilation | Sub-token highlighting inside `time.*` and `regexp.*` string arguments |
| `//go:generate` inline lenses (`WorkspaceState.goGenerateLenses`) | ≤ 20 directives per open `.go` file | Inline `Run go generate` code lenses |
| Test CPU & Memory profiles (`WorkspaceState.cpuProfileEntries`, `memProfileEntries`, `core/testutil.ParsePprofFiles`) | ≤ 200 entries per profile (`maxProfileEntries = 200`); temporary `.pprof` files deleted immediately after parsing; cleared on `Clear Profile` or workspace switch | Native gzipped protobuf `pprof` reader for `go test -cpuprofile -memprofile` |
| Benchmark metrics (`WorkspaceState.benchMetrics`) | ≤ 5,000 entries (`maxBenchMetrics = 5000`); cleared on `resetTestState()` or workspace switch | Stores `ns/op · B/op · allocs/op` per benchmark/sub-benchmark |
| Call & Type Hierarchy items (`WorkspaceState.hierarchyItems`) | ≤ 200 items (`maxHierarchyItems = 200`) per hierarchy query | `callHierarchy/*` and `typeHierarchy/*` results in `HierarchyPopupView` |
| Documentation Browser index cache (`core/docs.Service`) | ≤ 4 cached workspace entries (`maxCachedWorkspaces = 4`), LRU-evicted, keyed by canonical `(root, target, stamp)` | Keeps switching between recent projects/targets fast without retaining unbounded AST/search indexes |
| Documentation symbol search (`core/docs`) | ≤ 4 build workers (`maxSearchWorkers = 4`); ≤ 200 ranked results per query (`maxSearchResults = 200`) | Bounds background CPU concurrency and IPC payload size on large `std` + dependency graphs |
| Documentation Browser history (`DocsHistoryStack`) | ≤ 100 entries (`maxEntries = 100`) per Browser window; oldest trimmed on push | Stores route + scroll anchor for `Back` / `Forward` without unbounded growth |

---

## 4. Memory budgets

Budgets apply to `phys_footprint` for GoLens and RSS/footprint for gopls. "Steady" means 30 s after the last action; "peak" means the maximum during the scenario.

| Scenario | GoLens steady | GoLens peak | gopls steady | gopls peak | Today | GoLand (for comparison) |
|---|---|---|---|---|---|---|
| Idle, no project | ≤ 45 MB (provisional; calibrate against measured launch idle) | ≤ 60 MB | **0** (not spawned) | 0 | gopls is spawned at launch [M code] | One JVM: heap cap 2,048 MB + code cache 512 MB; typically 1.5–3 GB RSS (owner) [S: JetBrains memory docs] |
| Small project (≤ 100 files, ≤ 5 tabs) | target 55 MB (best effort, not a gate) | ≤ 90 MB | ≤ 80 MB | ≤ 150 MB (`memoryLimit` 256 MiB) | 70 / 140 MB GoLens, 73 MB gopls [M] | same JVM envelope |
| Medium (~700 files, e.g. the gopls module) | ≤ 80 MB | ≤ 130 MB | ≤ 300 MB | ≤ 400 MB | gopls cold peak 697 MiB, warm 179–275 MiB [M] | same |
| Large (~5k files, Kubernetes-size subtree) | ≤ 120 MB | ≤ 200 MB | ≤ 1.0 GB [E] | ≤ 1.5 GB [E] (`memoryLimit` 1 GiB, scoped `directoryFilters`) | unmeasured; unlimited today | GoLand users routinely raise `-Xmx` beyond 2 GB on such repos [E] |
| Per background tab | ≤ 1.1×N (Go buffer + int32 LineStarts) + 2 KB metadata | | package-dependent | | ≈ 2N+ (Swift String + Go copy) [E] | |
| Per visible editor | ≤ 2N (UTF-16) + ≤ 2 MB visible layout + tree-sitter ≈ 12×N [E] + 12 B/visible token | | | | ≈ 2N + 9N full layout ×2 (minimap) [M] | |
| Per terminal session | ≤ 4 MB in GoLens (1,000-line scrollback) + one zsh process (separate, ~3–6 MB [E]) | | | | leaked on close [code] | |

GoLens plus gopls on a small project should stay **≤ 135 MB total steady**. That is about 10–20× under the GoLand envelope. The large-project gopls figures are estimates and become gates only after the §5 scenario has been run on a real ~5k-file tree.

---

## 5. Measurement and enforcement

### 5.1 How to measure

| Target | Command / tool |
|---|---|
| GoLens footprint | `footprint -p $(pgrep -x GoLensApp)` (categories as in §1); `vmmap --summary <pid>`; in-app: `task_info(TASK_VM_INFO).phys_footprint` [S] |
| Swift heap / leaks | `MallocStackLogging=1 make run`, then `leaks <pid> --outputGraph=/tmp/golens.memgraph` and `heap <pid> -s`; Instruments **Allocations** (generation marks around open/close) and **Leaks**; `xctrace record --template 'Allocations' --attach <pid>` |
| Embedded Go runtime | `GoLensRuntimeStats` export (§3.3) shown in a debug status-bar overlay; `GoLensWriteHeapProfile` → `go tool pprof -top core/libgoagent.dylib heap.pb.gz`; `GODEBUG=gctrace=1 make run` for GC cadence |
| gopls | GoLens debug option to start `gopls -rpc.trace serve --debug=127.0.0.1:0` (pprof and memory pages) [S]; offline `gopls stats -anon` in the workspace (prints MemStats; use `/usr/bin/time -l` for peak footprint, as in §1); gopls auto-writes memory zips above 1 GB [S] |
| Micro costs | `go test -bench . -benchmem` in `core/` (Appendix A patterns move there as real benchmarks) |

### 5.2 Repeatable benchmark scenario ("golens-mem")

Fixtures: GoLensGoApp (small), the gopls v0.24 module (medium), plus generated `fixture_100k.go` and `fixture_1m.go`.

1. **S0 idle**: launch with no project, wait 10 s, record footprint and gopls count (expected 0).
2. **S1 small open**: open GoLensGoApp and one file, wait for diagnostics, wait 30 s, record.
3. **S2 typing**: in `fixture_100k.go`, type 500 characters at 10 chars/s (AppleScript/`CGEvent` driver). Record peak footprint, Go `/gc/cycles` delta, Go `/gc/heap/allocs` delta and gopls peak. Repeat with `fixture_1m.go`.
4. **S3 tab churn**: open and close 50 files twice, wait 30 s, record. Then `leaks`.
5. **S4 terminals**: open and close 10 terminals. Expect zsh process count and `terminalEngines.count` back at baseline.
6. **S5 output flood**: run a program that prints 1 M lines. GoLens footprint must stay under budget + 10 MB.
7. **S6 project switch ×5**: expect exactly one `gopls serve` child and gopls RSS at the single-project level.

Output is one JSON line per step (`{step, golens_fp, golens_peak, go_heap, go_gc, goroutines, gopls_rss}`), appended to a local report file for trend tracking.

### 5.3 Proposed checks (for the owner to approve; Makefile/scripts belong to another agent)

- **Go unit/bench gates (CI, cheap)**:
  - `testing.AllocsPerRun(FileBuffer.Splice) == 0`. The keystroke path (`NotifyEdit` with no transport) allocates ≤ 4 objects and ≤ 4 KB regardless of file size (asserted at both 10 KB and 1 MB).
  - Close-race test: `NotifyFileClose` followed by a late edit leaves `len(fileBuffers) == 0`.
  - Goroutine test: `NumGoroutine` returns to baseline after start and close of a terminal and of a fake LSP server.
  - Envelope test: decoding a 20k-token response allocates < 3 MB.
- **Dev check `make memcheck`** (proposed): runs S0–S4 and fails if any budget in §4 is exceeded by more than 10 %, or if `leaks` reports GoLens-attributed leaks.
- **Leak check after open/close 50 files**: GoLens footprint delta ≤ 2 MB; Go `len(fileBuffers) == 0`; every Swift per-path dictionary has `count == openFiles.count`; gopls RSS within 10 % of the pre-run value.
- **Review gate**: any new collection, cache or child process must add a row to §3.6 or §3.5.

---

## 6. Prioritized fix list

Risk column: "compliant" means the fix fits the architecture rules as written; "restores" means it brings the code back into line with the architecture rules.

| P | Item | Evidence | Expected savings | Effort | RULES risk |
|---|---|---|---|---|---|
| P0-1 | Wire byte-offset incremental sync from `textStorage(_:didProcessEditing:)`; delete `NotifyFullChange` from `textDidChange` and `updateNSView` | MacTextView.swift:95-105, 453-468 | Go per keystroke 468 KB → ≈3 KB (5.9 MB → ≈3 KB at 1 MB) [M]; Swift transcode of 1.4–15 ms per key removed | M | **restores** §1 |
| P0-2 | In-place `FileBuffer.Splice` + LineStarts patch (`[]int32`) | lsp/client.go:440-461 | 33 µs/120 KB → 0.7 µs/0 B per edit @100 KB [M]; LineStarts −50 % | S | compliant (FileBuffer stays the source of truth) |
| P0-3 | Terminal lifecycle: Swift calls `CloseTerminal` and drops the engine; Go kills the process group, closes the PTY and `Wait()`s | ConsoleView.swift:175-182; agent.go:118-131 | Leak of 1–5 MB plus one zsh per closed tab removed [E] | S | compliant |
| P0-4 | Close race: route `NotifyFileClose` through `lspQueue`; Go ignores edits for unknown or closed docs | +FileSys.swift:174-180; lsp/client.go:491-500 | Removes permanent buffer resurrection | S | compliant |
| P0-5 | gopls lifecycle: lazy spawn, shutdown/exit on switch and close, `memoryLimit`, one per workspace | lsp/client.go:61-96, 248-319 | Idle −73 MB (+ telemetry child); no stale workspace per switch; peak −35–50 % with the limit [M] | M | compliant |
| P0-6 | `languageId` by extension; send only Go-family files; file-size thresholds | lsp/client.go:366-376; +FileSys.swift:153-163 | gopls work and memory for non-Go docs removed | S | compliant |
| P1-7 | Remove `openFilesContent`; Swift holds NSTextStorage for visible editors + MRU 2; tab model = `DocumentSession` | WorkspaceState.openFilesContent; NativeEditorView.swift:27-33 | −N per background tab; per-keystroke SwiftUI invalidation removed | L | compliant (Go remains the model) |
| P1-8 | Highlight pass keyed on version counters; drop `EnsureFileOpen` from it; tree-sitter `tree.edit()` with UTF-16 byte units before `parse`; fix the units in A9; static keyword sets | MacTextView.swift:226-297; SyntaxHighlighter.swift:43-65, 180-229 | 3 × 4.5 ms compares + 200 KB copies per pass removed @100 KB [M]; true incremental parse | M | **restores** §2.1 (incremental parsing with strict offsets) |
| P1-9 | Semantic tokens: range request, typed envelope, packed `u32` into a caller buffer, byte→UTF-16 via NonASCIIIndex | lsp/client.go:126, 826-929; MacTextView.swift:304-379 | Envelope 14.6 MB → 2.2 MB per 20k tokens; payload 33.5 → 12 B/token; encode 160 µs → 0.8 µs per 2k [M] | M | compliant (Layer 2 kept, absolute byte offsets kept) |
| P1-10 | Codelens: lazy and cached, ≤ 50 references, `git blame` once per save | WorkspaceState.reloadCodeLens / getGitAuthors | Removes a fork plus a K-request gopls fan-out per typing pause | S | compliant |
| P1-11 | Replace the 44 `components(separatedBy:)` and the per-char `substring` scans on hot paths with an incremental line index and buffered `getCharacters` | GoLensTextView.swift:452-506, 875-878; MacTextView.swift:769-822; WorkspaceModels.swift:345-353 | Up to 4–43 ms and ~1.5–16×N allocations per caret move or pause removed [M]/[E] | M | compliant (UI line numbers, not sync) |
| P1-12 | Remove `ensureLayout(for:)` and the prefix `substring` from `drawBackground`; `allowsNonContiguousLayout = true` | GoLensTextView.swift:899, 950 | Retained layout ≈9×N → visible region only (−0.9 MB @100 KB, −9 MB @1 MB) [M] | S | compliant |
| P1-13 | Minimap drawn from line index + token runs into cached bitmap tiles (NSCache, cost-limited), not a second NSTextStorage | MinimapView.swift:184-237 | −2N storage − ≈9×N layout per document [M] | M | compliant |
| P1-14 | Typed LSP envelope; separate request/response/notification routing; one ID allocator in Go for both callers | lsp/client.go:98-225; LSPClient.swift:105-158 | −85 % bytes per large response [M]; fixes continuation leaks | S–M | compliant |
| P1-15 | Completions ≤ 200, `completionDocumentation:false` + resolve, `Data(bytesNoCopy:)` | WorkspaceState+LSP.swift:76-126 | ~150 KB → ≤ 30 KB per request [E]; 2 copies removed | S | compliant |
| P2-16 | One log ring with a byte cap; raw gopls/DAP logging behind a toggle | +Build.swift:165-171; lsp/client.go:221; dap/client.go:90 | Logs bounded at ≤ 1 MiB (today 2×2,000 unbounded lines) | S | compliant |
| P2-17 | Per-document `UndoManager` (500 levels), dropped on close | MacTextView.swift:46 | Removes unbounded cross-file undo growth | S–M | compliant |
| P2-18 | Diagnostics for open files + caps; incremental flat list; stable IDs (no UUID per publish) | WorkspaceState.diagnostics; +FileSys.swift:84-93; WorkspaceModels.swift:27-28 | Bounded; less SwiftUI identity churn | S | compliant |
| P2-19 | Image preview: decode once, downsample, NSCache | ImagePreviewView.swift:15, 56 | Up to tens of MB per large image [E] | S | compliant |
| P2-20 | Clear all per-path state on close (`DocumentSession`) | +FileSys.swift:174-193 | Growth bounded by open tabs | S | compliant |
| P2-21 | `DiscoverTests`: fresh `token.FileSet` per file, no `ParseComments`, `SkipObjectResolution`, or delegate to `go test -list` in a child | testutil/test_parser.go:31-50 | In-app transient heap O(largest file) instead of O(all tests) [E] | S | compliant |
| P2-22 | Go: `SetMemoryLimit(64 MiB)` guard, metrics and heap-profile exports | core (absent) | Observability; caps runaway growth | S | compliant |
| P2-23 | Terminal bytes as `(ptr,len)`, no NUL truncation; scrollback 1,000 | agent.go:83; WorkspaceState.goTerminalCallback | 3 copies → 1 per chunk; correct binary/UTF-8 output | S | compliant |
| P2-24 | `autoreleasepool` in long loops; `boundsDidChange` observer scoped to own clip view; `[weak textView]` in codelens task | +Search.swift:162-226; GoLensTextView.swift:130 | Lower peaks during search; CPU | S | compliant |

Suggested order: P0-1 → P0-2 → P0-4 → P0-3 → P0-5/6 (one sprint), then P1-8/11/12 (editor CPU and memory), then P1-7 (structural), then the rest.

---

## 7. Architecture rule 5 (approved 2026-10-30)

> ## 5. Memory Ownership & Budgets
> - **One authoritative copy per document per layer.** The Go `FileBuffer` (UTF-8) is the only document model. Swift holds an `NSTextStorage` only for visible editors (a rendering copy, plus at most 2 MRU hidden tabs). gopls holds its own copy. Document text must never be stored in Swift `@Observable` state or in value-type caches.
> - **Per-keystroke work is O(edit), not O(document).** Full-document transfers across CGO are allowed only for open, reload-from-disk and explicit replace-all. Whole-document scans (`components(separatedBy:)`, `String ==` on document text, `substring(to:)` prefixes, `ensureLayout` over the whole container, full-range attribute resets) are forbidden in keystroke, caret, scroll and draw paths. Use document version counters and incremental indexes.
> - **CGO ownership contract.** Every exported function documents who owns returned memory and which function frees it. Hot-path results (semantic tokens, diagnostics, folding, inlay hints) are packed binary `(ptr, len)`, never JSON. Callbacks receive `(ptr, len)` and must copy before returning. Go pointers are never retained by C/Swift beyond a call (cgo pointer rules). Paths cross once and become a `docID`.
> - **Every collection and cache has a numeric cap** recorded in `docs/memory-model.md` §3.6. An uncapped collection, or a cache without a cost limit, blocks review.
> - **Every child process and goroutine has an owner and a stop path** (shutdown → kill → `Wait`). Closing a tab, terminal or workspace releases all of its per-path state, views and processes.
> - **gopls**: one instance per workspace, started on workspace open, shut down on close or switch, launched with `memoryLimit`, and fed only Go-family documents.
> - **Budgets are release gates.** A change that regresses any `docs/memory-model.md` §4 budget by more than 10 % needs a measured justification in the PR.

---

## 8. Sources

- Apple: Reducing your app's memory use: https://developer.apple.com/documentation/xcode/reducing-your-app-s-memory-use
- Apple: Gathering information about memory use: https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use
- Apple WWDC18 "iOS Memory Deep Dive" (footprint, dirty/compressed memory): https://developer.apple.com/videos/play/wwdc2018/416/
- Apple `NSLayoutManager.allowsNonContiguousLayout`: https://developer.apple.com/documentation/appkit/nslayoutmanager/allowsnoncontiguouslayout
- Apple `NSTextViewDelegate.undoManager(for:)`: https://developer.apple.com/documentation/appkit/nstextviewdelegate/undomanager(for:)
- Apple `UndoManager.levelsOfUndo`: https://developer.apple.com/documentation/foundation/undomanager/levelsofundo
- Apple `NSCache.totalCostLimit`: https://developer.apple.com/documentation/foundation/nscache/totalcostlimit
- Apple Using Autorelease Pool Blocks: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MemoryMgmt/Articles/mmAutoreleasePools.html
- Apple `CGImageSourceCreateThumbnailAtIndex`: https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:)
- Apple `DispatchSource.makeMemoryPressureSource`: https://developer.apple.com/documentation/dispatch/dispatchsource/makememorypressuresource(eventmask:queue:)
- Go cgo, passing pointers: https://pkg.go.dev/cmd/cgo#hdr-Passing_pointers
- Go `runtime.Pinner`: https://pkg.go.dev/runtime#Pinner
- Go GC guide (GOGC, memory limit): https://go.dev/doc/gc-guide
- Go `debug.SetMemoryLimit`: https://pkg.go.dev/runtime/debug#SetMemoryLimit
- Go `runtime/metrics`: https://pkg.go.dev/runtime/metrics
- gopls settings (`memoryLimit`, `directoryFilters`, `expandWorkspaceToModule`, `semanticTokens`, `diagnosticsTrigger`): https://go.dev/gopls/settings (verified against the local v0.24.0 `doc/settings.md`)
- gopls troubleshooting (`-rpc.trace`, `--debug`, memory zips): https://go.dev/gopls/troubleshooting
- gopls scalability redesign, v0.12 (≈75 % average savings; memory ∝ open packages + direct imports; typed syntax ≈30× source): https://go.dev/blog/gopls-scalability
- LSP 3.17 position encodings (gopls v0.24 does not negotiate UTF-8; checked `gopls/internal/server`): https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#positionEncodingKind
- JetBrains GoLand memory settings (`-Xmx`; the default "depends on the platform"): https://www.jetbrains.com/help/go/increasing-memory-heap.html

---

## Measured after Phase M (2026-10-30)

All rows are [M]: same machine (Apple M4, macOS 26, gopls v0.24.0, Go 1.27.1), same scripts before and after. GoLens `phys_footprint` comes from `footprint -p` (S0, S1) or `task_info` sampled every 50 ms by an injected typing driver (S2). gopls figures are RSS of the direct `gopls serve` child, sampled every 0.5 s. S2 types 200 characters into a comment in the middle of the file at 10 chars/s; "sync" is the main-thread time of one `insertText` (AppKit included). Footprint varies ±15 MB between identical runs (window backing stores on the active display), so single runs are listed where they disagree.

| Scenario | Metric | Before | After | §4 budget |
|---|---|---|---|---|
| S0 idle, no project | GoLens steady / peak | 40 / 45 MB | 44–46 / 45–51 MB (2 runs) | ≤ 45 / ≤ 60 |
| | gopls processes | 1 (spawned at launch) | 0 | 0 |
| S1 GoLensGoApp, 1 file | GoLens steady / peak | 79 / 161 MB (another run crashed: index out of range in `GetSemanticTokens`) | 89 / 148 MB at 40 s; 73 MB at 65 s | ≤ 55 / ≤ 90 (missed before and after) |
| | gopls steady / peak | 227 / 256 MB | 21 / 164 MB (`GOMEMLIMIT=256MiB`) | ≤ 80 / ≤ 150 |
| | Idle CPU | 0 % | 0.1 % (65 s after launch) | |
| S2 10 KB | sync p50 / p95 / max | 1.28 / 2.54 / 6.4 ms | 0.80–0.91 / 0.97–1.12 / 5.7 ms | |
| | longest main-thread stall | 248 ms | 16–30 ms | |
| | GoLens CPU during 20 s of typing | 6.45 s | 0.80–1.07 s | |
| | GoLens steady after typing | 74.6 MB | 70–94 MB | |
| | gopls peak | 288 MB | 312–401 MB (fixture package holds 1.1 MB of Go) | |
| S2 100 KB | sync p50 / p95 / max | 5.9 / 6.4 / 11.5 ms | 0.77–0.88 / 0.94–1.22 / 6.3 ms | |
| | longest main-thread stall | 211 ms | 16–94 ms | |
| | GoLens CPU during typing | 28.9 s (145 % of a core) | 0.75–1.37 s | |
| | GoLens peak / steady | 172 / 92 MB | 149–159 / 80–91 MB (peak is graphics: 49 MB GPU-owned + 20 MB IOSurface; MALLOC_SMALL stays at 41 MB) | |
| | gopls peak | 287 MB | 306–375 MB | |
| S2 1 MB | completion | did not finish 200 characters in 18 min (GoLens 100–115 % CPU) | finished in 20 s | |
| | sync p50 / p95 / max | n/a | 1.68 / 2.16 / 2.7 ms | |
| | GoLens CPU / steady | n/a / 145 MB at kill | 0.83 s / 131 MB | |
| | gopls peak | 1.54 GB | 352 MB | |
| S2 1.87 MB | GoLens document-sync work per edit (indexes, tree-sitter edit, Go splice, didChange enqueue) | n/a | p50 0.14 ms, p95 0.19 ms | |
| | first tree-sitter parse on open / incremental pass | n/a | 144 ms (once) / 13 ms | |

Go core, per edit, no transport (`go test -bench Keystroke -benchmem ./lsp`; each op is an insert plus a delete): 10 KB 1.2 µs, 100 KB 2.6 µs, 1 MB 17.9 µs, each about 1.1 KB and 14 allocations, independent of file size (before: 120 µs and 468 KB at 100 KB, 1.27 ms and 5.9 MB at 1 MB). `FileBuffer.Splice` allocates nothing (`TestSpliceAllocatesNothingOnKeystroke`).

Other measured results: completion re-filter 0.08–0.15 ms per keystroke (1,000-item ranking 0.1 ms in `TestFilterLatencyBudget`); first completion results 8–106 ms on a warm small project; save with organize imports plus formatting through gopls 3–18 ms, no child process; gopls restart after `SIGKILL` 1.1 s with open documents replayed; five project switches leave exactly one `gopls serve` (`TestRealGoplsLifecycle`); opening three terminals and closing them returns the shell count from 4 to 1 with no zombies; semantic colours present at the top, middle and end of the 139 KB `net/http/server.go` (range requests, each < 90,000 bytes).

Not measured: S3 tab churn with `leaks`, S5 output flood, the medium (~700 files) and large corpora.

## Measured after Phase L (2026-10-30)

Same machine, same typer (`phaseM/typer.m`) and fixtures, `quiet-launch` injected, prefs restored from a backup. Because the recorded Phase M gopls figures could not be reproduced today (the Phase M binary, rebuilt from 1486ab2, now peaks at 853–947 MB on the 10 KB scenario instead of 312–401 MB), each Phase L run was paired with a same-day run of the Phase M binary.

| Scenario | Metric | Phase M doc | Phase M binary today | Phase L |
|---|---|---|---|---|
| S2 10 KB | sync p50 / p95 / max | 0.80–0.91 / 0.97–1.12 / 5.7 ms | 0.77–0.81 / 0.97–1.02 / 2.0–3.5 ms | 0.76–0.87 / 0.92–1.07 / 1.6–4.0 ms |
| | longest main-thread stall | 16–30 ms | 12 ms | 12–13 ms |
| | GoLens CPU during typing / steady / peak | 0.80–1.07 s / 70–94 / — MB | 0.65–0.68 s / 82–83 / 143 MB | 0.63–0.69 s / 78–81 / 141–150 MB |
| | gopls peak | 312–401 MB | 853–947 MB | 1,600–2,470 MB (10 runs, including the bisection builds) |
| S2 100 KB | sync p50 / p95 / max | 0.77–0.88 / 0.94–1.22 / 6.3 ms | 0.80 / 0.98 / 6.0 ms | 0.80 / 1.19 / 3.9 ms |
| | GoLens steady / peak | 80–91 / 149–159 MB | 87 / 148 MB | 87 / 157 MB |
| | gopls peak | 306–375 MB | 774 MB | 1,590 MB |
| S2 1 MB | sync p50 / p95 / max | 1.68 / 2.16 / 2.7 ms | 1.73 / 2.65 / 18.3 ms | 1.75 / 2.34 / 8.5 ms |
| | GoLens steady / peak | 131 / 211 MB | 148 / 222 MB | 156 / 217 MB |
| | gopls peak | 352 MB | 880 MB | 740 MB |
| Small project (GoLensGoApp copy, 200 chars in `main_test.go`) | gopls peak | — | 176 / 257 MB | 263 / 172 MB |

GoLens-side work per keystroke and GoLens footprint are within 10 % of Phase M (the 1 MB steady value is +5 % against the same-day Phase M run, inside the ±15 MB run-to-run spread noted above).

gopls peak on the 10 KB and 100 KB scenarios is about 2× the same-day Phase M binary; on 1 MB and on the small project it is not higher. The typed file sits in a package with about 3 MB of Go (`fixture_1m.go` and `fixture_2m.go` sit next to the typed file). Bisection with the same binary ruled out the gopls settings (Phase M settings: 1,880 / 2,466 MB), the client capabilities (Phase M capabilities: 1,797 / 1,603 MB) and the implementation-marker requests (2,026 MB). The traffic difference that remains is that Phase L sends almost no requests while typing in a comment (no completion requests in comments since L0, no reference lookups for this file), while Phase M sends 16 completion and 50 reference requests; the didChange stream is identical. Phase L also stopped re-sending the configuration at startup (`workspace/didChangeConfiguration` is only sent when the effective settings change), which removed one full gopls reload. Open item: profile gopls (`-profile.mem`) on this fixture to explain the growth; the RSS stays above `GOMEMLIMIT` (256 MiB), so the growth is live heap during repeated package diagnosis.

Project search, `go/src/net` (415 files, 4.7 MB, inside the Go git checkout), median of 5–7 runs, same queries:

| Query | Before: Swift serial scan (500-match cap) | Before with a 2,000-match cap | After: Go core parallel scan | Hits / files after |
|---|---|---|---|---|
| `func` | 24.6 ms (stops at 500) | 92.8 ms | 37.7 ms | 2,000 (cap) / 129 |
| `Dial` | 101.8 ms (stops at 500) | 338.5 ms | 35.0 ms | 1,271 / 102 |
| `error` | 23.9 ms (stops at 500) | 81.7 ms | 35.2 ms | 2,000 (cap) / 120 |
| `net.Conn` | 360.4 ms | 357.9 ms | 34.9 ms | 215 / 34 |
| `syscall` | 41.2 ms (stops at 500) | 351.1 ms | 34.5 ms | 1,418 / 148 |
| `TODO` | 365.9 ms | 369.5 ms | 34.6 ms | 132 / 48 |
| no match | 354.5 ms | 348.0 ms | 33.3 ms | 0 |

About 33 ms of every query is `git ls-files --cached --others --exclude-standard` (it reads the whole Go repository index); the scan itself takes 1–5 ms. Outside a git repository the core walks the tree itself with the same filters.

## Measured after UX Phase 4 (2026-10-30)

Same machine and typer (`phaseM/typer.m`, 200 characters at 10 chars/s into a comment), fixture package with about 3 MB of Go, each run paired with a same-day run of the Phase M binary. The main display is now an external 2560 × 1080 (1×) monitor, so absolute footprints are not comparable with the earlier Retina rows; compare within this table.

| Scenario | Metric | Phase M binary today | UX Phase 4 |
|---|---|---|---|
| S2 10 KB | sync p50 / p95 / max | 0.93 / 1.10 / 3.8 ms | 0.90–1.10 / 1.10–1.39 / 8.1–8.5 ms (2 runs) |
| | GoLens steady / peak | 67 / 121 MB | 70–72 / 126–127 MB |
| | gopls peak | 854 MB | 529–569 MB (Phase L: 1,600–2,470 MB) |
| S2 100 KB | sync p50 / p95 / max | 0.93 / 1.12 / 2.8 ms | 0.92–0.98 / 1.14–1.57 / 6.5–19.2 ms (3 runs) |
| | GoLens steady / peak | 74 / 129 MB | 72–76 / 131 MB |
| | gopls peak | 901 MB | 491–574 MB, 3 runs (Phase L: 1,590 MB) |
| S2 1 MB | sync p50 / p95 / max | 1.75 / 2.33 / 4.7 ms | 1.80–2.09 / 2.28–2.60 / 3.1–28.5 ms (6 runs; median p50 1.81) |
| | GoLens steady / peak | 139 / 196 MB | 102–137 / 109–194 MB (5 runs; one more: 188 / 292 MB, see below) |
| | gopls peak | 574 MB | 476–571 MB (6 runs) |
| S1 small project (fixture `iws`, 1 file, 45 s) | GoLens `phys_footprint` | — | 68 MB (MALLOC_SMALL 40 MB dirty, untagged VM 8 MB, IOSurface 5 MB, IOAccelerator 2.5 MB, `__DATA*` 5 MB, CG image 1.6 MB, CoreAnimation 1 MB); peak 130 MB at launch |

Keystroke latency stays within the run-to-run spread of the same-day Phase M binary (the first 10 KB run is +18 % p50, the second −4 %; 100 KB and 1 MB are within ±5 %). GoLens footprint is within 10 %. In 2 of the 9 runs (one 1 MB, one 100 KB) GoLens showed about 13 % CPU and 260–290 MB during the idle sample; a second document had been opened during those runs, see the next section.

### Idle anomaly: a second file opened during the idle sample (explained, 2026-10-31)

Cause: in both runs `fixture_2m.go` was opened in the editor during the idle window (most likely a click in the file navigator; the bench windows were launched visibly in front of the owner). The 13 % is not a spin. It is about 1 s of one-time work to open a 1.9 MB file, and it falls inside the 10 s idle sample. The 260–290 MB is the 100 KB or 1 MB document plus the 1.9 MB one. Evidence (agent scratch `pretrackb/`):

- **The failing lookups come from `fixture_2m.go`, not `fixture_1m.go`.** `fixture_2m.go` starts with the same 2,453 `Item1M*` types as `fixture_1m.go`. go/types records the first declaration in file order (`fixture_1m.go`), so the copies in `fixture_2m.go` have no object, and gopls answers "no object found" for their `references` and `implementation` requests. Usage lenses cover the first 50 declarations: 25 types fail and 25 methods resolve, which gives exactly 25 failures. Running the bench with `fixture_2m.go` as the document reproduces the same 25 failures, with the request path logged as `fixture_2m.go:9`, `:28`, … Lenses for `fixture_1m.go` never fail.
- **The active file changed during the run.** `refreshActiveFileDiff` runs on every active-file change and logs "Failed to run git diff" in this repo-less fixture. Normal runs log it once; the two anomalous runs logged it 2 and 3 times. Every path that changes the active file is a person's action (navigator click, tab, jump bar, search result, Back/Forward, go to definition).
- **Reproduction.** A navigator click on `fixture_2m.go`, delivered in-process at 62 s during the 100 KB bench, gives steady 151.6–154.1 MB, peak 256.8–260.6 MB, idle CPU 9.0–9.3 % and the same 25 failures (anomalous run: 153.0 / 261.2 MB, 13.4 %). The same click at 55 s, before the sample starts, gives 155 / 260 MB with 0.5 % idle CPU.
- **Sample across the burst** (`sample` at 1 ms intervals, 5 s): GoLens uses about 1 s of CPU. The main costs are the declaration scan in `documentDidEdit` (248 ms), decoding about 4,900 document symbols (184 ms), the lens task's declaration scan (136 ms) and the tree-sitter parse plus highlight (134 ms). After that, idle CPU drops back to 0.4 %.

Fixed while proving it: a usage-lens load kept running after its document left the screen whenever the next document was not a Go file or already had cached lenses (up to 50 `references` + 50 `implementation` requests on a hidden document). `syncVisibleDocuments` now cancels the lens task once its document is no longer visible (`WorkspaceState.codeLensLoadPath`). Opening `fixture_2m.go` and switching to `go.mod` 1.5 s later: 25 failed lookups before the fix, 14 after it. Check: 9 bench runs after the fix (3 each of 10 KB, 100 KB and 1 MB) with no anomaly (one active-file change per run, no failed lookups, idle CPU 0.38–0.84 %). p50, p95, GoLens footprint and gopls peak are within 10 % of the Phase 4 table above, or better. One 10 KB max (11.3 ms) is above the earlier 8.5 ms but inside the max spread of that table (up to 28.5 ms):

| Scenario | sync p50 / p95 / max | GoLens steady / peak | gopls peak |
|---|---|---|---|
| 10 KB | 0.79–0.85 / 0.95–1.02 / 3.0–11.3 ms | 65–68 / 121–123 MB | 453–505 MB |
| 100 KB | 0.75–0.79 / 0.91–0.93 / 4.5–6.4 ms | 68–73 / 126–127 MB | 465–493 MB |
| 1 MB | 1.73–1.97 / 1.94–2.27 / 2.7–8.1 ms | 106–113 / 166–169 MB | 493–514 MB |

Bench guidance: the typer measures whichever editor is in front. Runs launched visibly can pick up a person's click, so a run counts only if its log shows a single active-file change.

### Layout review check (2026-10-31)

100 KB typer runs on today's main display (built-in 2560 × 1664 Retina, so absolute footprints are higher than the 1× rows above), each paired with the HEAD binary (`5e72f2b`) built the same day:

| Binary | sync p50 / p95 / max | GoLens steady / peak | gopls peak |
|---|---|---|---|
| HEAD (2 runs) | 0.759–0.762 / 0.889–0.919 / 6.1–6.5 ms | 85.4–88.7 / 153.1–156.7 MB | 482–517 MB |
| Layout review (3 runs) | 0.757–0.772 / 0.900–0.918 / 3.1–6.5 ms | 90.1–91.0 / 156.4–167.9 MB | 455–508 MB |

Latency is unchanged; steady footprint is +3–6 % and peak within +7 % of the same-day HEAD runs (inside the 10 % gate).

### gopls peak: orphaned type-checks (fixed)

gopls peaked at about 2× the Phase M client on the 10 KB and 100 KB scenarios because of how gopls handles cancellation, not because of settings or capabilities. Every didChange makes gopls cancel the previous diagnosis and start a new immediate type-check of the edited package, but `go/types` cannot be interrupted once `check.Files` has started (gopls `cache/check.go`). On the 3 MB fixture package each abandoned check runs to completion (about 0.7–1 s and 150–250 MB of type information). With one didChange per keystroke at 10 chars/s, about nine orphaned checks ran at once: a goroutine dump at the 2.1 GB peak showed 9 goroutines inside `Checker.Files`, and 85 % of the 1.96 GB in use was `go/types` record maps. That is live heap, so `GOMEMLIMIT` cannot reclaim it; the GC ran nonstop instead. The Phase M client avoided this by accident: gopls handles messages in order, so each completion request typed into the comment held back the following didChanges until it finished, and the intermediate diagnoses were cancelled before their type-check started (a replay without those 16 completion requests peaks at 1.8–1.9 GB; the Phase L traffic with them added peaks at 0.87 GB). `diagnosticsDelay` does not help, because gopls does not apply it to this immediate check, and `diagnosticsTrigger: "Save"` only works by turning live diagnostics off. Evidence and replayer: agent scratch `phase4/gopls-prof/` (traces of both clients replayed against `gopls serve -debug`, heap profiles and goroutine dumps at each peak).

Fix (`core/lsp/conn.go`): after a didChange, later edits are held until gopls publishes diagnostics for that version (at most 2 s, `changeGateMax`) and then go out as one didChange with all content changes in order; every other outgoing message (requests, Swift-originated messages, other notifications) flushes held edits first, so no request ever sees stale text. The client now advertises `publishDiagnostics.versionSupport`. In replay this lowered the peak from 1.5–2.2 GB to 0.41–0.49 GB, gave fresh diagnostics at least every 1.7–3.7 s while typing (8–14 s before) and diagnostics 0.1–0.2 s after the last keystroke; in the app the 10 KB / 100 KB peaks are now 491–574 MB, below the Phase M binary. Cost: while typing on a large package, diagnostics lag the newest edit by about one type-check. A document gopls never publishes diagnostics for holds its edits up to 2 s unless a request flushes them. Test: `TestEditsWaitForDiagnosticsAndCoalesce`.

### Small-project footprint (§4 target 55 MB steady): findings

`heap` with `MallocStackLogging` on the 68 MB small-project process attributes the 40 MB of dirty MALLOC_SMALL as follows:

| Owner | Size | Notes |
|---|---|---|
| ColorSync transform LUTs (`CMMParaCurveTag::MakeInvertedTRC` / `MakeTRC`) | 19.6 MB (108 tables × 181 KB) | One ~2.1 MB set per distinct source-color-space → display conversion, created by CoreAnimation (`convert_cgcolor`), SwiftUI drawing, gradients, glyph drawing and image decoding (including the app icon). Size depends on the display's ICC profile (parametric curves on this monitor) |
| Swift metadata, ObjC method caches, SwiftUI attribute graph and view tables | ~10 MB | Runtime cost of the SwiftUI shell |
| Live app data (documents, tree, git, console ring) | a few MB | Small on this project |
| Fragmentation (dirty minus live) | ~9 MB | MALLOC_SMALL resident 30.8 MB of 40 MB dirty |

Window backing stores and GPU memory are small at steady state (IOSurface 5 MB, IOAccelerator 2.5 MB on the 1× display); the larger graphics numbers seen earlier were peaks on the Retina display. Fixed cheaply: GoLens no longer redraws its icon into the Dock at launch when it runs as a `.app` (the bundle's icon is used), which avoids one ColorSync conversion and the decoded icon image (about 2–4 MB). Not fixed: the remaining LUTs are system caches keyed by color space and display profile; reducing them would mean drawing every color and image in the display's color space, which is not cheap or safe. Owner decision (2026-10-30): the small-project GoLens footprint is a best-effort target, not a release gate — part of it is system caches GoLens can't control. Keep optimizing toward 55 MB, and treat regressions against the last measured value (68 MB) under the usual 10 % rule.

## Appendix A: Microbenchmarks (measured 2026-10-30, Apple M4, Go 1.27.1, macOS 26, Swift `-O`)

Sources live in the session scratchpad (`…/scratchpad/memory/gobench`, `…/swiftbench`). Re-create them under `core/` as real benchmarks when P0-2/P1-9 land.

Go (`go test -bench . -benchmem`):

| Benchmark | 10 KB | 100 KB | 1 MB |
|---|---|---|---|
| Current full-sync keystroke path (GoString→[]byte→LineStarts→JSON) | 13 µs, 46 KB, 27 allocs | 120 µs, 468 KB, 28 allocs | 1.27 ms, 5.9 MB, 44 allocs |
| Current incremental `NotifyIncrementalChange` buffer update | 3.5 µs, 12 KB, 2 allocs | 33 µs, 120 KB, 2 allocs | 357 µs, 1.19 MB, 2 allocs |
| Proposed in-place splice + LineStarts patch | 0.13 µs, 0 B | 0.73 µs, 0 B | 10.5 µs, 68 B (amortized growth) |
| Incremental `didChange` JSON (range + 1 char) | 1.7 µs, 2.8 KB, 32 allocs (size-independent) | | |

| Benchmark | Result |
|---|---|
| `C.CString` round trip (malloc+copy+free) 64 B / 4 KB / 100 KB / 1 MB | 61 ns / 186 ns / 3.5 µs / 33 µs (C heap, invisible to Go's -benchmem) |
| Pinned Go `(ptr,len)` to C, any size | ≈15 ns, 0 B |
| Semantic tokens 2k: JSON encode / +CString / packed reuse | 160 µs 74 KB / 164 µs 150 KB / 0.78 µs 0 B; sizes 66,989 B vs 24,000 B |
| Semantic tokens 20k: same | 1.65 ms 890 KB / 1.81 ms 2.5 MB / 7.2 µs 0 B; sizes 689,940 B vs 240,000 B |
| 20k-token gopls response (241 KB): `map[string]any` + typed vs typed envelope + `[]uint32` | 11.0 ms, 14.6 MB, 200,075 allocs vs 3.1 ms, 2.2 MB, 31 allocs |

Swift (NSTextView with real NSTextStorage):

| Operation | 10 KB | 100 KB | 1 MB |
|---|---|---|---|
| `textView.string.utf16.count` (bridge) | 0.5 µs | 0.2 µs | 0.2 µs |
| Edit with a bridged snapshot held (copy-on-write check) | 21 µs vs 18 µs without | 21 vs 16 µs | 19 vs 15 µs |
| Bytes retained by one held snapshot after an edit | 18 KB | 10 KB | 17 KB |
| `String ==` on two document snapshots (equal length, diff at end) | 0.51 ms | 4.6 ms | 45 ms |
| `withCString` on document (UTF-16 → UTF-8 transcode) | 0.15 ms | 1.39 ms | 14.8 ms |
| `substring + components(separatedBy: .newlines)` (lineAndCol at end) | 0.49 ms | 3.98 ms | 42.9 ms |
| UTF-8 walk of the bridged document | 0.16 ms | 1.48 ms | 16.1 ms |
| Footprint of an extra full-layout NSTextStorage copy (minimap-style, 2.5 pt) | 0.6 MB | 0.9 MB | 9.0 MB |
| Completion JSON, 500 items (151 KB): `String(cString:)`+`Data`+decode vs `Data(bytesNoCopy:)`+decode | 0.77 ms vs 0.75 ms (the saving is 2 transient copies, not time) | | |

gopls (`/usr/bin/time -l gopls stats -anon`, gopls v0.24.0): see §1. The cold run populated the on-disk cache. Warm runs vary ±50 % from run to run, so treat the limit comparisons as indicative, not exact.

## Appendix B: Open questions for the owner

1. Hidden-tab MRU of 2 NSTextStorages: is instant tab switching worth about 2N plus visible layout per tab, or should the MRU be 0 (always rebuild from Go)?
2. Undo depth of 500 per document, and should undo history survive closing a tab (GoLand-style) or be dropped (frugal default proposed)?
3. Large-file thresholds of 10 MB (read-only, no LSP) and 50 MB (refuse): acceptable?
4. `memoryLimit` defaults of 256 MiB (small) and 1 GiB (large): fixed, or derived from project size after the first load?
5. Should GoLens surface the gopls telemetry child (6–9 MB) in its memory UI, given it is the user's global choice?
