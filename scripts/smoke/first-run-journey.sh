#!/bin/bash
# First run: with tools missing, the welcome window lists Go, gopls, Git and Delve with a way to install each;
# with every tool present it shows Get Started, whose five tasks check themselves when done in a real project.
# Uses the isolated bundle id dev.golens.test.firstrun, quiet.dylib and driver.dylib.
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
export GOLENS_VM_MEMORY_MB=512
pkill -9 -f "Containers/dev.golens.test.firstrun/" 2>/dev/null || true
pkill -9 -f "golens-firstrun" 2>/dev/null || true

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=$REPO/.build/release/GoLensApp
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }

DOMAIN=dev.golens.test.firstrun
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
mkdir -p "$CONTAINER_DIR/tmp"
WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-firstrun.XXXXXX")" && pwd -P)
ART=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-firstrun-artifacts.XXXXXX")" && pwd -P)
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

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }
check() { if eval "$3"; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "$4"; fi; }
wait_mark() { local i=0; while [ $i -lt $(($3 * 5)) ]; do grep -q "DRIVE mark $2\$" "$1" 2>/dev/null && return 0; sleep 0.2; i=$((i + 1)); done; return 1; }

# Missing gopls and Delve: the checklist names them with Install, and Go and Git as installed
L1=$ART/logs/missing.log
GOLENS_DEV_MISSING_TOOLS=gopls,dlv DRIVE="wait:6;fakeactive;mark:ready;winlabels:Welcome to GoLens;winshot:Welcome to GoLens|firstrun-light;darkmode;wait:0.8;winshot:Welcome to GoLens|firstrun-dark;lightmode;mark:done;wait:20" \
  DRIVE_OUT="$L1" DRIVE_SHOTS="$ART/shots" DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" "$APP" > "$L1.app" 2>&1 &
APP_PID=$!
wait_mark "$L1" done 40
kill -TERM "$APP_PID" 2>/dev/null; sleep 1; kill -9 "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=
LABELS=$(grep -m1 "winlabels" "$L1")
check FR1 "With gopls and Delve missing the welcome window shows Set Up Your Mac for Go with an Install button for each" \
  'echo "$LABELS" | grep -q "Set Up Your Mac for Go" && echo "$LABELS" | grep -q "gopls, not installed" && echo "$LABELS" | grep -q "Delve, not installed" && [ "$(echo "$LABELS" | grep -o "Install" | wc -l)" -ge 2 ]' "shots/firstrun-light.png, shots/firstrun-dark.png"
check FR2 "Go and Git show as installed with Check Again" \
  'echo "$LABELS" | grep -q "Go, installed" && echo "$LABELS" | grep -q "Git, installed" && echo "$LABELS" | grep -q "Check Again"' ""

# Nothing missing: no setup checklist; Get Started instead, which Hide removes and Help > Get Started brings back
L2=$ART/logs/complete.log
DRIVE="wait:6;fakeactive;winlabels:Welcome to GoLens;winshot:Welcome to GoLens|getstarted-light;darkmode;wait:0.8;winshot:Welcome to GoLens|getstarted-dark;lightmode;\
axpress:Hide;wait:1;mark:hidden;winlabels:Welcome to GoLens;menu:Help/Get Started;wait:1.5;mark:shown;winlabels:Welcome to GoLens;mark:done;wait:20" \
  DRIVE_OUT="$L2" DRIVE_SHOTS="$ART/shots" DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" "$APP" > "$L2.app" 2>&1 &
APP_PID=$!
wait_mark "$L2" done 40
kill -TERM "$APP_PID" 2>/dev/null; sleep 1; kill -9 "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=
check FR3 "With every tool installed the welcome window shows no setup checklist" '! grep -q "Set Up Your Mac for Go" "$L2" && grep -q "winlabels" "$L2"' ""
FIRST=$(grep -m1 "winlabels" "$L2")
HIDDEN=$(sed -n '/mark hidden$/,$p' "$L2" | grep -m1 "winlabels")
SHOWN=$(sed -n '/mark shown$/,$p' "$L2" | grep -m1 "winlabels")
check FR4 "A new user sees Get Started with five tasks, none done" \
  'echo "$FIRST" | grep -q "Get Started" && echo "$FIRST" | grep -q "0 of 5 done" && echo "$FIRST" | grep -q "Open a Go Project, not done" && echo "$FIRST" | grep -q "Go to a Definition, not done" && echo "$FIRST" | grep -q "Run a Test from the Gutter, not done" && echo "$FIRST" | grep -q "Stop at a Breakpoint, not done" && echo "$FIRST" | grep -q "Find Any Command, not done"' "shots/getstarted-light.png, shots/getstarted-dark.png"
check FR5 "Hide removes Get Started and Help > Get Started shows it again" \
  '[ -n "$HIDDEN" ] && ! echo "$HIDDEN" | grep -q "0 of 5 done" && echo "$SHOWN" | grep -q "0 of 5 done"' ""

# Each task checks itself when the person does it in a real project
G=$WORK/gs
mkdir -p "$G"
printf 'module example.com/gs\n\ngo 1.22\n' > "$G/go.mod"
printf 'package main\n\nimport "fmt"\n\nfunc add(a, b int) int {\n\treturn a + b\n}\n\nfunc main() {\n\tn := add(2, 3)\n\tfmt.Println(n)\n}\n' > "$G/main.go"
printf 'package main\n\nimport "testing"\n\nfunc TestAdd(t *testing.T) {\n\tif add(2, 3) != 5 {\n\t\tt.Fatal("add")\n\t}\n}\n' > "$G/add_test.go"
L3=$ART/logs/tasks.log
DRIVE="wait:12;fakeactive;mark:ready;wait:4;menu:View/Command Palette…;wait:1;postkey:53;wait:0.8;\
cmdclick:add(2, 3);wait:3;mark:gs-def;line;axpress:add_test.go;wait:5;gutterctx:func TestAdd|Run “TestAdd”;wait:10;mark:gs-test;\
axpress:main.go;wait:2;bpclick:return a + b;wait:0.5;menu:Product/Debug;waitlabel:main.add;wait:1;mark:gs-paused;menu:Product/Stop;wait:2;\
menu:Help/Get Started;wait:2;mark:gs-welcome;winlabels:Welcome to GoLens;winshot:Welcome to GoLens|getstarted-done;mark:done;wait:20" \
  DRIVE_OUT="$L3" DRIVE_SHOTS="$ART/shots" DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" "$APP" -GoLensLastWorkspacePath "$G" -GoLensLastFilePath "$G/main.go" > "$L3.app" 2>&1 &
APP_PID=$!
wait_mark "$L3" done 150
kill -TERM "$APP_PID" 2>/dev/null; sleep 1; kill -9 "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=
DONE=$(sed -n '/mark gs-welcome$/,$p' "$L3" | grep -m1 "winlabels")
check FR6 "Opening a project, a definition jump, a gutter test run, a stop at a breakpoint and the Command Palette check all five tasks" \
  'echo "$DONE" | grep -q "All done" && ! echo "$DONE" | grep -q "not done"' "$(echo "$DONE" | grep -oE "[A-Za-z ]+, (not )?done" | tr '\n' ';' | cut -c1-300) — shots/getstarted-done.png"

fail=0
printf '\n%-5s %-6s  %s\n' ID RESULT CHECK
while IFS=$'\t' read -r id name status ev; do
  [ "$status" = FAIL ] && fail=$((fail + 1))
  printf '%-5s %-6s  %s\n        %s\n' "$id" "$status" "$name" "$ev"
done < "$RESULTS"
echo
echo "Runtime: $(( $(date +%s) - START ))s. Artifacts: $ART"
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
