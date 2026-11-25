#!/bin/bash
# Menu actions no other journey drives: editing and view commands, find, bookmarks, tests, stepping
# in the debugger and source control on throwaway fixtures. Each check reads an observable result.
# Uses the isolated bundle id dev.golens.test.coverage, quiet.dylib and driver.dylib.
# Copy Goroutine Dump writes the general pasteboard; its text is saved first and put back on exit.
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
export GOLENS_VM_MEMORY_MB=512
pkill -9 -f "Containers/dev.golens.test.coverage/" 2>/dev/null || true

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=${1:-$REPO/.build/release/GoLensApp}
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }

DOMAIN=dev.golens.test.coverage
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
rm -rf "$CONTAINER_DIR/Library/Preferences" 2>/dev/null || true
mkdir -p "$CONTAINER_DIR/tmp"
WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-coverage.XXXXXX")" && pwd -P)
ART=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-coverage-artifacts.XXXXXX")" && pwd -P)
mkdir -p "$ART/shots" "$ART/logs"
RESULTS=$ART/results.tsv
: > "$RESULTS"
START=$(date +%s)
APP_PID=
OWNED_PIDS=
CLIP_SAVED=0

descendants() { local k; for k in $(pgrep -P "$1" 2>/dev/null); do echo "$k"; descendants "$k"; done; }

cleanup() {
  [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null && kill -TERM "$APP_PID" 2>/dev/null
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  sleep 1
  for k in $OWNED_PIDS $APP_PID; do kill -KILL "$k" 2>/dev/null; done
  [ $CLIP_SAVED = 1 ] && pbcopy < "$WORK/clipboard.txt"
  defaults delete $DOMAIN >/dev/null 2>&1 || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  rm -f "$CONTAINER_DIR/tmp/vsock_"*.sock
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
! codesign -d --entitlements - "$WORK/app/GoLens.app" 2>&1 | grep -q "com.apple.security.app-sandbox" || { echo "unexpected app-sandbox entitlement"; exit 2; }
codesign -d --entitlements - "$WORK/app/GoLens.app" 2>&1 | grep -q "com.apple.security.cs.disable-library-validation" || { echo "missing disable-library-validation entitlement"; exit 2; }

APP="$WORK/app/GoLens.app/Contents/MacOS/GoLensApp"
clang -dynamiclib -fobjc-arc -framework AppKit -framework CoreImage "$REPO/scripts/smoke/driver.m" -o "$WORK/driver.dylib" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit "$REPO/scripts/smoke/quiet-launch.m" -o "$WORK/quiet.dylib" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
defaults delete $DOMAIN >/dev/null 2>&1 || true

gitq() { git -c user.email=coverage@golens -c user.name=coverage -c init.defaultBranch=main -c commit.gpgsign=false "$@" >/dev/null 2>&1; }

# ---- fixtures
E=$WORK/covedit
mkdir -p "$E"
printf 'module example.com/covedit\n\ngo 1.22\n' > "$E/go.mod"
LONG=$(printf 'LONGLINE'; for i in $(seq 1 40); do printf ' word%02d' "$i"; done)
cat > "$E/calc.go" <<EOF
package calc

import "strings"

// Scale multiplies the base value.
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
printf 'package calc\n\n// Other mentions the needle once more.\nfunc Other() string { return "needle four" }\n' > "$E/other.go"
cp "$E/calc.go" "$WORK/calc.go.orig"

R=$WORK/covrun
mkdir -p "$R"
printf 'module example.com/covrun\n\ngo 1.22\n' > "$R/go.mod"
cat > "$R/main.go" <<'EOF'
package main

import "fmt"

func add(a, b int) int {
	sum := a + b
	return sum
}

func main() {
	n := add(2, 3)
	fmt.Println("sum", n)
}
EOF
cat > "$R/main_test.go" <<'EOF'
package main

import (
	"os"
	"testing"
)

func TestAdd(t *testing.T) {
	if add(2, 3) != 5 {
		t.Fatal("want 5")
	}
}

func TestReady(t *testing.T) {
	if _, err := os.Stat("ready.txt"); err != nil {
		t.Fatal("ready.txt is missing")
	}
}
EOF

G=$WORK/covscm
mkdir -p "$G"
gitq init "$G"
printf 'module example.com/covscm\n\ngo 1.22\n' > "$G/go.mod"
printf 'package main\n\nfunc main() {}\n' > "$G/main.go"
printf 'package main\n\nfunc helper() int { return 1 }\n' > "$G/helper.go"
gitq -C "$G" add -A; gitq -C "$G" commit -m "start the project"
printf 'package main\n\nfunc main() { println("changed") }\n' > "$G/main.go"
printf 'package main\n\nfunc helper() int { return 2 }\n' > "$G/helper.go"

# ---- helpers
record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }
check() { if eval "$3"; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "$4"; fi; }
after() { sed -n "/mark $1\$/,\$p" "$LOG" | grep -m1 "$2" | cut -c1-${3:-400}; }
st() { grep -m1 "DRIVE edstate $1 " "$LOG" | sed 's/.*DRIVE edstate //' | cut -c1-240; }
stf() { st "$1" | grep -o " $2=[^ ]*" | cut -d= -f2; }
labels() { after "$1" "deeplabels:" 20000; }
found() { sed -n "/mark $1\$/,\$p" "$LOG" | grep -m1 -F "find '$2'" | grep -o "present\|absent"; }
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
  if kill -0 "$APP_PID" 2>/dev/null; then echo "  (app did not quit; killing)" >&2; kill -TERM "$APP_PID"; sleep 1; kill -KILL "$APP_PID" 2>/dev/null; fi
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  APP_PID=
}

launch() { # name workspace file steps
  LOG=$ART/logs/$1.log
  DRIVE="$4" DRIVE_OUT=$LOG DRIVE_SHOTS=$ART/shots DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
    "$APP" -GoLensLastWorkspacePath "$2" -GoLensLastFilePath "$3" -GoLensShowConsole '<true/>' > "$ART/logs/$1.app.log" 2>&1 &
  APP_PID=$!
}

echo "GoLens coverage journey — $(basename "$BIN") — artifacts: $ART"

# ---- Editing session: go to line, bookmarks, find, project search, recent files, comment, fold, refactors, view
launch edit "$E" "$E/calc.go" "wait:10;fakeactive;mark:ready;edstate:start;menustate:Navigate/Go to Line…;textclick:package cal;wait:0.6;mark:e1-pre;menustate:Navigate/Go to Line…;\
menu:Navigate/Go to Line…;wait:1.2;mark:e1-sheet;deeplabels;shot:goto-line;fieldp:Line:17;wait:1;edstate:e1;\
caret:first :;menu:Navigate/Toggle Bookmark;wait:0.4;caret:third :;menu:Navigate/Toggle Bookmark;wait:0.4;caret:package cal;\
menu:Navigate/Next Bookmark;wait:0.6;edstate:e2-next1;menu:Navigate/Next Bookmark;wait:0.6;edstate:e2-next2;menu:Navigate/Next Bookmark;wait:0.6;edstate:e2-wrap;\
menu:Navigate/Previous Bookmark;wait:0.6;edstate:e2-prev1;menu:Navigate/Previous Bookmark;wait:0.6;edstate:e2-prev2;\
menu:Navigate/Show Bookmarks;wait:1.5;mark:e2-list;axfind:needle one;axfind:needle three;axfind:Bookmarks (;shot:bookmarks;\
caret:third :;menu:Navigate/Toggle Bookmark;wait:0.4;caret:package cal;menu:Navigate/Next Bookmark;wait:0.6;edstate:e2-after-remove1;menu:Navigate/Next Bookmark;wait:0.6;edstate:e2-after-remove2;\
menu:View/Navigators/Files;wait:1;\
select:needle;menustate:Find/Use Selection for Find;menu:Find/Use Selection for Find;wait:1.2;mark:e3-find;deeplabels;edstate:e3-start;shot:find-bar;\
menu:Find/Find Next;wait:0.6;edstate:e3-next1;menu:Find/Find Next;wait:0.6;edstate:e3-next2;mark:e3-count;deeplabels;menu:Find/Find Previous;wait:0.6;edstate:e3-prev;axpress:Close Find Bar;wait:0.6;\
menu:Find/Find in Project…;wait:1.5;mark:e4-nav;deeplabels;fieldp:Search in project…:needle;wait:4;mark:e4-results;deeplabels;shot:project-search;\
menu:View/Navigators/Files;wait:1;axpress:other.go;wait:2;axpress:calc.go;wait:2;menu:Navigate/Recent Files…;wait:1.5;mark:e5-recent;deeplabels;shot:recent-files;postkey:53;wait:1;mark:e5-closed;deeplabels;\
caret:doub;menu:Editor/Comment/Uncomment Selection;wait:0.6;edstate:e6-on;mark:e6-on;edited;undotitle;waitfile:$WORK/e6-go;menu:Editor/Comment/Uncomment Selection;wait:0.6;edstate:e6-off;\
caret:return doub;edstate:e7-before;menu:View/Code Folding/Fold;wait:0.6;edstate:e7-fold;shot:folded;menu:View/Code Folding/Unfold;wait:0.6;edstate:e7-unfold;\
menu:View/Code Folding/Fold All;wait:0.6;edstate:e7-foldall;shot:folded-all;menu:View/Code Folding/Unfold All;wait:0.6;edstate:e7-unfoldall;\
caret:doub;menu:Editor/Refactor/Inline Variable;wait:1.2;mark:e8-inline;undotitle;text;waitfile:$WORK/e8-go;\
caret:plain te;menu:Editor/Refactor/Convert Between Raw and Interpreted String;wait:1.2;mark:e9-raw;find:\`plain text\`;caret:plain te;menu:Editor/Refactor/Convert Between Raw and Interpreted String;wait:1.2;mark:e9-back;find:\"plain text\";waitfile:$WORK/e9-go;\
caret:LONGLINE;edstate:e10-before;menu:View/Toggle Word Wrap;wait:1;edstate:e10-wrap;shot:word-wrap;menu:View/Toggle Word Wrap;wait:1;edstate:e10-nowrap;\
menu:View/Minimap;wait:1.2;edstate:e11-on;shot:minimap;menu:View/Minimap;wait:1.2;edstate:e11-off;\
menu:View/Zoom In;wait:0.4;edstate:e12-in1;mark:e12-hud;deeplabels;menu:View/Zoom In;wait:0.4;edstate:e12-in2;menu:View/Zoom Out;wait:0.4;edstate:e12-out;menu:View/Zoom In;wait:0.4;menu:View/Actual Size;wait:0.4;edstate:e12-actual;\
mark:done;quit"
snap() { wait_mark "$1" 120 && cp "$E/calc.go" "$ART/calc-on-disk-after-$1.go"; touch "$WORK/$2"; }
snap e6-on e6-go; snap e8-inline e8-go; snap e9-back e9-go
wait_mark done 240; finish 15

ln_() { stf "$1" line; }
check E1 "Navigate ▸ Go to Line… opens the sheet and Go puts the caret on line 17" \
  'after e1-pre "menustate Navigate/Go to Line" | grep -q "enabled=1" && labels e1-sheet | grep -q "Go to Line" && [ "$(ln_ e1)" = 17 ]' "$(after ready "menustate Navigate/Go to Line" | cut -c7-); after a click in the editor: $(after e1-pre "menustate Navigate/Go to Line" | cut -c7-) / $(after e1-sheet "fieldp Line" | cut -c7-) / caret line $(ln_ e1) — shots/goto-line.png"
check E2a "Toggle Bookmark on lines 17 and 19, then Next Bookmark walks 17, 19 and wraps to 17" \
  '[ "$(ln_ e2-next1)" = 17 ] && [ "$(ln_ e2-next2)" = 19 ] && [ "$(ln_ e2-wrap)" = 17 ]' "next: $(ln_ e2-next1), $(ln_ e2-next2), $(ln_ e2-wrap)"
check E2b "Previous Bookmark from line 17 wraps to 19, then goes back to 17" \
  '[ "$(ln_ e2-prev1)" = 19 ] && [ "$(ln_ e2-prev2)" = 17 ]' "previous: $(ln_ e2-prev1), $(ln_ e2-prev2)"
check E2c "Show Bookmarks lists both bookmarked lines" \
  'after e2-list "axfind Bookmarks (" | grep -q "Bookmarks (2)" && after e2-list "axfind needle one" | grep -qv -- "-> 0:" && after e2-list "axfind needle three" | grep -qv -- "-> 0:"' "$(after e2-list "axfind needle one" | cut -c7-); $(after e2-list "axfind needle three" | cut -c7-) — shots/bookmarks.png"
check E2d "Toggle Bookmark on a bookmarked line removes it: Next Bookmark stays on 17" \
  '[ "$(ln_ e2-after-remove1)" = 17 ] && [ "$(ln_ e2-after-remove2)" = 17 ]' "next: $(ln_ e2-after-remove1), $(ln_ e2-after-remove2)"
check E3a "Find ▸ Use Selection for Find opens the find bar with the selection and counts 3 matches" \
  'after ready "menustate Find/Use Selection for Find" | grep -q "enabled=1" && labels e3-find | grep -q "1/3"' "$(after ready "menustate Find/Use Selection" | cut -c7-) / $(labels e3-find | grep -oE "[0-9]+/[0-9]+" | head -1) — shots/find-bar.png"
check E3b "Find Next moves to the next match (lines 18, 19) and Find Previous back to 18" \
  '[ "$(ln_ e3-next1)" = 18 ] && [ "$(ln_ e3-next2)" = 19 ] && [ "$(ln_ e3-prev)" = 18 ] && labels e3-count | grep -q "3/3"' "lines: $(ln_ e3-start) -> $(ln_ e3-next1), $(ln_ e3-next2), $(ln_ e3-prev); count $(labels e3-count | grep -oE "[0-9]+/[0-9]+" | head -1)"
check E4 "Find ▸ Find in Project… shows the project search and lists the 5 matches in both files" \
  'labels e4-nav | grep -q "Search in Project" && labels e4-results | grep -q "calc.go" && labels e4-results | grep -q "other.go" && labels e4-results | grep -q "needle four" && labels e4-results | grep -q "5 results in 2 files"' \
  "$(after e4-results "fieldp" | cut -c7-) / $(labels e4-results | grep -oE "[0-9]+ (results?|matches?)[^|]*" | head -1) — shots/project-search.png"
check E5 "Navigate ▸ Recent Files… lists the file opened before and Esc closes it" \
  'labels e5-recent | grep -q "Recent in Workspace" && labels e5-recent | grep -q "other.go" && ! labels e5-closed | grep -q "Recent in Workspace"' "$(labels e5-recent | grep -oi "[^|]*recent[^|]*" | head -2 | tr '\n' ';') — shots/recent-files.png"
check E6 "Editor ▸ Comment/Uncomment Selection comments the caret line, marks the file edited, and uncomments it again" \
  'st e6-on | grep -qE "text=//[[:space:]]*doubled := base \\* 2" && after e6-on "DRIVE edited" | grep -q "edited 1" && st e6-off | grep -q "text=doubled := base \* 2"' "on: $(st e6-on | sed 's/.*text=//') / off: $(st e6-off | sed 's/.*text=//') / $(after e6-on undotitle | cut -c7-)"
check E7a "View ▸ Code Folding ▸ Fold hides the body around the caret and Unfold shows it again" \
  '[ "$(stf e7-fold visual)" -lt "$(stf e7-before visual)" ] && [ "$(stf e7-unfold visual)" = "$(stf e7-before visual)" ]' "visual lines: $(stf e7-before visual) -> $(stf e7-fold visual) -> $(stf e7-unfold visual) — shots/folded.png"
check E7b "Fold All hides more than one block and Unfold All shows everything" \
  '[ "$(stf e7-foldall visual)" -lt "$(stf e7-fold visual)" ] && [ "$(stf e7-unfoldall visual)" = "$(stf e7-before visual)" ]' "visual lines: all $(stf e7-foldall visual) -> $(stf e7-unfoldall visual) — shots/folded-all.png"
INL=$(textat e8-inline)
check E8 "Editor ▸ Refactor ▸ Inline Variable replaces doubled with its value" \
  '! echo "$INL" | grep -q "doubled" && echo "$INL" | grep -qE "return \(?base \* 2\)? \+ 1"' "$(echo "$INL" | grep -m1 "return .*+ 1" | tr -d '\t') / $(after e8-inline undotitle | cut -c7-)"
check E9 "Editor ▸ Refactor ▸ Convert Between Raw and Interpreted String turns \"plain text\" into a raw string and back" \
  '[ "$(found e9-raw "\`plain text\`")" = present ] && [ "$(found e9-back "\"plain text\"")" = present ]' "raw: $(found e9-raw "\`plain text\`") / back: $(found e9-back "\"plain text\"")"
check E10 "View ▸ Toggle Word Wrap wraps the long line and toggles back" \
  '[ "$(stf e10-before wrap)" = 0 ] && [ "$(stf e10-wrap wrap)" = 1 ] && [ "$(stf e10-wrap frags)" -gt 1 ] && [ "$(stf e10-nowrap wrap)" = 0 ] && [ "$(stf e10-nowrap frags)" = 1 ]' \
  "wrap/fragments: $(stf e10-before wrap)/$(stf e10-before frags) -> $(stf e10-wrap wrap)/$(stf e10-wrap frags) -> $(stf e10-nowrap wrap)/$(stf e10-nowrap frags) — shots/word-wrap.png"
check E11 "View ▸ Minimap shows the minimap and hides it again" \
  '[ "$(stf start minimap)" = 0 ] && [ "$(stf e11-on minimap)" = 1 ] && [ "$(stf e11-off minimap)" = 0 ]' "minimap: $(stf start minimap) -> $(stf e11-on minimap) -> $(stf e11-off minimap) — shots/minimap.png"
check E12 "View ▸ Zoom In, Zoom Out and Actual Size change the editor font 13 -> 14 -> 15 -> 14 -> 13" \
  '[ "$(stf start font)" = 13.0 ] && [ "$(stf e12-in1 font)" = 14.0 ] && [ "$(stf e12-in2 font)" = 15.0 ] && [ "$(stf e12-out font)" = 14.0 ] && [ "$(stf e12-actual font)" = 13.0 ] && labels e12-hud | grep -q "Zoom: 107%"' \
  "font: $(stf start font) -> $(stf e12-in1 font) -> $(stf e12-in2 font) -> $(stf e12-out font) -> $(stf e12-actual font); HUD $(labels e12-hud | grep -o "Zoom: [0-9]*%" | head -1)"
! grep -q "DRIVE mark done$" "$LOG" && record E0 "The editing session ran to the end" FAIL "last step: $(grep 'DRIVE' "$LOG" | tail -1 | cut -c1-160)"
check E13 "Comment/Uncomment only edits the buffer; a refactor in a clean file saves it, so the disk matches the editor" \
  'cmp -s "$ART/calc-on-disk-after-e6-on.go" "$WORK/calc.go.orig" && grep -q "return (base \* 2) + 1" "$ART/calc-on-disk-after-e8-inline.go" && grep -q "\"plain text\"" "$E/calc.go"' \
  "disk after comment: $(cmp -s "$ART/calc-on-disk-after-e6-on.go" "$WORK/calc.go.orig" && echo unchanged || echo changed); after Inline Variable: $(grep -c "return (base \* 2) + 1" "$ART/calc-on-disk-after-e8-inline.go" 2>/dev/null) inlined line(s)"

# ---- Tests: a failing test, Rerun Failed Tests after the cause is fixed, coverage and Clear Coverage
launch tests "$R" "$R/main.go" "wait:10;fakeactive;mark:ready;menu:Product/Test;waitlabel:Tests failed;wait:1;mark:t1;deeplabels;menustate:Product/Rerun Failed Tests;\
waitfile:$WORK/t1-go;menu:Product/Rerun Failed Tests;waitlabel:Tests passed: 1 passed;wait:1;mark:t2;deeplabels;shot:rerun-failed;\
menustate:Product/Clear Coverage;menu:Product/Run Tests with Coverage;waitlabel:Tests passed: 2 passed;wait:1.5;menu:View/Navigators/Tests;wait:1.5;mark:t3;axfind:%;menustate:Product/Clear Coverage;shot:coverage;\
menu:Product/Clear Coverage;wait:1;mark:t4;axfind:%;menustate:Product/Clear Coverage;shot:coverage-cleared;mark:done;quit"
wait_mark t1 120 && touch "$R/ready.txt"
touch "$WORK/t1-go"
wait_mark done 240; finish 15
summary() { labels "$1" | grep -oE "Tests (passed|failed): [^|]*" | tail -1; }
check T1 "Product ▸ Test reports the failing test and enables Rerun Failed Tests" \
  'summary t1 | grep -q "1 passed, 1 failed" && after t1 "menustate Product/Rerun Failed Tests" | grep -q "enabled=1"' "$(summary t1) / $(after t1 "menustate Product/Rerun" | cut -c7-)"
check T2 "Product ▸ Rerun Failed Tests runs only the failed test, which now passes" \
  'summary t2 | grep -q "Tests passed: 1 passed"' "$(summary t2) — shots/rerun-failed.png"
COV=$(after t3 "axfind %" | sed "s/.*-> [0-9]*://" | grep -oE "[0-9]+(\.[0-9]+)?%" | head -1)
COV4=$(after t4 "axfind %" | sed "s/.*-> [0-9]*://" | grep -oE "[0-9]+(\.[0-9]+)?%" | head -1)
check T3 "Run Tests with Coverage shows a package coverage percentage and enables Clear Coverage" \
  '[ -n "$COV" ] && after t2 "menustate Product/Clear Coverage" | grep -q "enabled=0" && after t3 "menustate Product/Clear Coverage" | grep -q "enabled=1"' "coverage label: ${COV:-none} / before: $(after t2 "menustate Product/Clear" | cut -c7-) — shots/coverage.png"
check T4 "Product ▸ Clear Coverage removes the percentage and disables itself" \
  '[ -z "$COV4" ] && after t4 "menustate Product/Clear Coverage" | grep -q "enabled=0"' "$(after t4 "menustate Product/Clear" | cut -c7-) — shots/coverage-cleared.png"
! grep -q "DRIVE mark done$" "$LOG" && record T0 "The test session ran to the end" FAIL "last step: $(grep 'DRIVE' "$LOG" | tail -1 | cut -c1-160)"
rm -f "$R/ready.txt"

# ---- Debugger: Step Into, Evaluate Expression…, Copy Goroutine Dump, Step Out
pbpaste > "$WORK/clipboard.txt" 2>/dev/null && CLIP_SAVED=1
printf 'coverage-journey-sentinel' | pbcopy
launch debug "$R" "$R/main.go" "wait:10;fakeactive;mark:ready;bpclick:n := add(2, 3);wait:0.5;menu:Product/Debug;waitlabel:main.main;wait:1;mark:d0;deeplabels;menustate:Debug/Step Into;\
menu:Debug/Step Into;waitlabel:main.add;wait:1;mark:d1;deeplabels;edstate:d1;shot:step-into;\
menu:Debug/Evaluate Expression…;wait:1;focus;fr:a*10+b;frkey:insertNewline:;wait:2;mark:d2;axfind:a*10+b;axfind:23;shot:evaluate;\
menu:Debug/Copy Goroutine Dump;wait:1.5;mark:d3;pasteboard;\
menu:Debug/Step Out;waitlabel:main.main;wait:1;mark:d4;deeplabels;edstate:d4;shot:step-out;menu:Product/Stop;wait:2;mark:done;quit"
wait_mark done 180; finish 15
gor() { labels "$1" | grep -o "Goroutine #[^|]*" | head -1 | cut -c1-120; }
check D1 "Debug ▸ Step Into from the breakpoint in main enters add" \
  'gor d0 | grep -q "main.main" && gor d1 | grep -q "main.add" && after d0 "menustate Debug/Step Into" | grep -q "enabled=1"' "$(gor d0) -> $(gor d1); editor line $(stf d1 line) — shots/step-into.png"
check D2 "Debug ▸ Evaluate Expression… focuses the expression field and a*10+b evaluates to 23" \
  'after d2 "axfind a\*10+b" | grep -qv -- "-> 0:" && after d2 "axfind 23" | grep -qE "(: |‖ )23( ‖|$)"' "$(after d2 "axfind a" | cut -c7-) / $(after d2 "axfind 23" | cut -c7-) — shots/evaluate.png"
check D3 "Debug ▸ Copy Goroutine Dump puts a dump that names main.add on the pasteboard" \
  'after d3 "DRIVE pasteboard" | grep -q "main.add" && ! after d3 "DRIVE pasteboard" | grep -q "coverage-journey-sentinel"' "$(after d3 "DRIVE pasteboard" | cut -c7-180)"
check D4 "Debug ▸ Step Out returns to main" \
  'gor d4 | grep -q "main.main"' "$(gor d4); editor line $(stf d4 line) — shots/step-out.png"
! grep -q "DRIVE mark done$" "$LOG" && record D0 "The debug session ran to the end" FAIL "last step: $(grep 'DRIVE' "$LOG" | tail -1 | cut -c1-160)"

# ---- Source control: Stage All, Unstage All, Stash Changes…, Discard All Changes… (tracked changes only, so nothing goes to the Trash)
launch scm "$G" "$G/main.go" "wait:10;fakeactive;mark:ready;menu:Source Control/Refresh File Status;wait:2;menustate:Source Control/Stage All Changes;\
menu:Source Control/Stage All Changes;wait:2.5;mark:g1;waitfile:$WORK/g1-go;menu:Source Control/Unstage All Changes;wait:2.5;mark:g2;waitfile:$WORK/g2-go;\
menu:Source Control/Stash Changes…;wait:1.5;mark:g3-sheet;deeplabels;sheetshot:stash;field:0:coverage stash;axpress:Stash;wait:3;mark:g3;waitfile:$WORK/g3-go;\
menu:Source Control/Refresh File Status;wait:2.5;menu:Source Control/Discard All Changes…;wait:1.5;mark:g4-alert;sheetshot:discard;sheetpress:Discard Changes;wait:3;mark:g4;deeplabels;mark:done;quit"
gstat() { git -C "$G" status --porcelain 2>/dev/null | tr '\n' ';'; }
G1=; G2=; G3=; G3S=
wait_mark g1 60 && G1=$(gstat); touch "$WORK/g1-go"
wait_mark g2 30 && G2=$(gstat); touch "$WORK/g2-go"
if wait_mark g3 30; then G3=$(gstat); G3S=$(git -C "$G" stash list 2>/dev/null | head -1); printf 'package main\n\nfunc helper() int { return 3 }\n' > "$G/helper.go"; fi
touch "$WORK/g3-go"
wait_mark done 60; finish 15
G4=$(gstat)
check G1 "Source Control ▸ Stage All Changes stages both modified files" \
  'after ready "menustate Source Control/Stage All Changes" | grep -q "enabled=1" && [ "$G1" = "M  helper.go;M  main.go;" ]' "git status: $G1"
check G2 "Source Control ▸ Unstage All Changes unstages them again" '[ "$G2" = " M helper.go; M main.go;" ]' "git status: $G2"
check G3 "Source Control ▸ Stash Changes… asks for a message and stashes every change" \
  'labels g3-sheet | grep -q "Stash Changes" && [ -z "$G3" ] && echo "$G3S" | grep -q "coverage stash"' "status: ${G3:-clean} / stash: ${G3S:-none} — shots/stash.png"
check G4 "Source Control ▸ Discard All Changes… asks first and returns the changed file to the last commit" \
  'after g4-alert "sheetpress Discard Changes" | grep -q -- "-> 1" && [ -z "$G4" ] && grep -q "return 1" "$G/helper.go"' "$(after g4-alert "sheetpress" | cut -c7-) / status: ${G4:-clean} — shots/discard.png"
! grep -q "DRIVE mark done$" "$LOG" && record G0 "The source control session ran to the end" FAIL "last step: $(grep 'DRIVE' "$LOG" | tail -1 | cut -c1-160)"

# ---- Help ▸ Keyboard Shortcuts: menu grouping, search filtering, empty state & reset, live preset sync
printf '{\n  "format": "golens-keymap",\n  "version": 1,\n  "preset": "vscode",\n  "overrides": {}\n}\n' > "$WORK/vscode-keymap.json"
launch shortcuts "$G" "$G/main.go" "wait:8;fakeactive;\
menu:Help/Keyboard Shortcuts;wait:1.5;mark:k1-open;winlabels:Keyboard Shortcuts;wintable:Keyboard Shortcuts;lightmode;wait:0.8;winshot:Keyboard Shortcuts|shortcuts-light;darkmode;wait:0.8;winshot:Keyboard Shortcuts|shortcuts-dark;\
fieldl:Keyboard Shortcuts|Search Keyboard Shortcuts|Go to Definition|noreturn;wait:0.8;mark:k2-search;winlabels:Keyboard Shortcuts;wintable:Keyboard Shortcuts;\
fieldl:Keyboard Shortcuts|Search Keyboard Shortcuts|zzzznotacommand|noreturn;wait:0.8;mark:k2-empty;winlabels:Keyboard Shortcuts;wintable:Keyboard Shortcuts;\
winpress:Keyboard Shortcuts|Reset Filters;wait:0.8;mark:k2-reset;winlabels:Keyboard Shortcuts;wintable:Keyboard Shortcuts;\
stubpanel:$WORK/vscode-keymap.json;menu:GoLens/Settings…;wait:2;winpress:Settings|Key Bindings;wait:1.5;winpress:Settings|Import…;wait:1.5;winpress:Settings|Import;wait:1.5;\
fieldl:Keyboard Shortcuts|Search Keyboard Shortcuts|Go to Definition|noreturn;wait:0.8;mark:k3-vscode;winlabels:Keyboard Shortcuts;wintable:Keyboard Shortcuts;\
winclose:Settings;winclose:Keyboard Shortcuts;mark:done;quit"
wait_mark done 60; finish 15
check K1 "Help ▸ Keyboard Shortcuts opens the searchable shortcuts window grouped by menu" \
  'after k1-open "winlabels:" 20000 | grep -q "GoLens Keymap" && after k1-open "wintable:" 20000 | grep -q "File" && after k1-open "wintable:" 20000 | grep -q "New File"' "shots/shortcuts-light.png, shots/shortcuts-dark.png"
check K2 "Keyboard Shortcuts filters via search, shows No Matching Shortcuts when empty, and Reset Filters restores the list" \
  'after k2-search "wintable:" 20000 | grep -q "Navigate" && after k2-search "wintable:" 20000 | grep -q "⌃⌘J" && after k2-empty "winlabels:" 20000 | grep -q "No Matching Shortcuts" && after k2-reset "winlabels:" 20000 | grep -q "GoLens Keymap" && after k2-reset "wintable:" 20000 | grep -q "File"' "filtered Go to Definition -> empty -> reset"
check K3 "Changing preset in Settings updates the open Keyboard Shortcuts window live" \
  'after k3-vscode "winlabels:" 20000 | grep -q "VS Code Keymap" && after k3-vscode "wintable:" 20000 | grep -q "F12" && ! after k3-vscode "wintable:" 20000 | grep -q "⌃⌘J"' "GoLens (⌃⌘J) -> VS Code (F12)"
! grep -q "DRIVE mark done$" "$LOG" && record K0 "The keyboard shortcuts session ran to the end" FAIL "last step: $(grep 'DRIVE' "$LOG" | tail -1 | cut -c1-160)"

# ---- Help ▸ Report a Problem…: lists items, unchecking and removing leave them out of the saved zip, no user paths
REPORT_ZIP="$WORK/report-diagnostics.zip"
launch report "$G" "$G/main.go" "wait:6;fakeactive;mark:ready;\
menu:Help/Report a Problem…;wait:1.5;mark:r1-open;deeplabels;lightmode;wait:0.6;sheetshot:report-problem-light;darkmode;wait:0.6;sheetshot:report-problem-dark;\
axpress:Include GoLens Logs;wait:0.4;axpress:Remove MetricKit Diagnostics;wait:0.5;mark:r2-edited;deeplabels;\
stubpanel:$REPORT_ZIP;axpress:Save Diagnostics Archive;wait:1;mark:r3-saved;deeplabels;\
axpress:Close Report a Problem;wait:0.6;mark:done;quit"
wait_mark done 60; finish 15
REPORT_LIST=$(/usr/bin/unzip -l "$REPORT_ZIP" 2>&1 || true)
REPORT_ALL=$(/usr/bin/unzip -p "$REPORT_ZIP" 2>&1 || true)
R1_OPEN=$(sed -n '/mark r1-open$/,/mark r2-edited$/p' "$LOG")
R2_EDITED=$(sed -n '/mark r2-edited$/,/mark r3-saved$/p' "$LOG")
R3_SAVED=$(sed -n '/mark r3-saved$/,/mark done$/p' "$LOG")
check R1 "Help ▸ Report a Problem… lists the diagnostics, honors unchecked and removed items, and saves only the rest without user paths" \
  'echo "$R1_OPEN" | grep -q "Report a Problem" && echo "$R1_OPEN" | grep -q "App & System" && echo "$R1_OPEN" | grep -q "Go & gopls Toolchain" && echo "$R1_OPEN" | grep -q "MetricKit Diagnostics" && ! echo "$R2_EDITED" | grep -q "MetricKit Diagnostics" && echo "$R2_EDITED" | grep -q "2 items selected for export" && echo "$R3_SAVED" | grep -q "Saved report-diagnostics.zip" && [ -f "$REPORT_ZIP" ] && echo "$REPORT_LIST" | grep -q "system-info.txt" && echo "$REPORT_LIST" | grep -q "toolchain-health.txt" && ! echo "$REPORT_LIST" | grep -q "golens-logs.txt" && ! echo "$REPORT_LIST" | grep -q "metrickit-diagnostics.json" && ! echo "$REPORT_ALL" | grep -q "/Users/" && ! echo "$REPORT_ALL" | grep -qF "$G"' \
  "zip entries: $(echo "$REPORT_LIST" | tr '\n' ' ') — shots/report-problem-light.png, shots/report-problem-dark.png"
! grep -q "DRIVE mark done$" "$LOG" && record R0 "The Report a Problem session ran to the end" FAIL "last step: $(grep 'DRIVE' "$LOG" | tail -1 | cut -c1-160)"

# ---- About GoLens ▸ Acknowledgements: real Go version, license list, search, empty state
launch about "$G" "$G/main.go" "wait:6;fakeactive;mark:ready;\
menu:GoLens/About GoLens;wait:2.5;mark:a1-about;winlabels:About GoLens;winpress:About GoLens|Acknowledgements;wait:1.5;mark:a2-ack;winlabels:Acknowledgements;wintable:Acknowledgements;\
lightmode;wait:0.8;winshot:Acknowledgements|ack-light;darkmode;wait:0.8;winshot:Acknowledgements|ack-dark;\
fieldl:Acknowledgements|Search Components|pgx|noreturn;wait:0.8;mark:a3-search;winlabels:Acknowledgements;wintable:Acknowledgements;\
fieldl:Acknowledgements|Search Components|zzzznotacomponent|noreturn;wait:0.8;mark:a4-empty;winlabels:Acknowledgements;\
winclose:Acknowledgements;winclose:About GoLens;mark:done;quit"
wait_mark done 60; finish 15
check A1 "About GoLens shows the Go version of the installed toolchain and an Acknowledgements link" \
  'after a1-about "winlabels:" 20000 | grep -qE "[0-9]+\.[0-9]+(\.[0-9]+)?" && ! after a1-about "winlabels:" 20000 | grep -q "Micro-VM" && after a1-about "winlabels:" 20000 | grep -q "Acknowledgements"' "$(after a1-about "winlabels:" 400 | cut -c1-300)"
check A2 "Acknowledgements lists the bundled licenses and filters them by component" \
  'after a2-ack "winlabels:" 20000 | grep -q "56 open source components" && after a2-ack "wintable:" 20000 | grep -q "Go gopher" && after a3-search "wintable:" 20000 | grep -q "github.com/jackc/pgx/v5" && ! after a3-search "wintable:" 20000 | grep -q "Go gopher" && after a4-empty "winlabels:" 20000 | grep -q "No Matching Components"' "shots/ack-light.png, shots/ack-dark.png"
! grep -q "DRIVE mark done$" "$LOG" && record A0 "The About and Acknowledgements session ran to the end" FAIL "last step: $(grep 'DRIVE' "$LOG" | tail -1 | cut -c1-160)"

printf '\n%-5s %-6s  %s\n' ID RESULT CHECK
fails=0
while IFS=$'\t' read -r id name res_status ev; do
  [ "$res_status" = FAIL ] && fails=$((fails + 1))
  printf '%-5s %-6s  %s\n        %s\n' "$id" "$res_status" "$name" "$ev"
done < "$RESULTS"
echo "Runtime: $(( $(date +%s) - START ))s. Artifacts: $ART"
[ $fails -eq 0 ] && echo "No failures." || echo "$fails failure(s)."
exit $([ $fails -eq 0 ] && echo 0 || echo 1)
