#!/bin/zsh
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off

HERE=${0:A:h}
REPO=${HERE:h:h}
BIN=$REPO/.build/release/GoLensApp
KEEP=0
for a in "$@"; do
  case $a in
    --keep) KEEP=1 ;;
    *) BIN=$a ;;
  esac
done
if [ ! -x "$BIN" ]; then
  echo "missing binary: $BIN (run GOLENS_CANONICAL_BUILD=0 make build)"
  exit 2
fi

LOCK=/private/tmp/golens-smoke.lock
. "$(cd "$(dirname "$0")" && pwd)/smoke-lock.sh"
smoke_lock_acquire

DOMAIN=dev.golens.test.dbgqf
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
mkdir -p "$CONTAINER_DIR/tmp"
WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-dbgqf.XXXXXX")" && pwd -P)
ART=${DEBUG_QUICKFIX_ARTIFACTS:-$(mktemp -d "$CONTAINER_DIR/tmp/golens-dbgqf-artifacts.XXXXXX")}
mkdir -p "$ART/shots" "$ART/logs"
RESULTS=$ART/results.tsv
: > "$RESULTS"
START=$(date +%s)
APP_PID=
OWNED_PIDS=
CLIP_SAVED=0
if pbpaste > "$WORK/clipboard.txt" 2>/dev/null; then
  CLIP_SAVED=1
fi

cleanup() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    sleep 1
    kill -KILL "$APP_PID" 2>/dev/null || true
  fi
  for k in ${=OWNED_PIDS}; do
    kill -TERM "$k" 2>/dev/null || true
    kill -KILL "$k" 2>/dev/null || true
  done
  if [ "$CLIP_SAVED" = 1 ]; then
    pbcopy < "$WORK/clipboard.txt" 2>/dev/null || true
  fi
  defaults delete "$DOMAIN" >/dev/null 2>&1 || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  if [ "$KEEP" = 1 ]; then
    echo "kept artifacts: $WORK $ART"
  else
    rm -rf "$WORK"
  fi
  smoke_lock_release
}
trap cleanup EXIT INT TERM

BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
APP="$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")"
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/driver.dylib" "$HERE/driver.m" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/quiet.dylib" "$HERE/quiet-launch.m" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
defaults delete "$DOMAIN" >/dev/null 2>&1 || true

QF=$WORK/qf
DBG=$WORK/dbg
mkdir -p "$QF" "$DBG"

cat > "$QF/go.mod" <<'EOF'
module example.com/quickfix

go 1.24
EOF

cat > "$QF/service.go" <<'EOF'
package quickfix

import (
	"database/sql"
	"errors"
	"os"
	"sync"
	"time"
)

func LoadEarlyReturn(path string, fail bool) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	if fail {
		return errors.New("failed")
	}
	buf := make([]byte, 4)
	_, _ = f.Read(buf)
	_ = f.Close()
	return nil
}

func BeginOrderTx(db *sql.DB, ok bool) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	if !ok {
		return errors.New("bad")
	}
	return tx.Commit()
}

func Heartbeat(done <-chan struct{}) {
	ticker := time.NewTicker(time.Second)
	select {
	case <-ticker.C:
	case <-done:
	}
}

func BumpCounter(mu *sync.Mutex, n *int) {
	mu.Lock()
	*n++
}

func InspectRoot(dir string) error {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return err
	}
	_, err = root.Stat(".")
	return err
}
EOF

cat > "$QF/edge.go" <<'EOF'
package quickfix

import (
	"net/http"
	"os"
)

func LoopFiles(paths []string) error {
	for _, p := range paths {
		f, err := os.Open(p)
		if err != nil {
			return err
		}
		_ = f
	}
	return nil
}

func FetchStatus(url string) (int, error) {
	resp, err := http.Get(url)
	if err != nil {
		return 0, err
	}
	return resp.StatusCode, nil
}
EOF

cat > "$DBG/go.mod" <<'EOF'
module example.com/dbg

go 1.24
EOF

cat > "$DBG/main.go" <<'EOF'
package main

import "fmt"

func compute(a, b int) int {
	total := a*10 + b
	return total * 2
}

func main() {
	n := compute(2, 3)
	fmt.Println("result", n)
}
EOF

descendants() {
  local k
  for k in $(pgrep -P "$1" 2>/dev/null); do
    echo "$k"
    descendants "$k"
  done
}

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }
check() { if eval "$3"; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "$4"; fi; }
after() { sed -n "/mark $1\$/,\$p" "$LOG" | grep -m1 "$2" | cut -c1-${3:-400}; }
found() { sed -n "/mark $1\$/,\$p" "$LOG" | grep -A2 -m1 -F "find '$2" | grep -m1 -o "present\|absent"; }
labels() { after "$1" "deeplabels:" 6000; }
winof() { sed -n "/mark $1\$/,\$p" "$LOG" | grep -m5 "DRIVE win class=" | cut -c1-1200; }

wait_mark() {
  local i=0
  local limit=$(($2 * 5))
  while [ "$i" -lt "$limit" ]; do
    grep -q "DRIVE mark $1\$" "$LOG" 2>/dev/null && return 0
    kill -0 "$APP_PID" 2>/dev/null || return 1
    OWNED_PIDS="$OWNED_PIDS $(descendants "$APP_PID" | tr '\n' ' ')"
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

finish() {
  local i=0
  local limit=$(($1 * 5))
  OWNED_PIDS="$OWNED_PIDS $(descendants "$APP_PID" | tr '\n' ' ')"
  while kill -0 "$APP_PID" 2>/dev/null && [ "$i" -lt "$limit" ]; do
    sleep 0.2
    i=$((i + 1))
  done
  if kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    sleep 1
    kill -KILL "$APP_PID" 2>/dev/null || true
  fi
  for k in ${=OWNED_PIDS}; do
    kill -TERM "$k" 2>/dev/null || true
  done
  APP_PID=
}

launch() {
  LOG="$ART/logs/$1.log"
  GOLENS_MEASURE=1 DRIVE="$4" DRIVE_OUT="$LOG" DRIVE_SHOTS="$ART/shots" DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
    "$APP" -GoLensLastWorkspacePath "$2" -GoLensLastFilePath "$3" > "$ART/logs/$1.app.log" 2>&1 &
  APP_PID=$!
}

echo "GoLens debug & quickfix journey — $(basename "$BIN") — artifacts: $ART"

QF_STEPS="wait:12;fakeactive;mark:ready;wait:12;caret:package quickfix;\
menu:Navigate/Next Issue;wait:1.2;mark:dq1-open;edstate:dq1-open;wininfo;\
darkmode;wait:0.6;panelshot:qf-popup-dark;shot:qf-main-dark;\
lightmode;wait:0.6;panelshot:qf-popup-light;shot:qf-main-light;darkmode;wait:0.4;\
postkey:36;wait:1.0;mark:dq2-fixed;find:defer f.Close();find:_ = f.Close();\
undo;wait:0.5;mark:dq2-undo;find:defer f.Close();find:_ = f.Close();\
redo;wait:0.5;mark:dq2-redo;find:defer f.Close();find:_ = f.Close();save;wait:1.5;\
menu:Navigate/Next Issue;wait:1.2;mark:dq3-tx-pop;wininfo;postkey:36;wait:0.8;\
menu:Navigate/Next Issue;wait:1.2;mark:dq3-tick-pop;wininfo;postkey:36;wait:0.8;\
menu:Navigate/Next Issue;wait:1.2;mark:dq3-mu-pop;wininfo;postkey:36;wait:0.8;\
menu:Navigate/Next Issue;wait:1.2;mark:dq3-root-pop;wininfo;postkey:36;wait:0.8;\
save;wait:6;menu:Navigate/Next Issue;wait:1.2;mark:dq3-clean;deeplabels;\
axpress:edge.go;wait:6;issueclick:f, err := os.Open(p);wait:1.2;mark:dq3-loop;wininfo;postkey:53;wait:0.5;\
issueclick:resp, err := http.Get(url);wait:1.2;mark:dq3-http;wininfo;postkey:53;wait:0.4;\
mark:done;quit"

launch qf "$QF" "$QF/service.go" "$QF_STEPS"
wait_mark done 180; finish 20
QF_VET=$(cd "$QF" && go vet ./... 2>&1 || true)

printf 'debug-quickfix-sentinel' | pbcopy
DBG_STEPS="wait:10;fakeactive;mark:ready;bpclick:n := compute(2, 3);wait:0.5;\
menu:Product/Debug;waitlabel:main.main;wait:1;mark:dq4-paused;deeplabels;\
menu:Debug/Step Into;waitlabel:main.compute;wait:1;mark:dq4-into;deeplabels;edstate:dq4-into;\
menu:Debug/Step Over;wait:1.5;mark:dq4-over;edstate:dq4-over;\
menu:Debug/Evaluate Expression…;wait:0.8;focus;fr:a*10+b;frkey:insertNewline:;wait:2;mark:dq5-eval;axfind:a*10+b;axfind:23;\
menu:Debug/Copy Goroutine Dump;wait:1.2;mark:dq5-dump;pasteboard;\
darkmode;wait:0.6;shot:dbg-paused-dark;lightmode;wait:0.6;shot:dbg-paused-light;darkmode;wait:0.4;\
menu:Debug/Step Out;waitlabel:main.main;wait:1;mark:dq5-out;deeplabels;\
menu:Product/Stop;wait:2;mark:dq5-stopped;menustate:Debug/Pause;mark:done;quit"

launch dbg "$DBG" "$DBG/main.go" "$DBG_STEPS"
wait_mark done 180; finish 20

LOG="$ART/logs/qf.log"
check DQ1 "Next Issue lands on early-return os.Open and opens IssuePopupView with inline safety diagnostics" \
  'after dq1-open "edstate dq1-open" | grep -q "os.Open(path)" && winof dq1-open | grep -q "Add defer f.Close()"' \
  "$(after dq1-open "edstate dq1-open") / $(winof dq1-open | cut -c1-120)"

check DQ2 "Return applies Add defer f.Close(), removes redundant _ = f.Close(), supports Undo/Redo, and passes go vet" \
  '[ "$(found dq2-fixed "defer f.Close()")" = present ] && [ "$(found dq2-fixed "_ = f.Close()")" = absent ] && [ "$(found dq2-undo "defer f.Close()")" = absent ] && [ "$(found dq2-undo "_ = f.Close()")" = present ] && [ "$(found dq2-redo "defer f.Close()")" = present ] && [ "$(found dq2-redo "_ = f.Close()")" = absent ] && [ -z "$QF_VET" ]' \
  "fixed=$(found dq2-fixed "defer f.Close()")/$(found dq2-fixed "_ = f.Close()"), undo=$(found dq2-undo "_ = f.Close()"), redo=$(found dq2-redo "defer f.Close()"), vet=${QF_VET:-ok}"

check DQ3 "Rollback, Ticker, Unlock, OpenRoot fixes apply cleanly, clean file shows No issues in this file., loop refuses defer, and HTTP avoids duplicates" \
  'winof dq3-tx-pop | grep -q "Add defer tx.Rollback()" && winof dq3-tick-pop | grep -q "Add defer ticker.Stop()" && winof dq3-mu-pop | grep -q "Add defer mu.Unlock()" && winof dq3-root-pop | grep -q "Add defer root.Close()" && labels dq3-clean | grep -q "No issues in this file." && ! winof dq3-loop | grep -q "Add defer f.Close()" && [ "$(winof dq3-http | grep -o "Add defer resp.Body.Close()" | wc -l | tr -d " ")" = "1" ]' \
  "clean=$(labels dq3-clean | grep -o "No issues in this file."), http_count=$(winof dq3-http | grep -o "Add defer resp.Body.Close()" | wc -l | tr -d " ")"

LOG="$ART/logs/dbg.log"
gor() { labels "$1" | grep -o "Goroutine #[^|]*" | head -1 | cut -c1-120; }
LINE_INTO=$(after dq4-into "edstate dq4-into" | grep -o "line=[0-9]*" | head -1 | cut -d= -f2)
LINE_OVER=$(after dq4-over "edstate dq4-over" | grep -o "line=[0-9]*" | head -1 | cut -d= -f2)

check DQ4 "Product > Debug hits breakpoint in main.main, Step Into enters main.compute, and Step Over advances inside main.compute" \
  'gor dq4-paused | grep -q "main.main" && gor dq4-into | grep -q "main.compute" && [ -n "$LINE_INTO" ] && [ -n "$LINE_OVER" ] && [ "$LINE_OVER" -gt "$LINE_INTO" ]' \
  "$(gor dq4-paused) -> $(gor dq4-into) line $LINE_INTO -> $LINE_OVER"

check DQ5 "Evaluate or add watch resolves a*10+b=23, Copy Goroutine Dump captures main.compute, Step Out returns to main.main, and Stop disables Pause" \
  'after dq5-eval "axfind 23" | grep -qE "(: |‖ )23( ‖|$)" && after dq5-dump "DRIVE pasteboard" | grep -q "main.compute" && ! after dq5-dump "DRIVE pasteboard" | grep -q "debug-quickfix-sentinel" && gor dq5-out | grep -q "main.main" && after dq5-stopped "menustate Debug/Pause" | grep -q "enabled=0"' \
  "eval=$(after dq5-eval "axfind 23" | cut -c7-80), out=$(gor dq5-out)"

echo
echo "=== Debug & Quick-Fix Journey Results ==="
cat "$RESULTS"
FAILS=$(grep -c $'\tFAIL\t' "$RESULTS" || true)
PASSES=$(grep -c $'\tPASS\t' "$RESULTS" || true)
ELAPSED=$(($(date +%s) - START))
echo "Summary: $PASSES passed, $FAILS failed (${ELAPSED}s) — artifacts: $ART"
[ "$FAILS" = 0 ]
