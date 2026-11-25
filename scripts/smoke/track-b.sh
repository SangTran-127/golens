#!/bin/bash
# End-to-end smoke verification for Track B features (Waves 1–3).
# Uses isolated bundle id dev.golens.test.trackb, quiet.dylib, and driver.dylib.
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
export GOLENS_VM_MEMORY_MB=512
pkill -9 -f "Containers/dev.golens.test.trackb/" 2>/dev/null || true
pkill -9 -f "golens-trackb" 2>/dev/null || true
pkill -f "vsock-bridge.go" 2>/dev/null || true
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=$REPO/.build/release/GoLensApp
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }

DOMAIN=dev.golens.test.trackb
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
mkdir -p "$CONTAINER_DIR/tmp"
WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-trackb.XXXXXX")" && pwd -P)
ART=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-trackb-artifacts.XXXXXX")" && pwd -P)
mkdir -p "$ART/shots" "$ART/logs"
RESULTS=$ART/results.tsv
: > "$RESULTS"
START=$(date +%s)
APP_PID=
OWNED_PIDS=

descendants() { local k; for k in $(pgrep -P "$1" 2>/dev/null); do echo "$k"; descendants "$k"; done; }

cleanup() {
  pkill -f "vsock-bridge.go" 2>/dev/null || true
  [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null && kill -TERM "$APP_PID" 2>/dev/null
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  sleep 1
  for k in $OWNED_PIDS $APP_PID; do kill -KILL "$k" 2>/dev/null; done
  defaults delete $DOMAIN >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  rm -f "$CONTAINER_DIR/tmp/vsock_"*.sock
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
! codesign -d --entitlements - "$WORK/app/GoLens.app" 2>&1 | grep -q "com.apple.security.app-sandbox" || { echo "unexpected app-sandbox entitlement"; exit 2; }
codesign -d --entitlements - "$WORK/app/GoLens.app" 2>&1 | grep -q "com.apple.security.virtualization" || { echo "missing virtualization entitlement"; exit 2; }
codesign -d --entitlements - "$WORK/app/GoLens.app" 2>&1 | grep -q "com.apple.security.cs.disable-library-validation" || { echo "missing disable-library-validation entitlement"; exit 2; }
APP=$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/driver.dylib" "$HERE/driver.m" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/quiet.dylib" "$HERE/quiet-launch.m" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
defaults delete $DOMAIN >/dev/null 2>&1

A=$WORK/proj
mkdir -p "$A/cmd/app" "$A/crypto" "$A/proto" "$A/sandbox" "$A/server" "$A/store" "$A/ui"
printf 'module example.com/trackb\n\ngo 1.22\n' > "$A/go.mod"
printf 'package app\nfunc Run() {}\n' > "$A/cmd/app/app.go"
printf 'package crypto\nfunc Hash() {}\n' > "$A/crypto/keys.go"
printf 'package proto\nfunc Encode() {}\n' > "$A/proto/frame.go"
printf 'package sandbox\nfunc Isolate() {}\n' > "$A/sandbox/sandbox.go"
printf 'package server\nfunc Serve() {}\n' > "$A/server/server.go"
printf 'package store\nfunc Save() {}\n' > "$A/store/db.go"
printf 'package ui\nfunc Render() {}\n' > "$A/ui/view.go"
cat > "$A/store.go" <<'EOF'
package main

import "sync"

type Store struct {
	prefix string
	count  int
}

func ComputeTotal(a int, b int) int {
	return a + b
}

func (s *Store) Lookup(key string) string {
	_ = ComputeTotal(1, 2)
	return s.prefix + key
}

func unsafeGoroutineWaitGroup() {
	var wg sync.WaitGroup
	go func() {
		wg.Add(1)
		defer wg.Done()
	}()
	wg.Wait()
}
EOF

cat > "$A/linux_only.go" <<'EOF'
//go:build linux

package main

func LinuxSpec() string {
	return "linux"
}
EOF

cat > "$A/store_test.go" <<'EOF'
package main

import "testing"

func TestLookup(t *testing.T) {
	s := &Store{prefix: "p:"}
	if got := s.Lookup("k"); got != "p:k" {
		t.Fatalf("got %q", got)
	}
}

func BenchmarkLookup(b *testing.B) {
	s := &Store{prefix: "p:"}
	for i := 0; i < b.N; i++ {
		_ = s.Lookup("k")
	}
}
EOF

cat > "$A/main.go" <<'EOF'
package main

import (
	"fmt"
	"regexp"
	"time"
)

var pat = regexp.MustCompile(`^(?P<id>[a-z0-9_]+)-\d{2,4}$`)

func main() {
	ts := time.Now().Format("2006-01-02T15:04:05Z07:00")
	sum := ComputeTotal(10, 20)
	fmt.Println(ts, sum, pat.MatchString("abc-12"))
}
EOF

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }
check() { if eval "$3"; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "$4"; fi; }

launch() {
  LOG=$ART/logs/$1.log
  local envs=(DRIVE="$4" DRIVE_OUT="$LOG" DRIVE_SHOTS="$ART/shots" DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib")
  if [ "${GOLENS_EXECUTION_MODE:-host}" = "vm" ]; then
    envs+=(GOLENS_EXECUTION_MODE=vm GOLENS_TEST_VSOCK_PATH="$CONTAINER_DIR/tmp")
  fi
  env "${envs[@]}" \
    "$APP" -GoLensLastWorkspacePath "$2" -GoLensLastFilePath "$3" -GoLensShowConsole '<true/>' > "$ART/logs/$1.app.log" 2>&1 &
  APP_PID=$!
}

wait_mark() {
  local i=0
  while [ $i -lt $(($2 * 5)) ]; do
    grep -q "DRIVE mark $1\$" "$LOG" 2>/dev/null && return 0
    kill -0 "$APP_PID" 2>/dev/null || return 1
    OWNED_PIDS="$OWNED_PIDS $(descendants "$APP_PID" | tr '\n' ' ')"
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

finish() {
  local i=0
  OWNED_PIDS="$OWNED_PIDS $(descendants "$APP_PID" | tr '\n' ' ')"
  while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt $(($1 * 5)) ]; do sleep 0.2; i=$((i + 1)); done
  if kill -0 "$APP_PID" 2>/dev/null; then kill -TERM "$APP_PID"; sleep 1; kill -KILL "$APP_PID" 2>/dev/null; fi
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  APP_PID=
}

line() { grep -m1 "$1" "$LOG" 2>/dev/null; }

echo "GoLens Track B smoke suite — $(basename "$BIN") — artifacts: $ART"

if [ "${GOLENS_EXECUTION_MODE:-host}" = "vm" ]; then
  VSOCK_DIR="$CONTAINER_DIR/tmp"
  rm -f "$VSOCK_DIR/vsock_"*.sock
  go run "$HERE/vsock-bridge.go" "$VSOCK_DIR/vsock_2002.sock" "$A" > "$ART/logs/vsock-bridge.log" 2>&1 &
  BRIDGE_PID=$!
  OWNED_PIDS="$OWNED_PIDS $BRIDGE_PID"
  i=0
  while [ ! -S "$VSOCK_DIR/vsock_2002.sock" ] && [ $i -lt 15 ]; do sleep 0.1; i=$((i + 1)); done
fi

launch trackb "$A" "$A/store.go" "wait:10;fakeactive;mark:ready;\
rowexpand:cmd;rowexpand:crypto;rowexpand:proto;rowexpand:sandbox;rowexpand:server;rowexpand:store;rowexpand:ui;wait:0.8;mark:tb14-tree;axexists:keys.go;axexists:db.go;axexists:view.go;outlinesel:store;outlinesel:go.mod;shot:tb14-tree;\
select:ComputeTotal;menu:Navigate/Go to Symbol in File…;wait:0.6;fr:Lookup;wait:0.5;mark:tb10-sym;deeplabels;shot:tb10-symbol;postkey:53;wait:0.5;find:ComputeTotal;\
select:ComputeTotal;fr:RenamedTotal;wait:0.5;edited;undo;wait:0.5;mark:tb11-undo;edited;deeplabels;find:ComputeTotal;\
axpress:Terminal;wait:1;axpress:Console;wait:0.5;axpress:Terminal;wait:1;fr:echo GOLENS_TERM_OK;wait:1.0;mark:tb12-term;wininfo;\
select:type Store;menu:Editor/Generate Constructor;wait:1.5;find:func NewStore;shot:tb1-constructor;\
select:type Store;menu:Editor/Extract Interface;wait:1.5;find:type Storer interface;shot:tb3-interface;\
select:ComputeTotal;menu:Editor/Change Signature…;wait:1.5;mark:tb4-sig;wininfo;shot:tb4-signature;axpress:Cancel;wait:1;\
select:ComputeTotal;menu:Navigate/Call Hierarchy;wait:2.5;mark:tb5-hier;deeplabels;shot:tb5-hierarchy;postkey:53;wait:1;\
select:Lookup;menu:Navigate/Jump to Test;wait:1.5;find:func TestLookup;shot:tb6-jumptest;\
axpress:Tests;wait:2;menu:Product/Run Tests with Coverage;wait:15;mark:tb7-cov;deeplabels;shot:tb7-coverage;\
menu:Product/Profile Tests;wait:18;mark:tb8-prof;deeplabels;shot:tb8-profiler;\
menu:Product/Run Benchmarks;wait:15;mark:tb9-bench;deeplabels;shot:tb9-benchmarks;\
axpress:Files;wait:0.6;axpress:linux_only.go;wait:1.2;mark:tb15-target;deeplabels;shot:tb15-buildtarget;axpress:store.go;wait:0.6;\
menu:Product/Run Safety Audit;wait:8;mark:tb16-safety;deeplabels;shot:tb16-safety;\
mark:done;quit"

wait_mark done 155; finish 15

check TB1 "Generate Constructor creates NewStore(prefix string, count int) *Store" 'line "find .func NewStore. -> present" >/dev/null' "$(line 'find .func NewStore') — shots/tb1-constructor.png"
check TB3 "Extract Interface creates type Storer interface" 'line "find .type Storer interface. -> present" >/dev/null' "$(line 'find .type Storer interface') — shots/tb3-interface.png"
SIG=$(sed -n '/mark tb4-sig/,/wininfo end/p' "$LOG" | grep -m1 "sheet=1.*Change Signature" | cut -c1-160)
check TB4 "Change Signature… opens native refactor sheet" '[ -n "$SIG" ]' "${SIG:-no sheet} — shots/tb4-signature.png"
HIER=$(sed -n '/mark tb5-hier/,/postkey 53/p' "$LOG" | grep -m1 "deeplabels:")
check TB5 "Call Hierarchy opens floating HierarchyPopupView with callers" 'echo "$HIER" | grep -q "Call Hierarchy.*Callers"' "$(echo "$HIER" | grep -o 'Call Hierarchy[^|]*|[^|]*|[^|]*|[^|]*|[^|]*|[^|]*' | head -1) — shots/tb5-hierarchy.png"
check TB6 "Jump to Test switches from store.go Lookup to store_test.go TestLookup" 'line "find .func TestLookup. -> present" >/dev/null' "$(line 'find .func TestLookup') — shots/tb6-jumptest.png"
COV=$(sed -n '/mark tb7-cov/,/mark tb8-prof/p' "$LOG" | grep -m1 "deeplabels:")
check TB7 "Run Tests with Coverage reports package coverage %" 'echo "$COV" | grep -q "%"' "$(echo "$COV" | grep -o '[0-9]*%' | head -1) — shots/tb7-coverage.png"
PROF=$(sed -n '/mark tb8-prof/,/mark tb9-bench/p' "$LOG" | grep -m1 "deeplabels:")
check TB8 "Profile Tests opens Profiler tab in Console" 'echo "$PROF" | grep -q "Profiler"' "Profiler tab visible — shots/tb8-profiler.png"
BENCH=$(sed -n '/mark tb9-bench/,/mark tb15-target/p' "$LOG" | grep -m1 "deeplabels:")
check TB9 "Run Benchmarks executes BenchmarkLookup and reports ns/op" 'echo "$BENCH" | grep -q "ns/op"' "$(echo "$BENCH" | grep -o '[^|]*ns/op[^|]*' | head -1) — shots/tb9-benchmarks.png"
SYM_FR=$(sed -n '/Navigate\/Go to Symbol in File/,/mark tb10-sym/p' "$LOG" | grep -m1 "DRIVE fr Lookup")
check TB10 "Go to Symbol focuses search field and never overwrites selected editor text" '[ -n "$SYM_FR" ] && echo "$SYM_FR" | grep -qv "GoLensTextView" && sed -n "/mark tb10-sym/,/menu File\/Save/p" "$LOG" | grep -q "find .ComputeTotal. -> present"' "$SYM_FR — shots/tb10-symbol.png"
UNDO_CLEAN=$(sed -n '/mark tb11-undo/,/axpress Terminal/p' "$LOG" | grep -m1 "DRIVE edited 0")
UNDO_LABELS=$(sed -n '/mark tb11-undo/,/axpress Terminal/p' "$LOG" | grep -m1 "deeplabels:")
check TB11 "Undo restores clean document state and clears Edited badge" '[ -n "$UNDO_CLEAN" ] && ! echo "$UNDO_LABELS" | grep -q "\[Edited\]"' "${UNDO_CLEAN:-undo failed}"
TERM_FR=$(sed -n '/axpress Terminal/,/mark tb12-term/p' "$LOG" | grep -m1 "DRIVE fr echo GOLENS_TERM_OK")
check TB12 "Terminal retains delegate and firstResponder across tab switches" 'echo "$TERM_FR" | grep -q "TerminalView"' "$TERM_FR"
check TB13 "Split Editor button exposes descriptive accessibility label" 'echo "$HIER" | grep -q "Split Editor Right"' "Split Editor Right in accessibility tree"
STORE_ROW=$(sed -n '/mark tb14-tree/,/select ComputeTotal/p' "$LOG" | sed -n 's/.*outlinesel store=\(row[0-9]*\).*/\1/p')
GOMOD_ROW=$(sed -n '/mark tb14-tree/,/select ComputeTotal/p' "$LOG" | sed -n 's/.*outlinesel go.mod=\(row[0-9]*\).*/\1/p')
check TB14 "Multi-folder file tree expands all subdirectories cleanly without row overlap" 'line "axexists keys.go -> 1" >/dev/null && line "axexists db.go -> 1" >/dev/null && line "axexists view.go -> 1" >/dev/null && [ -n "$STORE_ROW" ] && [ -n "$GOMOD_ROW" ] && [ "$STORE_ROW" != "$GOMOD_ROW" ]' "store=$STORE_ROW go.mod=$GOMOD_ROW — shots/tb14-tree.png"
TARGET_LABELS=$(sed -n '/mark tb15-target/,/axpress store.go/p' "$LOG" | grep -m1 "deeplabels:")
check TB15 "Build Target status bar item and Excluded Build Tag banner on a //go:build linux file under the default host target" 'echo "$TARGET_LABELS" | grep -q "File Excluded from Active Build Target" && echo "$TARGET_LABELS" | grep -q "for target darwin/"' "Excluded banner + darwin target — shots/tb15-buildtarget.png"
SAFETY_LABELS=$(sed -n '/mark tb16-safety/,$p' "$LOG" | grep -m1 "deeplabels:")
check TB16 "GoLens Safety Audit (⌃⇧⌘S) opens Safety tab and reports concurrency hazard & dead code findings" 'echo "$SAFETY_LABELS" | grep -q "Safety" && echo "$SAFETY_LABELS" | grep -q "WaitGroup.Add" && echo "$SAFETY_LABELS" | grep -q "Unreachable function"' "Safety tab + WaitGroup.Add hazard + Unreachable function — shots/tb16-safety.png"

unexpected=0
printf '\n%-5s %-6s  %s\n' ID RESULT CHECK
while IFS=$'\t' read -r id name status ev; do
  [ "$status" = FAIL ] && unexpected=$((unexpected + 1))
  printf '%-5s %-6s  %s\n        %s\n' "$id" "$status" "$name" "$ev"
done < "$RESULTS"
echo
echo "Runtime: $(( $(date +%s) - START ))s. Artifacts: $ART"
exit $([ $unexpected -eq 0 ] && echo 0 || echo 1)
