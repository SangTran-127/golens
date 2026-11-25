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
[ -x "$BIN" ] || { echo "missing binary: $BIN (run GOLENS_CANONICAL_BUILD=0 make build)"; exit 2; }

LOCK=/private/tmp/golens-smoke.lock
. "$(cd "$(dirname "$0")" && pwd)/smoke-lock.sh"
smoke_lock_acquire

DOMAIN=dev.golens.test.essentials
WORK=$(cd "$(mktemp -d -t golens-essentials)" && pwd -P)
ART=${EDITOR_ESSENTIALS_ARTIFACTS:-$(cd "$(mktemp -d -t golens-essentials-artifacts)" && pwd -P)}
mkdir -p "$ART/shots" "$ART/logs"
RESULTS=$ART/results.tsv
: > "$RESULTS"
START=$(date +%s)
APP_PID=
OWNED_PIDS=

descendants() { local k; for k in $(pgrep -P "$1" 2>/dev/null); do echo "$k"; descendants "$k"; done; }

cleanup() {
  [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null && kill -TERM "$APP_PID" 2>/dev/null || true
  for k in ${=OWNED_PIDS}; do kill -TERM "$k" 2>/dev/null || true; done
  sleep 1
  for k in ${=OWNED_PIDS} $APP_PID; do [ -n "$k" ] && kill -KILL "$k" 2>/dev/null || true; done
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
clang -dynamiclib -fobjc-arc -framework AppKit -framework CoreImage -o "$WORK/driver.dylib" "$HERE/driver.m" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/quiet.dylib" "$HERE/quiet-launch.m" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
defaults delete "$DOMAIN" >/dev/null 2>&1 || true

E=$WORK/essentials
mkdir -p "$E"
printf 'module example.com/essentials\n\ngo 1.22\n' > "$E/go.mod"
LONG=$(printf 'LONGLINE'; for i in $(seq 1 40); do printf ' word%02d' "$i"; done)
cat > "$E/calc.go" <<EOF
package essentials

import "strings"

func Scale(base int) int {
	doubled := base * 2
	return doubled + 1
}

func Label() string {
	msg := "plain text"
	return strings.ToUpper(msg)
}

func Count() int {
	first := len("needle one")
	second := len("needle two")
	third := len("needle three")
	return first + second + third
}

func Long() string {
	return "$LONG"
}
EOF

cat > "$E/helper.go" <<'EOF'
package essentials

func HelperOne(x int) int {
	return x + 1
}

func HelperNeedle() string {
	return "needle four"
}
EOF

cat > "$E/calc_test.go" <<'EOF'
package essentials

import (
	"os"
	"testing"
)

func TestPass(t *testing.T) {
	if Scale(3) != 7 {
		t.Fatal("want 7")
	}
}

func TestFailOnMissingMarker(t *testing.T) {
	if _, err := os.Stat("ready.txt"); err != nil {
		t.Fatal("ready.txt is missing")
	}
}
EOF

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }
check() { if eval "$3"; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "$4"; fi; }
both() { printf 'shot:light-%s;darkmode;wait:0.8;shot:dark-%s;lightmode;wait:0.6;' "$1" "$1"; }
bothsheet() { printf 'sheetshot:light-%s;darkmode;wait:0.8;sheetshot:dark-%s;lightmode;wait:0.6;' "$1" "$1"; }
after() { sed -n "/mark $1\$/,\$p" "$LOG" | grep -m1 -- "$2" | cut -c1-${3:-400}; }
between() { sed -n "/DRIVE mark $1\$/,/DRIVE mark $2\$/p" "$LOG"; }
st() { grep -m1 "DRIVE edstate $1 " "$LOG" | sed 's/.*DRIVE edstate //' | cut -c1-240; }
stf() { st "$1" | grep -o " $2=[^ ]*" | cut -d= -f2; }
ln_() { stf "$1" line; }
labels() { after "$1" "deeplabels:" 20000; }
textat() { sed -n "/mark $1\$/,/^>>>/p" "$LOG" | sed -n '/TEXT<<</,/^>>>/p'; }

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
  if kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    sleep 1
    kill -KILL "$APP_PID" 2>/dev/null || true
  fi
  for k in ${=OWNED_PIDS}; do kill -TERM "$k" 2>/dev/null || true; done
  APP_PID=
}

LOG=$ART/logs/essentials.log
STEPS="wait:10;fakeactive;mark:ready;edstate:start;\
caret:return doubled + 1;edstate:ee1-before;menu:View/Code Folding/Fold;wait:0.8;edstate:ee1-fold;$(both 01-folded)menu:View/Code Folding/Unfold;wait:0.8;edstate:ee1-unfold;\
menu:View/Zoom In;wait:0.4;edstate:ee2-in1;menu:View/Zoom In;wait:0.4;edstate:ee2-in2;menu:View/Zoom Out;wait:0.4;edstate:ee2-out;menu:View/Actual Size;wait:0.4;edstate:ee2-actual;\
caret:LONGLINE;edstate:ee3-before;menu:View/Toggle Word Wrap;wait:1.0;edstate:ee3-wrap;$(both 02-word-wrap)menu:View/Toggle Word Wrap;wait:1.0;edstate:ee3-nowrap;\
caret:package essentials;menu:Navigate/Go to Line…;wait:1.2;mark:ee4-sheet;deeplabels;$(bothsheet 03-goto-line)fieldp:Line:17;wait:0.8;edstate:ee4-jumped;\
menu:Navigate/Toggle Bookmark;wait:0.5;axpress:helper.go;wait:1.5;caret:return \"needle four\";edstate:ee5-helper-bm;menu:Navigate/Toggle Bookmark;wait:0.5;\
menu:Navigate/Show Bookmarks;wait:1.2;mark:ee5-list;axfind:needle two;axfind:needle four;$(both 04-bookmarks)\
menu:Navigate/Next Bookmark;wait:0.8;mark:ee5-next1;wineditor:essentials;edstate:ee5-next1;\
menu:Navigate/Next Bookmark;wait:0.8;mark:ee5-next2;wineditor:essentials;edstate:ee5-next2;\
menu:Navigate/Previous Bookmark;wait:0.8;mark:ee5-prev;wineditor:essentials;edstate:ee5-prev;\
menu:View/Navigators/Files;wait:0.8;axpress:helper.go;wait:1.2;axpress:calc.go;wait:1.2;menu:Navigate/Recent Files…;wait:1.2;mark:ee6-popup;deeplabels;$(both 05-recent-files)\
postkey:125;wait:0.4;postkey:36;wait:1.2;mark:ee6-switched;wineditor:essentials;\
axpress:calc.go;wait:1.2;select:needle;menu:Find/Use Selection for Find;wait:1.0;mark:ee7-start;deeplabels;edstate:ee7-start;$(both 06-find-bar)\
menu:Find/Find Next;wait:0.5;edstate:ee7-n1;menu:Find/Find Next;wait:0.5;edstate:ee7-n2;menu:Find/Find Next;wait:0.5;mark:ee7-wrapfwd;deeplabels;edstate:ee7-wrapfwd;\
menu:Find/Find Previous;wait:0.5;mark:ee7-wrapback;deeplabels;edstate:ee7-wrapback;axpress:Close Find Bar;wait:0.5;\
menu:Find/Find in Project…;wait:1.2;mark:ee8-open;fieldp:Search in project…:needle;wait:3.0;mark:ee8-results;deeplabels;$(both 07-project-search)\
axpress:7:;wait:1.2;mark:ee8-jumped;wineditor:essentials;edstate:ee8-jumped;\
menu:View/Navigators/Files;wait:0.8;axpress:calc.go;wait:1.2;caret:doub;edstate:ee9-before;menu:Editor/Refactor/Inline Variable;wait:1.5;mark:ee9-inlined;text;undotitle;undo;wait:0.6;mark:ee9-undone;text;menu:File/Save;wait:0.6;\
menu:Product/Test;waitlabel:Tests failed;wait:1.0;mark:ee10-failed;deeplabels;menustate:Product/Rerun Failed Tests;$(both 08-test-failed)\
waitfile:$WORK/ee10-go;menu:Product/Rerun Failed Tests;waitlabel:Tests passed: 1 passed;wait:1.0;mark:ee10-rerun;deeplabels;$(both 09-rerun-passed)\
mark:ee11-pre;menustate:Product/Clear Coverage;menu:Product/Run Tests with Coverage;waitlabel:Tests passed: 2 passed;wait:1.2;menu:View/Navigators/Tests;wait:1.5;mark:ee11-cov;axfind:%;menustate:Product/Clear Coverage;$(both 10-coverage)\
menu:Product/Clear Coverage;wait:1.0;mark:ee11-cleared;axfind:%;menustate:Product/Clear Coverage;$(both 11-coverage-cleared)mark:done;quit"

echo "GoLens editor essentials journey — $(basename "$BIN") — artifacts: $ART"
GOLENS_MEASURE=1 DRIVE="$STEPS" DRIVE_OUT=$LOG DRIVE_SHOTS=$ART/shots DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
  "$APP" -AppleInterfaceStyle Light -GoLensLastWorkspacePath "$E" -GoLensLastFilePath "$E/calc.go" -GoLensShowConsole '<true/>' -GoLensEnablePreviewTab '<false/>' > "$ART/logs/essentials.app.log" 2>&1 &
APP_PID=$!

wait_mark ee10-failed 240 && touch "$E/ready.txt"
touch "$WORK/ee10-go"
wait_mark done 240
finish 15

check EE1 "View > Code Folding > Fold hides the function body and Unfold restores visual lines" \
  '[ "$(stf ee1-fold visual)" -lt "$(stf ee1-before visual)" ] && [ "$(stf ee1-unfold visual)" = "$(stf ee1-before visual)" ]' \
  "visual: $(stf ee1-before visual) -> $(stf ee1-fold visual) -> $(stf ee1-unfold visual); shots/light-01-folded.png, shots/dark-01-folded.png"

check EE2 "View > Zoom In, Zoom Out, and Actual Size update editor font 13 -> 14 -> 15 -> 14 -> 13" \
  '[ "$(stf start font)" = 13.0 ] && [ "$(stf ee2-in1 font)" = 14.0 ] && [ "$(stf ee2-in2 font)" = 15.0 ] && [ "$(stf ee2-out font)" = 14.0 ] && [ "$(stf ee2-actual font)" = 13.0 ]' \
  "font: $(stf start font) -> $(stf ee2-in1 font) -> $(stf ee2-in2 font) -> $(stf ee2-out font) -> $(stf ee2-actual font)"

check EE3 "View > Toggle Word Wrap wraps a long line and toggles back off" \
  '[ "$(stf ee3-before wrap)" = 0 ] && [ "$(stf ee3-wrap wrap)" = 1 ] && [ "$(stf ee3-wrap frags)" -gt 1 ] && [ "$(stf ee3-nowrap wrap)" = 0 ] && [ "$(stf ee3-nowrap frags)" = 1 ]' \
  "wrap/frags: $(stf ee3-before wrap)/$(stf ee3-before frags) -> $(stf ee3-wrap wrap)/$(stf ee3-wrap frags) -> $(stf ee3-nowrap wrap)/$(stf ee3-nowrap frags); shots/light-02-word-wrap.png, shots/dark-02-word-wrap.png"

check EE4 "Navigate > Go to Line… opens the sheet and lands on exact line 17" \
  'labels ee4-sheet | grep -q "Go to Line" && [ "$(ln_ ee4-jumped)" = 17 ]' \
  "line=$(ln_ ee4-jumped); shots/light-03-goto-line.png, shots/dark-03-goto-line.png"

check EE5 "Toggle Bookmark adds bookmarks in 2 files and Next/Previous Bookmark navigates across them" \
  'after ee5-list "axfind needle two" | grep -qv -- "-> 0:" && after ee5-list "axfind needle four" | grep -qv -- "-> 0:" && after ee5-next1 "DRIVE wineditor" | grep -q "calc.go" && [ "$(ln_ ee5-next1)" = 17 ] && after ee5-next2 "DRIVE wineditor" | grep -q "helper.go" && [ "$(ln_ ee5-next2)" = 8 ] && after ee5-prev "DRIVE wineditor" | grep -q "calc.go" && [ "$(ln_ ee5-prev)" = 17 ]' \
  "next1=$(after ee5-next1 "DRIVE wineditor" | grep -oE "file=[^ ]+")@L$(ln_ ee5-next1) -> next2=$(after ee5-next2 "DRIVE wineditor" | grep -oE "file=[^ ]+")@L$(ln_ ee5-next2) -> prev=$(after ee5-prev "DRIVE wineditor" | grep -oE "file=[^ ]+")@L$(ln_ ee5-prev); shots/light-04-bookmarks.png, shots/dark-04-bookmarks.png"

check EE6 "Navigate > Recent Files… lists previous file and selecting it switches active editor to helper.go" \
  'labels ee6-popup | grep -q "Recent in Workspace" && labels ee6-popup | grep -q "helper.go" && after ee6-switched "DRIVE wineditor" | grep -q "helper.go"' \
  "switched=$(after ee6-switched "DRIVE wineditor" | grep -oE "file=[^ ]+"); shots/light-05-recent-files.png, shots/dark-05-recent-files.png"

check EE7 "Find Next wraps forward from 3/3 back to 1/3 and Find Previous wraps backward from 1/3 to 3/3" \
  'labels ee7-start | grep -q "1/3" && [ "$(ln_ ee7-start)" = 16 ] && [ "$(ln_ ee7-n1)" = 17 ] && [ "$(ln_ ee7-n2)" = 18 ] && labels ee7-wrapfwd | grep -q "1/3" && [ "$(ln_ ee7-wrapfwd)" = 16 ] && labels ee7-wrapback | grep -q "3/3" && [ "$(ln_ ee7-wrapback)" = 18 ]' \
  "lines: $(ln_ ee7-start) -> $(ln_ ee7-n1) -> $(ln_ ee7-n2) -> wrap $(ln_ ee7-wrapfwd) -> prev wrap $(ln_ ee7-wrapback); shots/light-06-find-bar.png, shots/dark-06-find-bar.png"

check EE8 "Find > Find in Project… searches across files and clicking a hit jumps to helper.go line 7" \
  'labels ee8-results | grep -q "calc.go" && labels ee8-results | grep -q "helper.go" && labels ee8-results | grep -q "HelperNeedle" && after ee8-jumped "DRIVE wineditor" | grep -q "helper.go" && [ "$(ln_ ee8-jumped)" = 7 ]' \
  "jumped=$(after ee8-jumped "DRIVE wineditor" | grep -oE "file=[^ ]+")@L$(ln_ ee8-jumped); shots/light-07-project-search.png, shots/dark-07-project-search.png"

INLINED=$(textat ee9-inlined)
UNDONE=$(textat ee9-undone)
check EE9 "Editor > Refactor > Inline Variable replaces variable and single-step Undo restores original source" \
  '! echo "$INLINED" | grep -q "doubled" && echo "$INLINED" | grep -qE "return \(?base \* 2\)? \+ 1" && echo "$UNDONE" | grep -q "doubled := base \* 2" && echo "$UNDONE" | grep -q "return doubled + 1"' \
  "undotitle=$(after ee9-inlined undotitle | cut -c7-); restored=$(echo "$UNDONE" | grep -c "doubled") lines"

summary() { labels "$1" | grep -oE "Tests (passed|failed): [^|]*" | tail -1; }
check EE10 "Product > Rerun Failed Tests enables after failure and reruns only the single failed test after fix" \
  'summary ee10-failed | grep -q "1 passed, 1 failed" && after ee10-failed "menustate Product/Rerun Failed Tests" | grep -q "enabled=1" && summary ee10-rerun | grep -q "Tests passed: 1 passed"' \
  "initial: $(summary ee10-failed); rerun: $(summary ee10-rerun); shots/light-08-test-failed.png, shots/light-09-rerun-passed.png"

COV_ON=$(after ee11-cov "axfind %" | sed "s/.*-> [0-9]*://" | grep -oE "[0-9]+(\.[0-9]+)?%" | head -1)
COV_OFF=$(after ee11-cleared "axfind %" | sed "s/.*-> [0-9]*://" | grep -oE "[0-9]+(\.[0-9]+)?%" | head -1)
check EE11 "Product > Clear Coverage clears percentage indicators after Run Tests with Coverage and disables itself" \
  'after ee11-pre "menustate Product/Clear Coverage" | grep -q "enabled=0" && [ -n "$COV_ON" ] && after ee11-cov "menustate Product/Clear Coverage" | grep -q "enabled=1" && [ -z "$COV_OFF" ] && after ee11-cleared "menustate Product/Clear Coverage" | grep -q "enabled=0"' \
  "coverage: before=disabled -> on=$COV_ON (enabled=1) -> cleared=${COV_OFF:-none} (enabled=0); shots/light-10-coverage.png, shots/dark-10-coverage.png, shots/light-11-coverage-cleared.png, shots/dark-11-coverage-cleared.png"

! grep -q "DRIVE mark done$" "$LOG" && record EE0 "The editor essentials session ran to completion" FAIL "last step: $(grep 'DRIVE' "$LOG" | tail -1 | cut -c1-160)"

[ -s "$RESULTS" ] || { echo "missing or empty results: $RESULTS"; exit 1; }
fail=0
printf '\n%-5s %-6s  %s\n' ID RESULT CHECK
while IFS=$'\t' read -r id name res_status ev; do
  [ "$res_status" = FAIL ] && fail=$((fail + 1))
  printf '%-5s %-6s  %s\n        %s\n' "$id" "$res_status" "$name" "$ev"
done < "$RESULTS"
echo "Runtime: $(( $(date +%s) - START ))s. Artifacts: $ART"
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
