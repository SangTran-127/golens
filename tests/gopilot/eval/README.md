# Gopilot live eval

Prompts and checks for measuring answer quality of the Gopilot copilot against real models.

## Pieces

| Path | Role |
| --- | --- |
| `tests/gopilot/fixtures/<name>/` | Synthetic Go projects (stdlib only, no network). Each has `ground-truth.json` written and verified by hand. |
| `tests/gopilot/eval/prompts.json` | 30 prompts: 10 onboarding, 8 explain, 4 ambiguity, 4 performance, 4 propose-verify. |
| `scripts/gopilot/run-eval.sh` | Runs the prompts inside the app and writes `results.json`. |
| `scripts/gopilot/eval-check.py` | Scores `results.json` with mechanical checks, prints a report, writes a markdown review sheet. |
| `scripts/gopilot/check-fixtures.py` | Vets, tests and gofmt-checks every fixture, validates ground-truth references. `--profiles` also runs every `prepare.sh` and checks the expected top frames with `go tool pprof`. |

Typical flow: `python3 scripts/gopilot/check-fixtures.py --profiles`, then the app harness, then `python3 -I scripts/gopilot/eval-check.py results.json`, then a human grades the review sheet.

## Prompt fields

`id`, `category`, `fixture`, `prompt` (the exact text sent), optional `profileKind`, `mustMention`, `mustNotClaim`, `expectedTools`, `expectUncertainty`, `allowsExecution`, `expectProposal`, `groundTruthRef`.

- `mustMention`: every element must be satisfied. An element is a string, or an array of acceptable alternatives. Matching is a case-insensitive substring test.
- `mustNotClaim`: substrings that signal a wrong or fabricated claim. A negated sentence can trigger one by accident, so review these hits instead of trusting them blindly.
- `expectedTools`: at least one of these tools must finish with status `ok`. Names come from the registry in `technical-contracts.md` section 4.
- `allowsExecution`: only propose-verify and benchmark-comparison prompts may call `run_tests` or `run_benchmark`.
- `groundTruthRef`: where each fact in `mustMention` and `mustNotClaim` was verified (fixture source, ground-truth fact id, or an observed command output).

## Profiles: the `prepare.sh` convention

Fixtures that need a profile contain an executable `prepare.sh`:

```
prepare.sh <fixture-dir> <output-profile-path> [kind]
```

`kind` is one of `cpu`, `alloc`, `inuse`, `block`, `mutex`. The script copies the fixture into its own temporary directory, runs `go test -run '^$' -bench ... -cpuprofile|-memprofile|-blockprofile|-mutexprofile` there, and writes a real `.pprof` to the output path. It leaves the fixture untouched, so it works on a copy as well. Exit code 2 means an unsupported kind. `alloc` and `inuse` produce the same heap profile; the sample index (`alloc_space` or `inuse_space`) is chosen when reading it.

| Fixture | Kinds | Expected top frame (from `ground-truth.json`) |
| --- | --- | --- |
| perf-cpu | cpu | `isPrime` |
| perf-heap | alloc, inuse | alloc_space `renderRows`, inuse_space `loadIndex` |
| perf-contention | cpu, block, mutex | cpu `spin`, block `runtime.chanrecv1` from the testing framework, mutex `Mutex.Unlock` under `Store.Add` |
| benchmark-lab | cpu, alloc | cpu `runtime.memequal` under `Dedupe`, alloc `JoinSlow` |

## Results schema

The harness writes `{"schema":1,"model":str,"startedAt":iso,"runs":[...]}`. Each run:

`promptID`, `run`, `terminal` (`turnCompleted|turnFailed|turnCancelled|turnBudgetExceeded`), `answer`, `toolTrace[]` (`name`, `args`, `status` ok or error, `errorCode`, `startMs`, `endMs`, `result`), `citations[]` (`token`, `resolved`, `path`, `startLine`, `endLine`, `stale`), `evidence[]` (`id`, `kind`, `path`, `contentHash`, `truncated`), `usage` (`requests`, `inputTokens`, `outputTokens`), `ttftMs`, `firstEvidenceMs`, `totalMs`, `approvals[]` (`operation`, `decision`), `proposals`, `error`.

## Automatic checks

Per run: terminal completed; every `[E<n>]` token in the answer is in `citations`, resolved and not stale; no `mustNotClaim` hit; every `mustMention` element satisfied; an expected tool finished ok; uncertainty wording present when `expectUncertainty`; no execution tool unless `allowsExecution`; at least one proposal when `expectProposal` and none otherwise; no `sk-` followed by 10 or more alphanumerics in the answer, tool args or tool results.

A case passes only if all of these pass. The six rubric items (0 to 2 each) are filled where possible: correct flow and symbols, citation validity, uncertainty and scope are auto-scored; purpose, helpfulness and whether citations really support the claims are marked `needs-review`. The aggregate report gives pass rate, citation resolve rate, mean tokens per category, median and p95 of time to first token, time to first evidence, total time and request count, and per-prompt consistency across runs. `python3 -I scripts/gopilot/eval-check.py --selftest` checks the checker on an embedded synthetic result set and exits non-zero on any mis-scoring.

## Honesty rules

- A model is never the sole judge. Semantic grading is manual, against `ground-truth.json`; the review sheet lists the facts next to each answer.
- An automatic pass is not a quality pass. The release proposal (at least 90 percent of cases at 10 of 12 or better with no critical error, 100 percent of rendered citations resolving) can only be claimed after the human rubric is filled in.
- Failures are reported with the full answer, tool trace and failed checks. Answers are redacted for secret-like strings only; nothing else is trimmed. Do not publish averages without the worst cases.
- Missing coverage is stated, not hidden: fewer than 30 prompts or fewer than 3 runs per prompt means this is not a full eval.
- A faster microbenchmark or a CPU profile does not prove an end-to-end speedup; prompts in the performance and propose-verify groups are written so that a correct answer says so.
- Fixtures contain no secrets. Never put a real key in prompts, fixtures or results.
