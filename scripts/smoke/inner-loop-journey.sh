#!/bin/bash
# Inner-loop journey: Format Document undo, Next/Previous Issue, live templates, Surround With, multiple cursors,
# Move Symbol to another package, inline rename,
# and the debugger's Pause, Run to Cursor, function breakpoints and goroutine filter.
# Usage: scripts/smoke/inner-loop-journey.sh [path/to/GoLensApp] [--keep]
# Prefs live in the dev.golens.test.innerloop domain (never the owner's GoLensApp domain).
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=$REPO/.build/release/GoLensApp
KEEP=0
for a in "$@"; do case $a in --keep) KEEP=1 ;; *) BIN=$a ;; esac; done
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }

DOMAIN=dev.golens.test.innerloop
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
mkdir -p "$CONTAINER_DIR/tmp"
WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-inner.XXXXXX")" && pwd -P)
ART=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-inner-artifacts.XXXXXX")" && pwd -P)
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


E=$WORK/edit
D=$WORK/loop
R=$WORK/rename
mkdir -p "$E" "$D" "$R"
printf 'module example.com/edit\n\ngo 1.22\n' > "$E/go.mod"
printf 'package main\n\nimport (\n\t"strings"\n\t"fmt"\n)\n\nfunc greet(name string) string {\n\treturn "hi " + strings.ToUpper(name)\n}\n\nfunc main() {\n\tx := 1\n\ty := x + 2\n\tfmt.Println(greet("a"), x, y)\n}\n' > "$E/main.go"
printf 'package main\n\nfunc broken() {\n\t_ = missingOne\n\n\t_ = missingTwo\n}\n' > "$E/issues.go"
printf 'package main\n\nfunc clean() int {\n\treturn 1\n}\n' > "$E/clean.go"
printf 'package main\n\nimport "fmt"\n\nfunc report(id int, name string) {\n\tfmt.Printf("%%d %%s\\n",\n\t\tid,\n\t\tname)\n}\n' > "$E/sig.go"
printf '//go:build ignore\n\npackage main\n\nimport "fmt"\n\nfunc main() {\n\tfmt.Println("a"\n\tif len("x") > 0\n}\n' > "$E/stmt.go"
printf '//go:build ignore\n\npackage main\n\n// Run does work.\nfunc run() {\n\ta := 1\n\tif a > 0 {\n\t\ta++\n\t}\n\tb := a +\n\t\t2\n\t_ = b\n}\n' > "$E/lines.go"
printf 'module example.com/rename\n\ngo 1.22\n' > "$R/go.mod"
printf 'package main\n\nimport (\n\t"fmt"\n\t"strings"\n)\n\nfunc greet(name string) string {\n\treturn "hi " + strings.ToUpper(name)\n}\n\nfunc main() {\n\tx := 1\n\tfmt.Println(greet("a"), x)\n}\n' > "$R/main.go"
printf 'package main\n\nfunc welcome() string {\n\treturn greet("b")\n}\n' > "$R/use.go"
printf 'module example.com/loop\n\ngo 1.22\n' > "$D/go.mod"
printf 'package main\n\nimport (\n\t"fmt"\n\t"time"\n)\n\nfunc tick(i int) int {\n\treturn i * 2\n}\n\nfunc worker(ch chan int) {\n\tfor v := range ch {\n\t\t_ = v\n\t}\n}\n\nfunc main() {\n\tch := make(chan int)\n\tgo worker(ch)\n\ttotal := 0\n\tfor i := 0; ; i++ {\n\t\ttotal += tick(i)\n\t\ttime.Sleep(50 * time.Millisecond)\n\t\tif i%%100 == 0 {\n\t\t\tfmt.Println("tick", i, total)\n\t\t}\n\t}\n}\n' > "$D/main.go"

M=$WORK/mc
mkdir -p "$M"
printf 'module example.com/mc\n\ngo 1.22\n' > "$M/go.mod"
printf 'package main\n\nimport "fmt"\n\nfunc main() {\n\talpha := 1\n\tbeta := 2\n\tgamma := 3\n\tfmt.Println(alpha, beta, gamma)\n\tfmt.Println(alpha)\n}\n' > "$M/main.go"

V=$WORK/move
mkdir -p "$V/util" "$V/text" "$V/cmd"
printf 'module example.com/move\n\ngo 1.22\n' > "$V/go.mod"
printf 'package util\n\nimport "strings"\n\n// Shout returns s in capitals.\nfunc Shout(s string) string {\n\treturn strings.ToUpper(s)\n}\n\nfunc Local() string { return Shout("x") }\n' > "$V/util/util.go"
printf 'package text\n\nfunc Trim(s string) string { return s }\n' > "$V/text/text.go"
printf 'package main\n\nimport (\n\t"fmt"\n\n\t"example.com/move/util"\n)\n\nfunc main() { fmt.Println(util.Shout("a")) }\n' > "$V/cmd/main.go"

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }
check() { if eval "$3"; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "$4"; fi; }
after() { sed -n "/mark $1\$/,\$p" "$LOG" | grep -m1 "$2" | cut -c1-${3:-400}; }
found() { sed -n "/mark $1\$/,\$p" "$LOG" | grep -A2 -m1 -F "find '$2" | grep -m1 -o "present\|absent"; }
textat() { sed -n "/mark $1\$/,/^>>>/p" "$LOG"; }
labels() { after "$1" "deeplabels:" 6000; }
popup() { sed -n "/mark $1\$/,\$p" "$LOG" | grep -m1 "deeplabels:" | cut -c1-1500; }
windows() { sed -n "/mark $1\$/,/wininfo end/p" "$LOG"; }

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


launch() {
  LOG=$ART/logs/$1.log
  GOLENS_MEASURE=1 DRIVE="$4" DRIVE_OUT=$LOG DRIVE_SHOTS=$ART/shots DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
    "$APP" -GoLensLastWorkspacePath "$2" -GoLensLastFilePath "$3" > "$ART/logs/$1.app.log" 2>&1 &
  APP_PID=$!
}

echo "GoLens inner-loop journey — $(basename "$BIN") — artifacts: $ART"

launch edit "$E" "$E/main.go" "wait:12;fakeactive;mark:ready;wait:6;\
caret:x := 1;postkey:49, ;postkey:49, ;wait:0.8;mark:e1-typed;undotitle;find:x := 1  ;menu:Editor/Format Document;wait:3;mark:e1-fmt;undotitle;find:\"fmt\"\n\t\"strings\";find:x := 1  ;\
undo;wait:0.5;mark:e1-undo;undotitle;find:\"strings\"\n\t\"fmt\";find:x := 1  ;undo;wait:0.5;mark:e1-undo2;find:x := 1  ;find:\"strings\"\n\t\"fmt\";redo;redo;wait:0.5;mark:e1-redo;find:\"fmt\"\n\t\"strings\";find:x := 1  ;\
select:x := 1\n\ty := x + 2;menu:Editor/Surround With…;wait:1.5;mark:e3-popup;deeplabels;panelshot:e3-popup-dark;lightmode;wait:0.6;panelshot:e3-popup-light;darkmode;axpress:if, Run the lines only when a condition holds;wait:1.5;mark:e3-wrapped;line;text;undotitle;undo;wait:0.5;mark:e3-undo;text;\
caret:y := x + 2;typefast:\n\tprl;wait:2.5;mark:e2-panel;panel;code:\t;wait:1.5;mark:e2-expanded;line;undotitle;undo;wait:0.5;mark:e2-undo;line;\
axpress:issues.go;wait:8;caret:package main;menu:Navigate/Next Issue;wait:1;mark:e4-n1;line;menu:Navigate/Next Issue;wait:1;mark:e4-n2;line;menu:Navigate/Next Issue;wait:1;mark:e4-n3;line;menu:Navigate/Previous Issue;wait:1;mark:e4-p1;line;wininfo;postkey:36,,0,-3;wait:0.8;mark:e4-stale;text;postkey:53;wait:0.5;\
axpress:clean.go;wait:6;menu:Navigate/Next Issue;wait:1;mark:e4-none;deeplabels;\
axpress:sig.go;wait:6;caret:\t\tid;menu:View/Parameter Info;wait:2;mark:e5-open;wininfo;key:moveDown:;wait:1.5;mark:e5-next-line;wininfo;caret:package main;wait:1.5;mark:e5-outside;wininfo;\
axpress:stmt.go;wait:5;caret:Println(\"a;menu:Editor/Complete Current Statement;wait:0.6;mark:e6-call;text;undotitle;undo;wait:0.5;mark:e6-call-undo;text;\
caret:> 0;menu:Editor/Complete Current Statement;wait:0.6;mark:e6-if;text;undotitle;code:_ = 1;wait:0.8;mark:e6-typed;text;\
axpress:lines.go;wait:5;caret:b := a +;menu:Edit/Join Lines;wait:0.6;mark:e7-join;text;undotitle;\
caret:_ = b;menu:Edit/Move Statement Up;wait:0.5;menu:Edit/Move Statement Up;wait:0.6;mark:e7-up;text;undotitle;\
menu:Edit/Move Statement Up;wait:0.5;menu:Edit/Move Statement Up;wait:0.8;mark:e7-edge;deeplabels;text;\
postkey:125,,11010048;wait:0.8;mark:e7-line;text;undotitle;\
caret:Run does;code:\n;wait:0.6;mark:e7-comment;text;\
axpress:main.go;wait:4;caret:fmt.Println(greet;mark:e8-pre;line;postkey:49, ,524288;wait:4;mark:e8-qdef;wininfo;panelshot:e8-qdef-dark;lightmode;wait:0.6;panelshot:e8-qdef-light;darkmode;\
postkey:53;wait:0.8;mark:e8-esc;line;menu:View/Quick Definition;wait:3;mark:e8-again;wininfo;postkey:36;wait:2;mark:e8-open;line;\
mark:done;quit"
wait_mark done 180; finish 20

launch rename "$R" "$R/main.go" "wait:12;fakeactive;mark:ready;wait:10;\
caret:fmt.Println(greet;mark:e9-pre;line;menu:Editor/Rename Symbol…;wait:3;mark:e9-open;wininfo;focus;line;panelshot:e9-hint-dark;lightmode;wait:0.6;panelshot:e9-hint-light;darkmode;\
keys:salute;wait:0.8;mark:e9-typed;text;lightmode;wait:0.6;shot:e9-typed-light;darkmode;wait:0.6;shot:e9-typed-dark;postkey:53;wait:0.8;mark:e9-esc;text;line;wininfo;\
postkey:120;wait:3;keys:zz;postkey:6,z,1048576;wait:0.8;mark:e9-cmdz;text;\
postkey:120;wait:3;keys:a ;wait:0.6;mark:e9-space;wininfo;postkey:53;wait:0.6;\
postkey:120;wait:3;keys:1x;postkey:36;wait:1;mark:e9-digit;wininfo;text;postkey:53;wait:0.6;\
postkey:120;wait:3;keys:salute;postkey:36;wait:8;mark:e9-done;text;undotitle;wininfo;undo;wait:1;mark:e9-undo;text;mark:done;quit"
wait_mark done 150; finish 20

launch loop "$D" "$D/main.go" "wait:12;fakeactive;mark:ready;wait:8;menustate:Debug/Pause;menustate:Debug/Run to Cursor;menu:Product/Debug;wait:30;mark:d0-running;menustate:Debug/Pause;deeplabels;menu:Debug/Pause;wait:5;mark:d1-paused;deeplabels;menustate:Debug/Run to Cursor;shot:d1-paused;\
caret:total += tick;menu:Debug/Run to Cursor;wait:8;mark:d2-rtc;deeplabels;\
menu:Debug/Add Function Breakpoint…;wait:1.5;sheetshot:d3-sheet-dark;field:0:main.tick;wait:0.5;axpress:Add;wait:2;mark:d3-added;axpress:Issues;wait:1;axpress:Breakpoints;wait:1;mark:d3-list;deeplabels;\
menu:Debug/Continue;wait:4;mark:d3-hit;deeplabels;\
fieldp:Filter:worker;wait:1;mark:d4-filter;deeplabels;fieldp:Filter:;wait:0.5;menu:Debug/Show System Goroutines;wait:1;mark:d4-system;deeplabels;menu:Debug/Show System Goroutines;wait:0.5;\
menu:Product/Stop;wait:3;mark:d5-stopped;menustate:Debug/Pause;mark:done;quit"
wait_mark done 240; finish 20

launch mc "$M" "$M/main.go" "wait:12;fakeactive;mark:ready;wait:6;\
caret:\talpha;menu:Edit/Add Cursor Below;wait:0.3;menu:Edit/Add Cursor Below;wait:0.3;mark:m1;cursors;lightmode;wait:0.6;shot:m1-cursors-light;darkmode;wait:0.6;shot:m1-cursors-dark;\
postkey:7,x;postkey:16,y;wait:0.5;mark:m1-typed;cursors;text;undotitle;undo;wait:0.4;mark:m1-undo;cursors;text;\
key:moveRight:;wait:0.2;mark:m2-right;cursors;key:moveLeftAndModifySelection:;wait:0.2;mark:m2-extend;cursors;key:cancelOperation:;wait:0.2;mark:m2-esc;cursors;\
caret:alpha := 1;optclick:beta := 2;optclick:gamma := 3;mark:m3-added;cursors;optclick:beta := 2;mark:m3-removed;cursors;key:cancelOperation:;\
optdrag:alpha := 1|gamma := 3;mark:m4-column;cursors;postkey:9,v;wait:0.4;mark:m4-typed;text;postkey:51,;wait:0.4;mark:m4-deleted;text;key:insertNewline:;wait:0.4;mark:m4-newline;text;undo;wait:0.3;key:cancelOperation:;\
select:alpha;menu:Find/Select Next Occurrence;wait:0.3;menu:Find/Select Next Occurrence;wait:0.3;mark:m5-selected;cursors;shot:m5-selections-dark;postkey:6,z;wait:0.4;mark:m5-typed;cursors;text;undo;wait:0.4;mark:m5-undo;cursors;text;key:cancelOperation:;\
caret:alpha := 1;optclick:beta := 2;imecode:ab;wait:1;mark:m6-ime;cursors;text;undo;wait:0.3;mark:m6-undo;text;key:cancelOperation:;\
caret:\talpha;ctrlshiftclick:gamma := 3;mark:m7-added;cursors;key:moveWordRight:;wait:0.2;mark:m7-word;cursors;key:moveToLeftEndOfLineAndModifySelection:;wait:0.2;key:insertTab:;wait:0.4;mark:m7-indent;text;key:insertBacktab:;wait:0.4;mark:m7-outdent;text;cursors;mark:done;quit"
wait_mark done 120; finish 20

launch move "$V" "$V/util/util.go" "wait:12;fakeactive;mark:ready;wait:8;caret:func Shout;menu:Editor/Move Symbol…;wait:1.5;mark:v1-sheet;deeplabels;sheetshot:v1-sheet;field:0:text/text.go;wait:0.4;axpress:Move Symbol to Destination File;wait:8;mark:v1-moved;text;deeplabels;save;wait:2;\
caret:func Local;menu:Editor/Move Symbol…;wait:1.5;field:0:cmd/main.go;wait:0.4;axpress:Move Symbol to Destination File;waitlabel:other packages cannot import;mark:v2-refused;deeplabels;text;mark:done;quit"
wait_mark done 120; finish 20
MOVE_TEXT=$(cat "$V/text/text.go" 2>/dev/null)
MOVE_MAIN=$(cat "$V/cmd/main.go" 2>/dev/null)
MOVE_UTIL=$(cat "$V/util/util.go" 2>/dev/null)
MOVE_VET=$(cd "$V" && go vet ./... 2>&1 | head -3)

LOG=$ART/logs/edit.log
check I1a "Format Document is one undo step named Format Document and sorts the imports and trims the line" \
  'after e1-fmt "undotitle" | grep -q "Format Document canUndo=1" && [ "$(found e1-fmt \"fmt\")" = present ] && [ "$(found e1-fmt "x := 1  ")" = absent ]' \
  "$(after e1-fmt undotitle) / imports sorted: $(found e1-fmt \"fmt\") / trailing spaces: $(found e1-fmt 'x := 1  ')"
check I1b "Undo restores the text from before the format, and the typing before it is still its own undo step" \
  '[ "$(found e1-undo \"strings\")" = present ] && [ "$(found e1-undo "x := 1  ")" = present ] && after e1-undo undotitle | grep -q "Typing canUndo=1" && [ "$(found e1-undo2 "x := 1  ")" = absent ] && [ "$(found e1-undo2 \"strings\")" = present ]' \
  "after undo: $(after e1-undo undotitle), unsorted imports $(found e1-undo \"strings\"), typed spaces $(found e1-undo 'x := 1  '); after second undo: typed spaces $(found e1-undo2 'x := 1  ')"
check I1c "Redo brings the typing and then the format back" \
  '[ "$(found e1-redo \"fmt\")" = present ] && [ "$(found e1-redo "x := 1  ")" = absent ]' \
  "imports sorted: $(found e1-redo \"fmt\") / trailing spaces: $(found e1-redo 'x := 1  ')"
I2=$(after e3-wrapped "line:")
check I2a "Editor ▸ Surround With… lists the wrappers and the live templates that take a selection" \
  'labels e3-popup | grep -q "Filter Wrappers | if, Run the lines only when a condition holds | for, Repeat the lines in a loop" && labels e3-popup | grep -q "prl, Log a value with its name"' \
  "$(labels e3-popup | grep -o 'Filter Wrappers.*prl, Log a value with its name' | cut -c1-200) — shots/e3-popup-*.png"
check I2b "Choosing if wraps the selected lines, selects the condition, and one Undo named Surround With restores them" \
  'echo "$I2" | grep -q "if condition {" && echo "$I2" | grep -q "sel={[0-9]*, 9}" && after e3-wrapped undotitle | grep -q "Surround With canUndo=1" && [ "$(sed -n "/mark e3-undo\$/,\$p" "$LOG" | grep -c "if condition")" -eq 0 ]' \
  "${I2:-no line} / $(after e3-wrapped undotitle)"
check I3a "Typing a live template abbreviation offers it first in completion as a snippet" \
  'after e2-panel "panel " | grep -q "rows=prl, snippet, Log a value with its name"' "$(after e2-panel 'panel ' | grep -o 'rows=.*' | cut -c1-120)"
check I3b "Tab expands the template, and one Undo named Insert Template brings the abbreviation back" \
  'after e2-expanded "line:" | grep -q "log.Printf(\" = %v" && after e2-expanded undotitle | grep -q "Insert Template canUndo=1" && after e2-undo "line:" | grep -q "	prl⏎"' \
  "$(after e2-expanded 'line:' | cut -c1-90) / $(after e2-undo 'line:' | cut -c1-60)"
check I4a "Next Issue walks the file's issues in order and wraps; Previous Issue wraps backwards" \
  'after e4-n1 "line:" | grep -q "missingOne⏎" && after e4-n2 "line:" | grep -q "missingTwo⏎" && after e4-n3 "line:" | grep -q "missingOne⏎" && after e4-p1 "line:" | grep -q "missingTwo⏎"' \
  "$(for m in e4-n1 e4-n2 e4-n3 e4-p1; do after $m 'line:' | grep -o 'missing[A-Za-z]*' | tr '\n' ' '; done)"
check I4b "The issue under the caret is shown in the issue popup" \
  'after e4-p1 "IssuePopupView" | grep -q "undefined: missingTwo"' "$(after e4-p1 IssuePopupView | grep -o 'text=.*' | cut -c1-100)"
check I4d "A Return pressed before the issue popup opened does not apply its quick fix" \
  '! textat e4-stale | grep -q "var missingTwo" && grep -q "quick fix ignored a key pressed before" "$ART/logs/edit.app.log"' \
  "$(textat e4-stale | grep -c "var missing") fixes in the file after a stale Return"
check I4c "In a file without issues Next Issue says so" \
  'labels e4-none | grep -q "No issues in this file."' "$(labels e4-none | grep -o 'Next Issue[^|]*| No issues[^|]*' | head -1)"

check I11a "View ▸ Parameter Info inside a call shows the called function's signature" \
  'windows e5-open | grep -q "Printf("' "$(windows e5-open | grep -o 'Printf([^|]*' | head -1)"
check I11b "Moving the caret to the next line of the same call keeps the signature shown" \
  'windows e5-next-line | grep -q "Printf("' "signature still shown after moving down"
check I11c "Moving the caret out of the call closes the signature" \
  '! windows e5-outside | grep -q "Printf("' "signature closed outside the call"
joined() { textat "$1" | tr '\n' '~'; }
check I12a "Complete Current Statement closes the call, opens an indented line below, and undoes in one step" \
  'joined e6-call | grep -qF "$(printf "\tfmt.Println(\"a\")~\t~\tif")" && after e6-call undotitle | grep -q "Complete Current Statement canUndo=1" && joined e6-call-undo | grep -qF "$(printf "\tfmt.Println(\"a\"~\tif")"' \
  "$(joined e6-call | grep -o 'Println[^}]*' | head -1 | cut -c1-80) / $(after e6-call undotitle)"
check I12b "Complete Current Statement adds braces after if and puts the caret inside the block" \
  'joined e6-if | grep -qF "$(printf "\tif len(\"x\") > 0 {~\t\t~\t}~}")" && joined e6-typed | grep -qF "$(printf "> 0 {~\t\t_ = 1~\t}")"' \
  "$(joined e6-typed | grep -o 'if len.*' | cut -c1-80)"
check I13a "Join Lines joins the continuation line with one space and is one undo step" \
  'joined e7-join | grep -qF "$(printf "\tb := a + 2~\t_ = b")" && after e7-join undotitle | grep -q "Join Lines canUndo=1"' \
  "$(joined e7-join | grep -o 'b := a[^~]*' | head -1) / $(after e7-join undotitle)"
check I13b "Move Statement Up moves past a whole if block and stops at the start of the function body with a reason" \
  'joined e7-up | grep -qF "$(printf "\t_ = b~\tif a > 0 {~\t\ta++~\t}~\tb := a + 2")" && after e7-up undotitle | grep -q "Move Statement Up canUndo=1" && joined e7-edge | grep -qF "$(printf "func run() {~\t_ = b~\ta := 1~\tif")" && labels e7-edge | grep -q "already the first one in its block"' \
  "$(joined e7-edge | grep -o 'func run() {[^}]*' | head -1 | cut -c1-80)"
check I13c "Option-Down Arrow runs Move Line Down from the keymap" \
  'joined e7-line | grep -qF "$(printf "func run() {~\ta := 1~\t_ = b~\tif")" && after e7-line undotitle | grep -q "Move Line Down canUndo=1"' \
  "$(joined e7-line | grep -o 'func run() {[^}]*' | head -1 | cut -c1-80) / $(after e7-line undotitle)"
check I13d "Return in the middle of a comment continues it with // on the next line" \
  'joined e7-comment | grep -qF "// Run does~// work.~func run"' "$(joined e7-comment | grep -o '// Run[^f]*' | head -1)"
check I14a "Option-Space opens Quick Definition with focus, the file, line and source of greet" \
  'windows e8-qdef | grep "QuickDocumentationPopoverView" | grep -q "key=1" && windows e8-qdef | grep -q "main.go:8" && windows e8-qdef | grep -qF "func greet(name string) string {" && windows e8-qdef | grep -qF "return \"hi \" + strings.ToUpper(name)"' \
  "$(windows e8-qdef | grep -oE 'main.go:[0-9]+|func greet[^,]*' | head -2 | tr '\n' ' ' | cut -c1-120)"
check I14b "Esc closes Quick Definition and keeps the caret where it was" \
  '[ -n "$(after e8-pre "line:" | grep -o "sel=.*")" ] && [ "$(after e8-esc "line:" | grep -o "sel=.*")" = "$(after e8-pre "line:" | grep -o "sel=.*")" ]' \
  "$(after e8-pre 'line:' | grep -o 'sel=.*') -> $(after e8-esc 'line:' | grep -o 'sel=.*')"
check I14c "Return in Quick Definition opens greet in the editor" \
  'after e8-open "line:" | grep -qF "func greet(name string) string {⏎"' "$(after e8-open 'line:' | cut -c1-120)"
LOG=$ART/logs/rename.log
sel() { after "$1" "line:" | grep -o "sel=.*"; }
check I15a "Rename Symbol… renames in place: the name is selected, the hint shows the usages, and the editor keeps the keyboard" \
  'windows e9-open | grep -q "InlineRenameHintView" && after e9-open "firstResponder=" | grep -q "GoLensTextView" && windows e9-open | grep -qF "Rename ‘greet’" && windows e9-open | grep -q "2 usages in this file" && sel e9-open | grep -q ", 5}"' \
  "$(windows e9-open | grep -oE 'Rename ‘greet’|[0-9]+ usages? in this file' | tr '\n' ' ') $(after e9-open 'firstResponder=' | cut -c1-80) $(sel e9-open) — shots/e9-*.png"
check I15b "Typing the new name changes every usage in the file as you type" \
  'textat e9-typed | grep -qF "func salute(name string) string {" && textat e9-typed | grep -qF "fmt.Println(salute(\"a\"), x)"' \
  "$(textat e9-typed | grep -E 'func (greet|salute)|Println' | tr '\n' ' ' | cut -c1-160)"
check I15c "Esc puts the old name and the caret back and closes the hint" \
  'textat e9-esc | grep -qF "func greet(name string)" && ! textat e9-esc | grep -q salute && [ "$(sel e9-esc)" = "$(sel e9-pre)" ] && ! windows e9-esc | grep -q InlineRenameHintView' \
  "$(sel e9-pre) -> $(sel e9-esc), salute left: $(textat e9-esc | grep -c salute)"
check I15d "Command-Z while renaming cancels it instead of undoing older edits" \
  'textat e9-cmdz | grep -qF "func greet(name string)" && textat e9-cmdz | grep -qF "Println(greet(" && ! textat e9-cmdz | grep -q "zz"' \
  "$(textat e9-cmdz | grep -E 'func [a-z]+\(name|Println' | tr '\n' ' ' | cut -c1-160)"
check I15e "A space or a leading digit is refused and the hint says why" \
  'windows e9-space | grep -qF "Go names use only letters, digits and _." && windows e9-digit | grep -qF "A Go name can’t start with a digit." && textat e9-digit | grep -qF "func 1x(name"' \
  "$(windows e9-space | grep -oF 'Go names use only letters, digits and _.' | head -1) / $(windows e9-digit | grep -oF 'A Go name can’t start with a digit.' | head -1)"
check I15f "Return renames greet everywhere, including another file, as one undo step named Rename" \
  '! textat e9-done | grep -q greet && textat e9-done | grep -qF "func salute(name string)" && grep -qF "return salute(\"b\")" "$R/use.go" && after e9-done undotitle | grep -q "Rename canUndo=1" && ! windows e9-done | grep -q InlineRenameHintView' \
  "greet left: $(textat e9-done | grep -c greet), use.go: $(grep -o 'return [a-z]*' "$R/use.go"), $(after e9-done undotitle)"
check I15g "One Undo brings greet back in the file" \
  'textat e9-undo | grep -qF "func greet(name string)" && textat e9-undo | grep -qF "Println(greet(" && ! textat e9-undo | grep -q salute' \
  "$(textat e9-undo | grep -E 'func [a-z]+\(name|Println' | tr '\n' ' ' | cut -c1-160)"
LOG=$ART/logs/loop.log
check I5a "Pause and Run to Cursor are disabled with no debug session; Pause is enabled while the program runs" \
  'after ready "menustate Debug/Pause" | grep -q "enabled=0" && after ready "menustate Debug/Run to Cursor" | grep -q "enabled=0" && after d0-running "menustate Debug/Pause" | grep -q "enabled=1"' \
  "$(after ready 'menustate Debug/Pause' | cut -c7-40) / running: $(after d0-running 'menustate Debug/Pause' | cut -c7-40)"
check I5b "Debug ▸ Pause stops the running program and shows its goroutine, frames and variables" \
  'labels d1-paused | grep -q "Goroutine \[Goroutine #1: " && labels d1-paused | grep -q "| Continue | Step Over" && labels d1-paused | grep -q "Line 22: i: [0-9]"' \
  "$(labels d1-paused | grep -o 'Goroutine \[[^]]*\]') — shots/d1-paused.png"
check I5c "Run to Cursor stops on the caret line and leaves no breakpoint behind" \
  'labels d2-rtc | grep -q "Goroutine #1: main.main — main.go:23" && labels d3-list | grep -q "Breakpoints (1)"' \
  "$(labels d2-rtc | grep -o 'Goroutine \[[^]]*\]') / $(labels d3-list | grep -o 'Breakpoints ([0-9]*)')"
check I6 "A function breakpoint on main.tick is listed under Breakpoints and stops the program in that function" \
  'grep -q "field 0/1 -> ok value=main.tick" "$LOG" && labels d3-list | grep -q "Breakpoints (1)" && labels d3-hit | grep -q "Goroutine #1: main.tick — main.go:8"' \
  "$(labels d3-hit | grep -o 'Goroutine \[[^]]*\]')"
check I7a "The goroutine filter keeps the current goroutine listed and says why" \
  'labels d4-filter | grep -q "The current goroutine stays listed though it doesn’t match." && labels d4-filter | grep -q "Clear Filter"' \
  "$(labels d4-filter | grep -o 'The current goroutine[^|]*')"
check I7b "System goroutines are hidden by default and Show System Goroutines lists them all" \
  'labels d1-paused | grep -q "2 of 6 goroutines listed; 4 system goroutines hidden" && labels d4-system | grep -q "6 of 6 goroutines listed."' \
  "$(labels d1-paused | grep -o '[0-9]* of [0-9]* goroutines listed[^(|]*') / $(labels d4-system | grep -o '[0-9]* of [0-9]* goroutines listed')"
check I8 "Stop ends the session and Pause is disabled again" \
  'after d5-stopped "menustate Debug/Pause" | grep -q "enabled=0"' "$(after d5-stopped 'menustate Debug/Pause' | cut -c7-40)"
LOG=$ART/logs/mc.log
check I9a "Edit ▸ Add Cursor Below twice gives three insertion points in the same column, each drawn" \
  'after m1 "cursors " | grep -q "count=3 primary=0 cursors=48,60,71 indicators=2"' "$(after m1 'cursors ' | cut -c7-) — shots/m1-cursors-*.png"
check I9b "Typing goes to every cursor, and one Undo named Typing takes the whole run back and restores the cursors" \
  'textat m1-typed | grep -q "	alphaxy := 1" && textat m1-typed | grep -q "	gammaxy := 3" && after m1-typed undotitle | grep -q "Typing canUndo=1" && textat m1-undo | grep -q "	gamma := 3" && after m1-undo "cursors " | grep -q "count=3 primary=0 cursors=48,60,71"' \
  "typed: $(textat m1-typed | grep -c 'xy') lines with xy; after undo: $(after m1-undo 'cursors ' | cut -c7-)"
check I9c "Arrow keys move every cursor, Shift extends every selection, and Esc returns to one cursor" \
  'after m2-right "cursors " | grep -q "cursors=49,61,72" && after m2-extend "cursors " | grep -q "cursors=49-48,61-60,72-71" && after m2-esc "cursors " | grep -q "single {48, 0}"' \
  "$(after m2-right 'cursors ' | grep -o 'cursors=[^ ]*') / $(after m2-extend 'cursors ' | grep -o 'cursors=[^ ]*') / $(after m2-esc 'cursors ' | cut -c7-)"
check I9d "Option-click adds a cursor and Option-click on a cursor removes it" \
  'after m3-added "cursors " | grep -q "count=3 primary=2 cursors=53,55,66" && after m3-removed "cursors " | grep -q "count=2 primary=1 cursors=53,66"' \
  "$(after m3-added 'cursors ' | cut -c7-) / $(after m3-removed 'cursors ' | cut -c7-)"
check I9e "Option-drag down a column puts a cursor on every line; typing, Delete and Return act on each" \
  'after m4-column "cursors " | grep -q "count=3 primary=2 cursors=43,55,66" && textat m4-typed | grep -q "	vbeta := 2" && textat m4-typed | grep -q "	vgamma := 3" && ! textat m4-deleted | grep -q "	vbeta" && [ "$(textat m4-newline | grep -c "^	$")" -eq 3 ]' \
  "$(after m4-column 'cursors ' | cut -c7-); typed: $(textat m4-typed | grep -c '	v[a-z]* :=') lines; blank indented lines after Return: $(textat m4-newline | grep -c '^	$')"
check I9f "Select Next Occurrence adds each match as a selection; typing replaces them all and Undo restores the selections" \
  'after m5-selected "cursors " | grep -q "count=3 primary=2 cursors=43-48,90-95,123-128" && textat m5-typed | grep -q "fmt.Println(z, beta, gamma)" && textat m5-typed | grep -q "	z := 1" && after m5-undo "cursors " | grep -q "cursors=43-48,90-95,123-128" && textat m5-undo | grep -q "fmt.Println(alpha, beta, gamma)"' \
  "$(after m5-selected 'cursors ' | cut -c7-) / $(textat m5-typed | grep 'Println(z' | head -1) — shots/m5-selections-dark.png"
check I9g "Text composed with an input method is committed at every cursor, and one Undo removes it everywhere" \
  'textat m6-ime | grep -q "	alpha := 1ab" && textat m6-ime | grep -q "	abbeta := 2" && after m6-ime "cursors " | grep -q "count=2 primary=1 cursors=55,59" && textat m6-undo | grep -q "	alpha := 1$" && textat m6-undo | grep -q "	beta := 2"' \
  "$(textat m6-ime | grep 'ab' | tr '\n\t' '  ') / $(after m6-ime 'cursors ' | cut -c7-)"
check I9h "Control-Shift-click adds a cursor; word movement moves each; Tab and Shift-Tab indent and outdent every selected line" \
  'after m7-added "cursors " | grep -q "count=2 primary=1 cursors=48,66" && after m7-word "cursors " | grep -q "cursors=53,71" && textat m7-indent | grep -q "^		alpha := 1" && textat m7-indent | grep -q "^		gamma := 3" && textat m7-indent | grep -q "^	beta := 2" && textat m7-outdent | grep -q "^	alpha := 1" && textat m7-outdent | grep -q "^	gamma := 3"' \
  "$(after m7-added 'cursors ' | cut -c7-) / word: $(after m7-word 'cursors ' | grep -o 'cursors=[^ ]*') / indented lines: $(textat m7-indent | grep -c '^		[a-z]* :=') / after outdent: $(after m7-outdent 'cursors ' | grep -o 'cursors=[^ ]*')"
! grep -q "DRIVE mark done$" "$ART/logs/mc.log" && record I0c "The multiple-cursor journey ran to the end" FAIL "no done mark"
LOG=$ART/logs/move.log
check I10a "Move Symbol… explains that a path from the project root moves the declaration to that package" \
  'labels v1-sheet | grep -q "Move Symbol" && labels v1-sheet | grep -q "moves it to that package and updates every reference and import"' \
  "$(labels v1-sheet | grep -o 'A file name keeps[^|]*' | cut -c1-120) — shots/v1-sheet.png"
check I10b "Moving Shout to text/text.go moves it with its comment and import, and rewrites the uses in util and cmd" \
  'echo "$MOVE_TEXT" | grep -q "^func Shout(s string) string" && echo "$MOVE_TEXT" | grep -q "// Shout returns s in capitals." && echo "$MOVE_TEXT" | grep -q "\"strings\"" && echo "$MOVE_MAIN" | grep -q "text.Shout(\"a\")" && ! echo "$MOVE_MAIN" | grep -q "move/util\"" && echo "$MOVE_UTIL" | grep -q "text.Shout(\"x\")" && ! echo "$MOVE_UTIL" | grep -q "func Shout"' \
  "text.go has Shout: $(echo "$MOVE_TEXT" | grep -c '^func Shout'); main.go: $(echo "$MOVE_MAIN" | grep -o 'text.Shout("a")'); util.go: $(echo "$MOVE_UTIL" | grep -o 'text.Shout("x")')"
check I10c "The project still passes go vet after the move" '[ -z "$MOVE_VET" ]' "${MOVE_VET:-go vet: no findings}"
check I10d "A move that cannot compile is refused with the reason and changes nothing" \
  'labels v2-refused | grep -q "package main, which other packages cannot import" && textat v2-refused | grep -q "^func Local() string"' \
  "$(labels v2-refused | grep -o '[^|]*package main, which other packages cannot import[^|]*' | head -1 | cut -c1-160)"
! grep -q "DRIVE mark done$" "$ART/logs/move.log" && record I0d "The move journey ran to the end" FAIL "no done mark"
! grep -q "DRIVE mark done$" "$ART/logs/edit.log" && record I0a "The editing journey ran to the end" FAIL "no done mark"
! grep -q "DRIVE mark done$" "$ART/logs/loop.log" && record I0b "The debugger journey ran to the end" FAIL "no done mark"
! grep -q "DRIVE mark done$" "$ART/logs/rename.log" && record I0e "The rename journey ran to the end" FAIL "no done mark"
printf '\n%-5s %-6s  %s\n' ID RESULT CHECK
fails=0
while IFS=$'\t' read -r id name res_status ev; do
  [ "$res_status" = FAIL ] && fails=$((fails + 1))
  printf '%-5s %-6s  %s\n        %s\n' "$id" "$res_status" "$name" "$ev"
done < "$RESULTS"
echo "Runtime: $(( $(date +%s) - START ))s. Artifacts: $ART"
[ $fails -eq 0 ] && echo "No failures." || echo "$fails failure(s)."
exit $([ $fails -eq 0 ] && echo 0 || echo 1)
