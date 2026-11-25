# Completion quality harness

The acceptance gate for any change to code completion (`core/lsp/completion.go`,
`core/lsp/modules.go`, `desktop/Views/Editor/CompletionController.swift`). A change that makes
any check below fail, or lowers a recall metric, does not merge.

## What it checks

| Check | Test | Runs in |
|---|---|---|
| Ranking unit rules (gopls order, no length penalty, exact case first, dedupe, module-graph filter) | `TestRanking*`, `TestMatchTiers`, `TestDeprecatedSortsLast` | every `go test` |
| Session rules (local filter on incomplete lists, background refresh, typo keeps the session, commit uses the server edit range, snippet exit) | `TestIncompleteListFiltersLocallyAndRefreshesInBackground`, `TestCommitUsesTheServerEditRange`, `TestExpandSnippet`, `TestSessionFilterRowsAndCommit` | every `go test` |
| Context corpus: 71 snippets against the real gopls, expected top-3, forbidden items, text after commit | `TestCompletionQualityCorpus` | every `go test` with gopls installed (~15 s) |
| Masked-identifier recall vs raw gopls, forbidden unimported packages, duplicate rows | `TestCompletionRecall` | quick mode in every `go test` (~25 s); full mode on demand |
| Re-filter latency (1,000 items < 2 ms) | `TestFilterLatencyBudget` | every `go test` (skipped under `-race`) |

## Context corpus

One file per case in `core/lsp/testdata/completion/`:

```
name: struct literal key
want: name                 # expected top rows in order (comma separated, up to 3)
forbid: naq, nat           # labels that must not appear
insert: name: |            # committed text must start with this (| ends the value)
after: \tu.Greet("hi")\n|  # document must contain this after committing (\n allowed)
notafter: Greetet|         # document must not contain this after committing
commit: Greet              # row to commit for insert/after checks (default: top row)
file: x_test.go            # file name (default case.go; go.mod/go.work run outside the module)
expect: none               # only the forbid list is checked (gopls may return nothing)
-- src --
package p
...caret marked with |...
```

Each case gets its own package directory inside a temporary module `example.com/app` that
requires `example.com/dep` through a `replace` (so "unimported project module" has a real
target). Besides the listed expectations every case asserts: no duplicate rows, no unimported
package outside the standard library and the module graph, and GoLens never ranks the expected
item below its position in raw gopls order.

Add a case for every completion bug before fixing it.

## Masked-identifier recall

Samples identifier occurrences from real Go code, truncates each to its first 1–3 runes at the
original position (in an in-memory overlay sent with `didOpen`; files on disk are never
written), requests completion and records the rank of the original identifier in raw gopls
order (`sortText`) and in GoLens's ranking. Reports Recall@1/3/5 and MRR per context kind
(field, method, local, identifier, package, package member, literal key, keyword, unimported —
for unimported the import line is blanked in the overlay), and the 20 worst GoLens-vs-gopls
regressions with the line and caret. Fails when GoLens is below raw gopls on any overall metric,
or on any forbidden or duplicate row.

```sh
cd core
go test ./lsp -run TestCompletionRecall -v -short          # quick: 200 samples, owner projects
GOLENS_RECALL_N=2000 go test ./lsp -run TestCompletionRecall -v -timeout 60m   # full: adds Go's src
```

| Variable | Meaning |
|---|---|
| `GOLENS_RECALL_N` | sample count (default 200); setting it also adds `~/Documents/research/go/src` |
| `GOLENS_RECALL_SEED` | sampling seed (default 1) |
| `GOLENS_RECALL_ROOTS` | colon-separated module roots instead of the defaults |
| `GOLENS_RECALL_SAVE` / `GOLENS_RECALL_REPLAY` | save the sampled gopls responses as JSON / re-rank a saved file without gopls (0.2 s for 2,000 samples; use this to iterate on the ranker) |
| `GOLENS_RECALL_MISSES` | print up to 25 misses of one kind with GoLens's top 5 |
| `GOLENS_RECALL_OUT` | write the report to a file |

Default roots: every `~/GolandProjects/*` with a `go.mod` (read-only).

## Quick mode after Phase L (2026-10-30, 200 samples, seed 1)

| Ranker | R@1 | R@3 | R@5 | MRR |
|---|---|---|---|---|
| raw gopls order | 0.600 | 0.795 | 0.860 | 0.702 |
| GoLens | 0.610 | 0.805 | 0.865 | 0.710 |

No forbidden or duplicate rows; `TestCompletionQualityCorpus` passes. Phase L did not change the ranker; the gopls settings are now only re-sent when they change.

## Latest numbers (2026-10-30, gopls v0.24.0, seed 1)

Full mode, 2,000 samples (1,000 from Go's `src`, 1,000 from the owner's projects):

| Ranker | R@1 | R@3 | R@5 | MRR |
|---|---|---|---|---|
| raw gopls order | 0.571 | 0.748 | 0.809 | 0.670 |
| GoLens before (length penalty) | 0.535 | 0.742 | 0.809 | 0.653 |
| **GoLens now** | **0.593** | **0.769** | **0.821** | **0.689** |

Per kind, GoLens now vs gopls (R@1): local 0.774 vs 0.747, identifier 0.540 vs 0.494, unimported
0.328 vs 0.269, keyword 0.379 vs 0.360, field 0.832 = 0.832, method 0.699 = 0.699, package
member 0.377 = 0.377. Zero forbidden unimported suggestions and zero duplicate rows.
Quick mode (200 samples, owner projects): R@1 0.610 vs 0.600, MRR 0.710 vs 0.702.

## Ranking rules the numbers decided

- Match quality only buckets items: strong (prefix or word-start/camel) before subsequence.
  Within the strong bucket, a prefix that matches the typed case exactly comes first
  (`MaxR` → `MaxRetries` before `maxRate`); +0.022 R@1 over plain gopls order inside buckets.
- No label-length penalty (it cost 0.036 R@1 against gopls).
- Unimported items keep gopls' position instead of being forced last: forcing them last lost
  0.068 R@1 on unimported samples (gopls already ranks them low unless the context asks for a
  package), so the spec's "unimported always last" rule is not applied.
- Unimported packages outside the standard library and `go list -m all` are dropped; the
  module list is refreshed when `go.mod` or `go.work` changes.

Known limits: keyword recall is bounded by gopls (it offers `return nil` snippets instead of
`return` in functions with results, and no `for`/`select` before `{`); package-member R@1 is
low because many members share a prefix and nothing in the context distinguishes them.
