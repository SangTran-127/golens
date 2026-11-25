#!/bin/bash
# Unsaved edits survive a crash: type into a file, kill the app, relaunch and restore.
# Uses the isolated bundle id dev.golens.test.crashrecovery, quiet.dylib and driver.dylib.
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_VM_MEMORY_MB=512
pkill -9 -f "Containers/dev.golens.test.crashrecovery/" 2>/dev/null || true
pkill -9 -f "golens-crashrecovery" 2>/dev/null || true

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=$REPO/.build/release/GoLensApp
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }

DOMAIN=dev.golens.test.crashrecovery
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
mkdir -p "$CONTAINER_DIR/tmp"
WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-crashrecovery.XXXXXX")" && pwd -P)
ART=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-crashrecovery-artifacts.XXXXXX")" && pwd -P)
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

RECOVERY="$HOME/Library/Application Support/$DOMAIN/UnsavedBuffers"
rm -rf "$RECOVERY"
PROJ=$(cd "$(mktemp -d "$WORK/proj.XXXXXX")" && pwd -P)
printf 'module example.com/recovery\n\ngo 1.24.0\n' > "$PROJ/go.mod"
printf 'package main\n\nimport "fmt"\n\nfunc main() {\n\tfmt.Println("hello")\n}\n' > "$PROJ/main.go"
cp "$PROJ/main.go" "$WORK/main.go.orig"

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }
check() { if eval "$3"; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "$4"; fi; }
wait_mark() { local i=0; while [ $i -lt $(($3 * 5)) ]; do grep -q "DRIVE mark $2\$" "$1" 2>/dev/null && return 0; sleep 0.2; i=$((i + 1)); done; return 1; }
launch() { # log steps
  DRIVE="$2" DRIVE_OUT="$1" DRIVE_SHOTS="$ART/shots" DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
    "$APP" -GoLensLastWorkspacePath "$PROJ" -GoLensLastFilePath "$PROJ/main.go" > "$1.app" 2>&1 &
  APP_PID=$!
}

# Session 1: type, give the journal time to write, then crash
S1=$ART/logs/session1.log
launch "$S1" 'wait:8;fakeactive;caret:fmt.Println("hello");code:\n;type:// unsaved-crash-marker;wait:4;edited;mark:typed;wait:30'
wait_mark "$S1" typed 40
kill -9 "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=
check CRR1 "Typing leaves the file edited and a recovery copy appears within a few seconds" \
  'grep -q "edited 1" "$S1" && grep -rqs "unsaved-crash-marker" "$RECOVERY/live"' "$(ls "$RECOVERY/live" 2>/dev/null | wc -l | tr -d ' ') recovery file(s)"
check CRR2 "The crash leaves the file on disk unchanged" 'cmp -s "$PROJ/main.go" "$WORK/main.go.orig"' ""

# Session 2: relaunch, the app offers to restore, Restore brings the edit back unsaved
S2=$ART/logs/session2.log
launch "$S2" 'wait:9;fakeactive;sheetshot:restore-light;darkmode;wait:0.8;sheetshot:restore-dark;lightmode;wait:0.4;sheetpress:Restore;wait:2;find:unsaved-crash-marker;edited;undotitle;shot:restored;mark:done;wait:30'
wait_mark "$S2" done 40
kill -9 "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=
check CRR3 "Relaunch asks Restore Unsaved Changes? with Restore and Discard Changes" \
  'grep -q "sheetpress Restore -> 1 (buttons: Discard Changes)" "$S2"' "$(grep -m1 "sheetpress" "$S2") — shots/restore-light.png, shots/restore-dark.png"
check CRR4 "Restore puts the unsaved edit back in the editor, marked edited, as one undo step" \
  'grep -q "find .unsaved-crash-marker. -> present" "$S2" && grep -q "edited 1" "$S2" && grep -q "Restore Unsaved Changes" "$S2"' "$(grep -m1 "undotitle" "$S2") — shots/restored.png"
check CRR5 "The file on disk is still unchanged until the person saves" 'cmp -s "$PROJ/main.go" "$WORK/main.go.orig"' ""

# Session 3: a decided recovery is not offered again
S3=$ART/logs/session3.log
rm -rf "$RECOVERY/live"
launch "$S3" 'wait:9;fakeactive;mark:done;wait:30'
wait_mark "$S3" done 30
kill -9 "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=
check CRR6 "A recovery that was decided is not offered again" '[ -z "$(ls "$RECOVERY/pending" 2>/dev/null)" ] && ! grep -q "Restore Unsaved" "$S3"' "$(ls "$RECOVERY/pending" 2>/dev/null | wc -l | tr -d ' ') pending"
rm -rf "$RECOVERY"

fail=0
printf '\n%-5s %-6s  %s\n' ID RESULT CHECK
while IFS=$'\t' read -r id name status ev; do
  [ "$status" = FAIL ] && fail=$((fail + 1))
  printf '%-5s %-6s  %s\n        %s\n' "$id" "$status" "$name" "$ev"
done < "$RESULTS"
echo
echo "Runtime: $(( $(date +%s) - START ))s. Artifacts: $ART"
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
