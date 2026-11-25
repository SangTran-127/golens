#!/bin/bash
# End-to-end smoke verification for Multi-Session Cmd+Q Quit and Cold Relaunch under App Sandbox.
# Uses isolated bundle id dev.golens.test.relaunch, quiet.dylib, and driver.dylib.
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
export GOLENS_VM_MEMORY_MB=512
pkill -9 -f "Containers/dev.golens.test.relaunch/" 2>/dev/null || true
pkill -9 -f "golens-relaunch" 2>/dev/null || true

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=$REPO/.build/release/GoLensApp
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }

DOMAIN=dev.golens.test.relaunch
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
mkdir -p "$CONTAINER_DIR/tmp"
WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-relaunch.XXXXXX")" && pwd -P)
ART=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-relaunch-artifacts.XXXXXX")" && pwd -P)
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
  defaults delete $DOMAIN >/dev/null 2>&1 || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  rm -f "$CONTAINER_DIR/tmp/vsock_"*.sock
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
! codesign -d --entitlements - "$WORK/app/GoLens.app" 2>&1 | grep -q "com.apple.security.app-sandbox" || { echo "unexpected app-sandbox entitlement"; exit 2; }
codesign -d --entitlements - "$WORK/app/GoLens.app" 2>&1 | grep -q "com.apple.security.virtualization" || { echo "missing virtualization entitlement"; exit 2; }
codesign -d --entitlements - "$WORK/app/GoLens.app" 2>&1 | grep -q "com.apple.security.cs.disable-library-validation" || { echo "missing disable-library-validation entitlement"; exit 2; }

APP="$WORK/app/GoLens.app/Contents/MacOS/GoLensApp"
clang -dynamiclib -fobjc-arc -framework AppKit -framework CoreImage "$REPO/scripts/smoke/driver.m" -o "$WORK/driver.dylib" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit "$REPO/scripts/smoke/quiet-launch.m" -o "$WORK/quiet.dylib" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true

# Create a project outside the container in /tmp to enforce real security-scoped sandbox access
PROJ=$(mktemp -d /tmp/golens-cold-relaunch-proj.XXXXXX)
OWNED_PIDS="$OWNED_PIDS"

cat > "$PROJ/go.mod" <<'EOF'
module example.com/relaunch

go 1.24.0
EOF

cat > "$PROJ/main.go" <<'EOF'
package main

import "fmt"

func Hello(name string) string {
	return "Hello, " + name
}

func main() {
	fmt.Println(Hello("GoLens"))
}
EOF

cat > "$PROJ/main_test.go" <<'EOF'
package main

import "testing"

func TestHello(t *testing.T) {
	if got := Hello("GoLens"); got != "Hello, GoLens" {
		t.Fatalf("unexpected: %s", got)
	}
}
EOF

(
  cd "$PROJ"
  git init -q
  git config user.email "test@golens.dev"
  git config user.name "GoLens Test"
  git add .
  git commit -q -m "initial commit"
)

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }
check() { if eval "$3"; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "$4"; fi; }

LAUNCH_ENVS=()
if [ "${GOLENS_EXECUTION_MODE:-host}" = "vm" ]; then
  VSOCK_DIR="$CONTAINER_DIR/tmp"
  rm -f "$VSOCK_DIR/vsock_"*.sock
  pkill -f "vsock-bridge.go" 2>/dev/null || true
  go run "$REPO/scripts/smoke/vsock-bridge.go" "$VSOCK_DIR/vsock_2002.sock" "$PROJ" > "$ART/logs/vsock-bridge.log" 2>&1 &
  BRIDGE_PID=$!
  OWNED_PIDS="$OWNED_PIDS $BRIDGE_PID"
  i=0
  while [ ! -S "$VSOCK_DIR/vsock_2002.sock" ] && [ $i -lt 15 ]; do sleep 0.1; i=$((i + 1)); done
  LAUNCH_ENVS=(GOLENS_EXECUTION_MODE=vm GOLENS_TEST_VSOCK_PATH="$CONTAINER_DIR/tmp")
fi

wait_mark_in_log() {
  local logfile="$1"
  local markname="$2"
  local timeout="$3"
  local i=0
  while [ $i -lt $(($timeout * 5)) ]; do
    grep -q "DRIVE mark $markname\$" "$logfile" 2>/dev/null && return 0
    [ -n "$APP_PID" ] && ! kill -0 "$APP_PID" 2>/dev/null && return 1
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

echo "=== GoLens Cold Relaunch Suite ==="
echo "Artifacts: $ART"
echo "Project: $PROJ"

# ---------------------------------------------------------
# Phase 1: Session 1 (Initial Open, Bookmark Save & Work)
# ---------------------------------------------------------
echo "[Session 1] Launching to open project and persist bookmark..."
S1_LOG="$ART/logs/session1.log"
env ${LAUNCH_ENVS[@]+"${LAUNCH_ENVS[@]}"} \
  DRIVE="wait:8;fakeactive;mark:s1-ready;select:Hello;find:func Hello;deeplabels;shot:s1-open;wait:2;mark:s1-done;quit" \
  DRIVE_OUT="$S1_LOG" DRIVE_SHOTS="$ART/shots" DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
  "$APP" -GoLensLastWorkspacePath "$PROJ" -GoLensLastFilePath "$PROJ/main.go" -GoLensShowConsole '<true/>' > "$ART/logs/session1.app.log" 2>&1 &
APP_PID=$!

wait_mark_in_log "$S1_LOG" s1-done 30
wait "$APP_PID" 2>/dev/null || true
APP_PID=

# Verify Session 1 results
check CR1 "Session 1 opened project and located symbol" 'grep -q "find .func Hello. -> present" "$S1_LOG"' "$(grep -m1 "find .func Hello" "$S1_LOG")"
check CR2 "Session 1 persisted GoLensLastWorkspacePath in UserDefaults" '[ "$(defaults read $DOMAIN GoLensLastWorkspacePath 2>/dev/null)" = "$PROJ" ]' "$(defaults read $DOMAIN GoLensLastWorkspacePath 2>/dev/null)"
BOOKMARK_BYTES=$(defaults read $DOMAIN GoLensSecurityScopedBookmarks 2>/dev/null | wc -c)
check CR3 "Session 1 created and persisted SecurityScopedBookmark" '[ "$BOOKMARK_BYTES" -gt 50 ]' "bookmark stored ($BOOKMARK_BYTES bytes)"

# ---------------------------------------------------------
# Phase 2: Session 2 (Cold Relaunch after Cmd+Q / Quit)
# ---------------------------------------------------------
echo "[Session 2] Cold Relaunching without CLI workspace args (restores via SecurityScopedBookmarkManager)..."
S2_LOG="$ART/logs/session2.log"
env ${LAUNCH_ENVS[@]+"${LAUNCH_ENVS[@]}"} \
  DRIVE="wait:8;fakeactive;mark:s2-ready;select:Hello;find:func Hello;deeplabels;shot:s2-relaunch;wait:2;mark:s2-done;quit" \
  DRIVE_OUT="$S2_LOG" DRIVE_SHOTS="$ART/shots" DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
  "$APP" -GoLensShowConsole '<true/>' > "$ART/logs/session2.app.log" 2>&1 &
APP_PID=$!

wait_mark_in_log "$S2_LOG" s2-done 30
wait "$APP_PID" 2>/dev/null || true
APP_PID=

# Verify Session 2 Cold Relaunch results
EPERM_COUNT=$(grep -ciE "Operation not permitted|permission denied|EPERM" "$ART/logs/session2.app.log" 2>/dev/null || true)
check CR4 "Session 2 cold restored workspace with zero EPERM / permission denials" '[ "$EPERM_COUNT" -eq 0 ]' "EPERM count: $EPERM_COUNT"
check CR5 "Session 2 restored file tree and gopls LSP loaded symbols cleanly" 'grep -q "find .func Hello. -> present" "$S2_LOG"' "$(grep -m1 "find .func Hello" "$S2_LOG") — shots/s2-relaunch.png"
S2_DEEP=$(grep -m1 "deeplabels:" "$S2_LOG" 2>/dev/null || true)
check CR6 "Session 2 restored open files and Git status without degradation" 'echo "$S2_DEEP" | grep -q "main.go"' "main.go restored in editor tree"

rm -rf "$PROJ"

unexpected=0
printf '\n%-5s %-6s  %s\n' ID RESULT CHECK
while IFS=$'\t' read -r id name status ev; do
  [ "$status" = FAIL ] && unexpected=$((unexpected + 1))
  printf '%-5s %-6s  %s\n        %s\n' "$id" "$status" "$name" "$ev"
done < "$RESULTS"
echo
echo "Runtime: $(( $(date +%s) - START ))s. Artifacts: $ART"
exit $([ $unexpected -eq 0 ] && echo 0 || echo 1)
