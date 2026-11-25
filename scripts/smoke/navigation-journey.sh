#!/bin/bash
# Navigation journey: Show Usages across packages, Cmd-click on a declaration, a failed lookup that offers Retry,
# Go to Definition across packages, and lenses that fill in once gopls is ready.
# Usage: scripts/smoke/navigation-journey.sh [path/to/GoLensApp] [--keep]
# Prefs live in the dev.golens.test.navjourney domain (never the owner's GoLensApp domain).
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=$REPO/.build/release/GoLensApp
KEEP=0
for a in "$@"; do case $a in --keep) KEEP=1 ;; *) BIN=$a ;; esac; done
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }

DOMAIN=dev.golens.test.navjourney
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
mkdir -p "$CONTAINER_DIR/tmp"
WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-nav.XXXXXX")" && pwd -P)
ART=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-nav-artifacts.XXXXXX")" && pwd -P)
mkdir -p "$ART/shots" "$ART/logs"
RESULTS=$ART/results.tsv
: > "$RESULTS"
START=$(date +%s)
APP_PID=
OWNED_PIDS=

descendants() { local k; for k in $(pgrep -P "$1" 2>/dev/null); do echo "$k"; descendants "$k"; done; }

cleanup() {
  [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null && kill -TERM "$APP_PID" 2>/dev/null
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  sleep 1
  for k in $OWNED_PIDS $APP_PID; do kill -KILL "$k" 2>/dev/null; done
  defaults delete $DOMAIN >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  [ $KEEP = 1 ] && echo "kept fixtures: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
APP=$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/driver.dylib" "$HERE/driver.m" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/quiet.dylib" "$HERE/quiet-launch.m" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
defaults delete $DOMAIN >/dev/null 2>&1

N=$WORK/nav
mkdir -p "$N/shared" "$N/alpha" "$N/beta"
printf 'module example.com/nav\n\ngo 1.22\n' > "$N/go.mod"
printf 'package shared\n\n// Greet returns a greeting.\nfunc Greet(name string) string {\n\treturn "hi " + name\n}\n' > "$N/shared/shared.go"
printf 'package alpha\n\nimport "example.com/nav/shared"\n\nfunc A() string {\n\treturn shared.Greet("alpha")\n}\n' > "$N/alpha/alpha.go"
printf 'package beta\n\nimport "example.com/nav/shared"\n\nfunc B() string {\n\treturn shared.Greet("beta")\n}\n' > "$N/beta/beta.go"
printf 'package main\n\nimport (\n\t"fmt"\n\n\t"example.com/nav/alpha"\n\t"example.com/nav/beta"\n)\n\nfunc main() {\n\tfmt.Println(alpha.A(), beta.B())\n}\n' > "$N/main.go"

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }
check() { if eval "$3"; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "$4"; fi; }
line() { grep -m1 "$1" "$LOG" 2>/dev/null; }
ev() { echo "$1" | grep -oE "(Usages|References|Call Hierarchy): ?Greet|[0-9]+ results?|Couldn’t load [a-z ]+\.|gopls didn’t answer[^|]*|Retry|alpha\.go(:[0-9]+)?|beta\.go(:[0-9]+)?|No [a-z]+ found" | sort -u | tr '\n' ' '; }
popup() { sed -n "/mark $1\$/,\$p" "$LOG" | grep -m1 "deeplabels:" | cut -c1-1500; }

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
  if kill -0 "$APP_PID" 2>/dev/null; then echo "  (app did not quit; killing)" >&2; kill -TERM "$APP_PID"; sleep 1; kill -KILL "$APP_PID" 2>/dev/null; fi
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  APP_PID=
}

echo "GoLens navigation journey — $(basename "$BIN") — artifacts: $ART"
LOG=$ART/logs/nav.log
STEPS="wait:10;fakeactive;mark:ready;wait:25;mark:n1-lens;shot:n1-lenses;\
lensclick:func Greet(|2 usages|0;wait:4;mark:n1-usages;deeplabels;shot:n1-usages-dark;lightmode;wait:0.6;shot:n1-usages-light;darkmode;postkey:53;wait:1;mark:n1-closed;deeplabels;\
cmdclick:Greet(name;wait:6;mark:n2-cmd;deeplabels;postkey:53;wait:1;\
defaultbool:GoLensDebugForceLSPTimeouts|1;caret:func Gre;menu:Navigate/Find References;wait:3;mark:n3-failed;deeplabels;lightmode;wait:0.6;shot:n3-failed-light;darkmode;wait:0.6;shot:n3-failed-dark;\
defaultbool:GoLensDebugForceLSPTimeouts|0;axpress:Retry;wait:6;mark:n3-retry;deeplabels;postkey:53;wait:1;\
defaultbool:GoLensDebugForceLSPTimeouts|1;caret:func Gre;menu:Navigate/Call Hierarchy;wait:3;mark:n5-failed;deeplabels;shot:n5-failed-dark;lightmode;wait:0.6;shot:n5-failed-light;darkmode;\
defaultbool:GoLensDebugForceLSPTimeouts|0;axpress:Retry;wait:6;mark:n5-retry;deeplabels;shot:n5-retry;postkey:53;wait:1;\
rowexpand:alpha;wait:1;axpress:alpha.go;wait:4;cmdclick:Greet(\"alpha;wait:6;mark:n4-def;line;mark:done;quit"
GOLENS_MEASURE=1 DRIVE="$STEPS" DRIVE_OUT=$LOG DRIVE_SHOTS=$ART/shots DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
  "$APP" -GoLensLastWorkspacePath "$N" -GoLensLastFilePath "$N/shared/shared.go" > "$ART/logs/nav.app.log" 2>&1 &
APP_PID=$!
wait_mark done 240; finish 20

N1=$(popup n1-usages)
check N1 "The usage lens on a declaration counts calls from other packages and opens them" \
  'echo "$N1" | grep -q "Usages: Greet" && echo "$N1" | grep -q "2 results" && echo "$N1" | grep -q "alpha.go" && echo "$N1" | grep -q "beta.go"' \
  "$(ev "$N1") — shots/n1-usages-*.png"
check N1b "The lens loaded once gopls was ready (ready refresh)" \
  'grep -q "status languageServer {\"state\":\"ready\"" "$ART/logs/nav.app.log" || grep -q "\"state\":\"ready\"" "$ART/logs/nav.app.log"' \
  "$(grep -m1 '"state":"ready"' "$ART/logs/nav.app.log" | cut -c1-120) / $(grep -c 'code-lens' "$ART/logs/nav.app.log") lens batches"
check N1c "Esc closes the usages popup" '! popup n1-closed | grep -qE "[0-9]+ results?"' "$(popup n1-closed | grep -o "Usages: [^|]*" | head -1)"
N2=$(popup n2-cmd)
check N2 "Cmd-click on the declaration name shows its usages without a definition round trip" \
  'echo "$N2" | grep -q "Usages: Greet" && echo "$N2" | grep -q "2 results" && grep -q "navigation: Greet is a declaration" "$ART/logs/nav.app.log"' "$(ev "$N2") / $(grep -m1 'navigation: Greet' "$ART/logs/nav.app.log")"
N3=$(popup n3-failed)
check N3 "A lookup that times out says so and offers Retry instead of showing 0 references" \
  'echo "$N3" | grep -q "Couldn’t load references." && echo "$N3" | grep -q "Retry" && ! echo "$N3" | grep -q "No references found"' \
  "$(ev "$N3") — shots/n3-failed-light*.png, shots/n3-failed-dark*.png"
N3R=$(popup n3-retry)
check N3b "Retry (Return) asks again and shows the references" \
  'echo "$N3R" | grep -q "References: Greet" && echo "$N3R" | grep -q "2 results"' "$(ev "$N3R")"
N5=$(popup n5-failed)
check N5 "Call Hierarchy that times out says so and offers Retry instead of No callers found" \
  'echo "$N5" | grep -q "Couldn’t load the hierarchy." && echo "$N5" | grep -q "Retry"' "$(ev "$N5") — shots/n5-failed-*.png"
N5R=$(popup n5-retry)
check N5b "Retry in Call Hierarchy lists both callers" \
  'echo "$N5R" | grep -q "alpha.go" && echo "$N5R" | grep -q "beta.go" && ! echo "$N5R" | grep -q "Retry"' "$(ev "$N5R")"
N4=$(sed -n '/mark n4-def$/,$p' "$LOG" | grep -m1 "DRIVE line:")
check N4 "Go to Definition from another package opens the declaration" \
  'echo "$N4" | grep -q "func Greet(name string) string"' "${N4:-no line}"

printf '\n%-5s %-6s  %s\n' ID RESULT CHECK
fails=0
while IFS=$'\t' read -r id name res_status ev; do
  [ "$res_status" = FAIL ] && fails=$((fails + 1))
  printf '%-5s %-6s  %s\n        %s\n' "$id" "$res_status" "$name" "$ev"
done < "$RESULTS"
echo "Runtime: $(( $(date +%s) - START ))s. Artifacts: $ART"
[ $fails -eq 0 ] && echo "No failures." || echo "$fails failure(s)."
exit $([ $fails -eq 0 ] && echo 0 || echo 1)
