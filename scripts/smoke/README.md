# Smoke suite

End-to-end checks of the real app on throwaway fixtures, run before every merge.

```sh
make build
scripts/smoke/run.sh                  # uses .build/release/GoLensApp
scripts/smoke/run.sh path/to/GoLensApp  # another build (a worktree's)
scripts/smoke/run.sh --keep           # keep the fixtures for inspection
SMOKE_PORT=48000 scripts/smoke/run.sh # if 47123/47124 are taken
```

Journeys that drive a real app window share one lock, `/private/tmp/golens-smoke.lock`, taken through `smoke-lock.sh`. A journey that finds the lock held by its own parent (an `until mkdir /private/tmp/golens-smoke.lock …` wrapper or `with-lock.py`) runs inside it instead of waiting for itself; any other holder makes it wait. Wrapping a journey in the lock is therefore safe but not needed.

- Takes about 3–4 minutes. Prints one line per check (PASS / FAIL / KNOWN / PASS*) and exits non-zero on an unexpected failure. Logs and screenshots stay in the printed artifacts folder.
- The app runs as a separate bundle (`dev.golens.test.smoke` prefs domain, reset each run) with `quiet-launch.m` (never activates or takes focus) and `driver.m` (in-process steps; no system-wide input). The owner's `GoLensApp` prefs are never touched.
- `known-failures.txt` lists checks expected to fail until a fix lands. A listed check that passes shows `PASS*`: remove it from the list.
- Journeys: navigator (J1), project switch + terminal folder (J2), hover (J3), rename (J4), completion (J5), close-tab review (J6), external file change (J7), run/stop and run from a subpackage (J8), test summary (J9), debug (J10), issues (J11), conflicted pull and Abort Merge (J12), Dockerfile completion, findings, engine state and compose validation (J13), stage and unstage a hunk (J14), generate a Dockerfile (J15), add a Go module with go get (J16), sqlc Go and SQL jumps, Usages and Run sqlc generate (J17; J17d needs `sqlc` on PATH), toolchain health for a module that needs a newer Go and an outdated gopls (J18).
- `driver.m` here is the versioned copy of the verification driver, with extra steps for the suite (`mark`, `waitfile`, `wininfo`, `outlinesel`, `axexists`, `edited`, `panelkey`, `underline`, `deeplabels`, `lensclick`, `popoverlabels`, `restartls`, `clearline`, `guestsh`, `panelwait`, `wintable` for the visible rows of a list or table in another window).

## Auto-import in the Linux VM

```sh
scripts/smoke/auto-import-journey.sh                       # gopls in the VM, 512 MB guest
AUTOIMPORT_OUT=/tmp/ai scripts/smoke/auto-import-journey.sh  # keep logs, fd.tsv and peak-lsof.txt
```

- Generates a small module under `~/Documents/golens-autoimport` (removed afterwards) that depends on go-redis and uuid, so gopls loads in a 512 MB guest while it still sees the host's full module cache.
- Accepts `errors.Jo`, `strings.Tri`, `redis.NewCl` and, after a gopls restart, `bytes.Equa` and `redis.NewCl` with Tab, and checks that each adds its import. It also runs bare-identifier completions (`err`, `str`, `redis`, `cobr`), reports main-thread stalls and key latency, and checks that the final import block is gofmt-clean.
- Reports how long the completion panel takes to appear after the last key, for selector and bare-identifier completions. Then it stays idle for `STEADY` seconds (default 150) while a guest loop samples `/proc/sys/fs/inode-nr` and `/proc/stat` every 0.5 s. It prints the inode range, the number of cache drops and the guest CPU use.
- Samples the host files held open by the Virtualization process every 2 s (VZ virtiofs keeps one host file open per guest inode; the per-process limit is `kern.maxfilesperproc`, 61,440). Prints the peak and last count and the peak per phase.
- `FRESH_INDEX=1` deletes the container's gopls module-cache index first.

## Typing under gopls load

```sh
MODE=vm WORKLOAD=mesh scripts/smoke/typing-stress-journey.sh          # 74-package generated module, gopls in the VM
MODE=local WORKLOAD=lms scripts/smoke/typing-stress-journey.sh        # copy of ~/Documents/golens-typing-lms, host gopls
MODE=vm WORKLOAD=lms SCENARIO=switch scripts/smoke/typing-stress-journey.sh  # type, open 60 files, type, open 60 more, type
STRESS_OUT=/tmp/stress scripts/smoke/typing-stress-journey.sh          # keep logs, stack samples and the report
```

- `WORKLOAD=mesh` generates a module with `stress-mesh-gen.py`: a hub package imported by every layer, a 16-deep domain chain, generic repositories, services that import each other, uuid, zap and x/sync from the module cache. `WORKLOAD=lms` copies the lms dogfood project. Both live under `~/Documents/golens-stress-<workload>` and are removed afterwards (`KEEP_WORKLOAD=1` keeps them).
- The default scenario types bursts with member completions into a leaf file, then edits a hub declaration (a struct field rename, a generic or widely called signature change, a new interface method), goes straight back to typing while gopls re-checks the dependents, reverts the edit, and ends with hover, an auto-import Tab accept, a large delete with undo and redo, and save. `SCENARIO=input` types the same text through `insertText`, real key events and IME marked text. `SCENARIO=switch` measures typing after opening `SWITCHES` (default 60) and twice as many files.
- `INPUT=keys` types through real `NSEvent` key events (`NSApp.sendEvent`), `INPUT=ime` composes words as marked text. `OWNER_PREFS=1` shows the Gopilot panel and hides inlay hints. `USAGE_COUNTS=off` turns off Settings ▸ Editor ▸ Show Usage Counts. `GIT_REPO=1` makes the copy a git repository first. `RESTART_VM=1` (with `SCENARIO=switch`) ends by running Restart Linux Machine from the command palette, then types again; `RESTART_SETTLE` is the wait in seconds (default 90).
- The report (`stress-report.py`) prints, per phase: key latency from the moment a key was due to the end of its paint (`keystats`), main-thread stalls with the main thread's stack for each stall of 50 ms or more, gopls request latency and outcome per method (from `GOLENS_LSP_TRACE`), diagnostics publishes, host CPU and RSS of the app, gopls and the Virtualization process (`stress-host-sampler.py`), and in the VM the LSP cgroup memory, MemAvailable, swap, gopls RSS and CPU, `memory.high` events and OOM kills (a guest loop started with `guestsh`).
- Driver steps added for it: `keys`/`keysfast` (real key events), `imecode` (marked text), `keystats`, `head`, `redo`; `hangmon` now records the main thread's stack while it is blocked. `VM_AGENT=path` replaces the guest agent in the test container only. `VM_GOPLS=path` does the same for the guest gopls (`typing-journey.sh` takes it too in `MODE=vm`); build one with `scripts/gopls/build.sh <path>`. `DRIVE_STEPS` replaces the whole step list; `guestsh:<command>` runs a guest shell command with the workspace as its working directory.
- The test container starts from default settings, so the VM boots with the 2 GB maximum and runs at 512 MB until gopls needs more; `GOLENS_VM_MEMORY_MB=512` pins it at 512 MB as before.
- `IDLE_TAIL=seconds` ends the run with the app reporting itself inactive (driver step `fakeinactive`) for that long, so the VM's idle memory step-down can be observed. The guest sampler also records the balloon (`nr_balloon_pages`) and the gopls cgroup's `memory.high` and swap, and the report prints the usable guest memory and `memory.high` range per phase.

## Database tools (J-DB)

```sh
scripts/smoke/database-journey.sh                         # SQLite, always
GOLENS_TEST_PG_DSN=postgres://… scripts/smoke/database-journey.sh  # adds the PostgreSQL leg (scripts/db/engines.sh up prints the DSN)
DATABASE_JOURNEY_PERF_ONLY=1 scripts/smoke/database-journey.sh    # only the budget steps
```

- Builds a 1,000,000-row SQLite fixture from `db-fixture/orders.sql` with the system `sqlite3`, opens `console.sql`, and runs as `dev.golens.test.database` with `GOPILOT_CREDENTIAL_STORE=file` and `GOLENS_UNSAVED_RECOVERY=off`. The trap stops the app it started.
- Adds a SQLite data source in Data Sources and tests it, runs a statement, pages and scrolls (`hangmon`, `winwheel`), sorts, Fetch All, scrolls the full result, opens the cell viewer, Stop during Fetch All, DELETE without WHERE (Cancel), Stop on a long query, completion of alias columns, a read-only refusal, the schema outline, and Close Other Tabs and Close Tab with an open transaction. Each state is captured in light and dark.
- Phase 2 steps (DB21–DB31): opens `customers` from the schema outline, filters `country = 'VN'` on the server and counts the matching rows, edits two cells, adds a row (Add Row, then Return on each `DEFAULT` cell), deletes a row, previews the four statements in Submit Changes and submits (checked with `sqlite3`), switches the table to Manual, submits an edit into the open transaction and rolls it back, runs Explain Plan on the join, binds `'; DROP TABLE t; --` as a `:name` value (table `t` must survive), underlines `FROMM` from the SQLite error position, inserts a past statement from Query History… (then undoes it), exports the full 1,000,000-row result to `result.csv` through the save panel while sampling `footprint` (growth ≤ 120 MB, the Fetch All budget), and checks that Detect Data Sources in Project… proposes the fixture's `compose.yaml` PostgreSQL and adds nothing on Cancel. With `GOLENS_TEST_PG_DSN` the PostgreSQL leg also runs Explain Analyze on a `DELETE` and checks the row is still there (DB32). The driver turns `\x3b` in a step argument into a semicolon.
- Budget checks read the app's `[measure]` lines: first rows on warm runs (≤ 50 ms after the core returns), completion p95 (≤ 30 ms), and the main-thread maximum while scrolling the full result (≤ 16 ms). The footprint before scrolling and after Fetch All is printed with DB8.

## Issue capsule under font churn (IC)

```sh
scripts/smoke/issue-capsule-journey.sh                                # uses .build/release/GoLensApp
ISSUE_CAPSULE_ARTIFACTS=/tmp/ic scripts/smoke/issue-capsule-journey.sh  # keep the drive log, app log and screenshots
```

- Takes the shared smoke lock, runs as `dev.golens.test.issuecapsule` with `GOLENS_UNSAVED_RECOVERY=off` on a generated module (host gopls), and types incomplete code right under a method signature so the edited line's lens row draws its issue capsule on every keystroke.
- The driver step `fontchurn:on` keeps a background thread creating and freeing monospaced system fonts. While it runs, AppKit returns nil from `monospacedSystemFont` on other threads, which used to reach CoreText as a nil font and terminate the app. `fontchurn:report` prints how many fonts it created and how many came back nil.
- Checks: the app reaches the end of the journey (IC1), no `NSInvalidArgumentException` in the app log (IC2), the capsule was drawn and clicked (IC3), and the churn was active (IC4).

## Services tab (SV)

```sh
scripts/smoke/services-journey.sh               # engine-down and fake-engine legs, plus the real-engine leg when Docker runs
scripts/smoke/services-journey.sh --keep        # keep the fixture project
SERVICES_JOURNEY_ARTIFACTS=/tmp/sv scripts/smoke/services-journey.sh  # logs, marks, fake-engine requests and screenshots there
```

- Takes the shared smoke lock (`/private/tmp/golens-smoke.lock`), runs as `dev.golens.test.services` with `GOLENS_UNSAVED_RECOVERY=off` and `GOLENS_MEASURE=1`, opens a copy of `services-fixture/project` (Go server, Dockerfile, `compose.yaml` with `api` and `redis`) with `api.go` active, and stops only the app and the fake engine it started. It never starts or quits Docker; Open <provider> is checked, never pressed.
- Engine-down leg: View ▸ Show Services shows "Docker Engine Isn’t Running" with Retry (and Open OrbStack when the context points to OrbStack). With a running engine the leg points `DOCKER_HOST` at a missing socket.
- Fake-engine leg (always): `services-fixture/fake-engine` serves the Engine API on a Unix socket (`DOCKER_HOST`), logs each request with a timestamp, and stops `svcdemo-api-1` on `SIGUSR1` to simulate an external `docker stop`. It covers the list, logs, Details with a masked and a revealed environment value, the exit banner and Start, merged This Project logs, the Remove Container… and Compose Down… confirmations (Cancel), images, Open Shell (a `docker` shim on `PATH` proves that only Open Shell starts a docker process), a Console tab round trip without a reconnect, B3 (show to first list, from the `services first list` measure line), B4 (external stop to the applied batch) and B6 (selection change closes the previous log stream within 1 s; hiding the panel closes the engine connections within 31 s).
- Real-engine leg (only when `docker version` reaches a server): Compose Up from the Tools menu with `api.go` active, logs, masked details, `docker stop` from outside with the exit banner and Start, merged logs, and Compose Down… confirmed; `compose down -v` cleans up afterwards.
