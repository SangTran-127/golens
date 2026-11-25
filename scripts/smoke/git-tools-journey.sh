#!/bin/bash
# Git tools journey: the commit graph in History, interactive rebase and the three-column merge editor.
# Usage: scripts/smoke/git-tools-journey.sh [path/to/GoLensApp] [--keep]
# Prefs live in the dev.golens.test.gittools domain (never the owner's GoLensApp domain).
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=$REPO/.build/release/GoLensApp
KEEP=0
for a in "$@"; do case $a in --keep) KEEP=1 ;; *) BIN=$a ;; esac; done
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }

DOMAIN=dev.golens.test.gittools
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
if [ "${GOLENS_EXECUTION_MODE:-host}" = "vm" ]; then
  mkdir -p "$CONTAINER_DIR/tmp"
  WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-git.XXXXXX")" && pwd -P)
  ART=${GIT_TOOLS_ARTIFACTS:-$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-git-artifacts.XXXXXX")" && pwd -P)}
else
  WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/golens-git.XXXXXX")" && pwd -P)
  ART=${GIT_TOOLS_ARTIFACTS:-$(cd "$(mktemp -d "${TMPDIR:-/tmp}/golens-git-artifacts.XXXXXX")" && pwd -P)}
fi
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


gitq() { git -c user.name="Ann Lee" -c user.email=ann@example.com -c init.defaultBranch=main -c commit.gpgsign=false "$@" >/dev/null 2>&1; }

G=$WORK/graph
mkdir -p "$G"
gitq init "$G"
printf 'module example.com/graph\n\ngo 1.22\n' > "$G/go.mod"
printf 'package main\n\nfunc main() {}\n' > "$G/main.go"
gitq -C "$G" add -A; gitq -C "$G" commit -m "start the project"
gitq -C "$G" checkout -b topic; printf 'package main\n\nfunc topic() {}\n' > "$G/topic.go"; gitq -C "$G" add -A; gitq -C "$G" commit -m "add the topic helper"
gitq -C "$G" checkout main; printf 'package main\n\nfunc util() {}\n' > "$G/util.go"; gitq -C "$G" add -A; gitq -C "$G" commit -m "add the util helper"
gitq -C "$G" merge --no-ff --no-edit -m "merge the topic branch" topic
gitq -C "$G" checkout -b spike; printf 'package main\n\nfunc spike() {}\n' > "$G/spike.go"; gitq -C "$G" add -A; gitq -C "$G" commit -m "try a spike"
gitq -C "$G" checkout main; printf 'package main\n\nfunc main() { println() }\n' > "$G/main.go"; gitq -C "$G" commit -am "print on start"

R=$WORK/rebase
RR=$WORK/rebase-remote.git
gitq init --bare "$RR"
gitq clone "$RR" "$R"
printf 'module example.com/rebase\n\ngo 1.22\n' > "$R/go.mod"
gitq -C "$R" add -A; gitq -C "$R" commit -m "add one"
for w in two three four five; do printf '%s\n' "$w" > "$R/$w.txt"; gitq -C "$R" add -A; gitq -C "$R" commit -m "add $w"; [ $w = two ] && gitq -C "$R" push -u origin HEAD:main; done

C=$WORK/conflict
mkdir -p "$C"
gitq init "$C"
printf 'module example.com/conflict\n\ngo 1.22\n' > "$C/go.mod"
body() { printf 'package main\n\nfunc greet() string {\n\treturn %s\n}\n\nfunc middle() {\n\ta := 1\n\tb := 2\n\tc := 3\n\td := 4\n\te := 5\n\tf := 6\n\t_ = a + b + c + d + e + f\n}\n\nfunc count() int {\n\treturn %s\n}\n' "$1" "$2"; }
body '"hello"' 1 > "$C/main.go"
gitq -C "$C" add -A; gitq -C "$C" commit -m "base"
gitq -C "$C" checkout -b feature; body '"hey"' 3 > "$C/main.go"; gitq -C "$C" commit -am "feature greeting"
gitq -C "$C" checkout main; body '"hi"' 2 > "$C/main.go"; gitq -C "$C" commit -am "main greeting"
gitq -C "$C" -c merge.conflictStyle=diff3 merge feature

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }
check() { if eval "$3"; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "$4"; fi; }
after() { sed -n "/mark $1\$/,\$p" "$LOG" | grep -m1 "$2" | cut -c1-${3:-400}; }
found() { sed -n "/mark $1\$/,\$p" "$LOG" | grep -A2 -m1 -F "find '$2" | grep -m1 -o "present\|absent"; }
textat() { sed -n "/mark $1\$/,/^>>>/p" "$LOG"; }
labels() { after "$1" "deeplabels:" 6000; }
multilabels() { awk -v m="DRIVE mark $1" '$0==m{f=1;next} f && /^DRIVE /{if(p) exit; if(/^DRIVE deeplabels:/){p=1; print; next}} f && p{if(/^DRIVE /) exit; print}' "$LOG" | tr '\n' ' '; }
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


launch() {
  LOG=$ART/logs/$1.log
  GOLENS_MEASURE=1 DRIVE="$4" DRIVE_OUT=$LOG DRIVE_SHOTS=$ART/shots DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
    "$APP" -GoLensLastWorkspacePath "$2" -GoLensLastFilePath "$3" > "$ART/logs/$1.app.log" 2>&1 &
  APP_PID=$!
}

echo "GoLens git tools journey — $(basename "$BIN") — artifacts: $ART"

launch graph "$G" "$G/main.go" "wait:10;fakeactive;mark:ready;axpress:Source Control;wait:1.5;axpress:Show History;wait:3;mark:g1-history;axexists:merge the topic branch;axexists:add the topic helper;axexists:try a spike;shot:g1-graph-dark;lightmode;wait:0.6;shot:g1-graph-light;darkmode;\
axpress:All Branches;wait:3;mark:g2-all;axexists:try a spike;deeplabels;shot:g2-all-dark;\
lightmode;wait:0.6;menu:Editor/Show File History…;wait:4;mark:g3-file-history;deeplabels;sheetshot:g3-file-history-light;sheetpress:Close;wait:1;mark:done;quit"
wait_mark done 90; finish 15

LOG=$ART/logs/graph.log
check G1a "History lists the merge commit and the commit it merged from the topic branch" \
  'sed -n "/mark g1-history/,/mark g2-all/p" "$LOG" | grep -q "axexists merge the topic branch -> 1" && sed -n "/mark g1-history/,/mark g2-all/p" "$LOG" | grep -q "axexists add the topic helper -> 1" && sed -n "/mark g1-history/,/mark g2-all/p" "$LOG" | grep -q "axexists try a spike -> 0"' \
  "— shots/g1-graph-light.png, shots/g1-graph-dark.png"
check G1b "All Branches adds the unmerged spike branch and retitles the History" \
  'after g2-all "axexists try a spike" | grep -q -- "-> 1" && labels g2-all | grep -q "All Branches"' "— shots/g2-all-dark.png"
check G1c "Show File History… lists the file’s commits and shows the selected commit’s diff" \
  'after g3-file-history "deeplabels:" 60000 | grep -q "print on start" && after g3-file-history "deeplabels:" 60000 | grep -q "Added line 1: package main"' "— shots/g3-file-history-light.png"
! grep -q "DRIVE mark done$" "$LOG" && record G0a "The graph journey ran to the end" FAIL "no done mark"
launch rebase "$R" "$R/go.mod" "wait:10;fakeactive;mark:ready;menustate:Source Control/Interactive Rebase…;axpress:Source Control;wait:1.5;axpress:Show History;wait:3;\
rowmenu:add two|Interactively Rebase from Here…;wait:2.5;mark:r1-sheet;deeplabels;sheetshot:r1-sheet-dark;\
axpress:Move Up;wait:0.5;popupselect:Action for “add four”|Reword;wait:0.8;sheettext:0:add four, reworded;wait:0.4;popupselect:Action for “add three”|Fixup;popupselect:Action for “add five”|Drop;wait:0.6;mark:r2-plan;deeplabels;lightmode;wait:0.6;sheetshot:r2-plan-light;darkmode;\
axpress:Start Rebasing;waitlabel:Interactive Rebase Finished;mark:r3-done;deeplabels;wait:2;\
menu:Source Control/Interactive Rebase…;wait:2.5;mark:r4-sheet;deeplabels;popupselect:#0|Stop to Edit;wait:0.5;axpress:Start Rebasing;wait:4;mark:r4-stopped;deeplabels;axpress:OK;wait:2;mark:r4-header;deeplabels;shot:r4-header-dark;axpress:Continue;wait:4;mark:r5-continued;deeplabels;mark:done;quit"
wait_mark done 120; finish 15

LOG=$ART/logs/rebase.log
RB_LOG=$(git -C "$R" log --format=%s 2>/dev/null | tr '\n' '|')
RB_STATE=$(git -C "$R" status 2>/dev/null | head -3 | tr '\n' ' ')
check R1a "Interactively Rebase from Here… opens the plan oldest first, warns that a commit is on the remote and waits for a change" \
  'labels r1-sheet | grep -q "Interactive Rebase" && labels r1-sheet | grep -q "1 commit is already on a remote" && labels r1-sheet | grep -q "Change an action, a message or the order to rebase"' \
  "— shots/r1-sheet-dark.png"
check R1b "Moving a commit up, rewording, fixing up and dropping commits clears the problem line" \
  'sed -n "/mark r1-sheet$/,/mark r2-plan$/p" "$LOG" | grep -q "popupselect Action for “add five” -> Drop ok=1" && sed -n "/mark r1-sheet$/,/mark r2-plan$/p" "$LOG" | grep -q "sheettext 0/1 -> ok" && ! labels r2-plan | grep -q "Change an action, a message or the order"' \
  "$(sed -n "/mark r1-sheet$/,/mark r2-plan$/p" "$LOG" | grep -E "popupselect|sheettext" | cut -c7- | tr '\n' ';') — shots/r2-plan-light.png"
check R1c "Start Rebasing rewrites the branch: add four reworded with add three folded in, add five dropped" \
  '[ "$RB_LOG" = "add four, reworded|add two|add one|" ] && [ ! -e "$R/five.txt" ] && [ -e "$R/three.txt" ] && labels r3-done | grep -q "Interactive Rebase Finished"' \
  "git log: $RB_LOG"
check R2a "Source Control ▸ Interactive Rebase… is enabled and Stop to Edit stops the rebase with an explanation" \
  'after ready "menustate Source Control/Interactive Rebase" | grep -q "enabled=1" && labels r4-stopped | grep -q "The rebase stopped so you can change a commit" && labels r4-header | grep -q "Stopped so you can change a commit"' \
  "— shots/r4-header-dark.png"
check R2b "Continue finishes the stopped rebase" \
  '! labels r5-continued | grep -q "Rebase in Progress" && ! echo "$RB_STATE" | grep -qi "rebase in progress"' "$RB_STATE"
! grep -q "DRIVE mark done$" "$LOG" && record R0a "The rebase journey ran to the end" FAIL "no done mark"
launch merge "$C" "$C/main.go" "wait:10;fakeactive;mark:ready;wait:3;menustate:Source Control/Open in Merge Editor;menu:Source Control/Mark as Resolved;wait:2;mark:m0-unresolved;deeplabels;sheetpress:Cancel;wait:0.8;axpress:Open in Merge Editor;wait:2;mark:m1-open;deeplabels;shot:m1-editor-dark;lightmode;wait:0.6;shot:m1-editor-light;darkmode;\
axpress:Accept Left for Conflict 1;wait:0.6;mark:m2-left;deeplabels;axtext:Result of Conflict 2|\\treturn 42;wait:0.6;mark:m3-edited;deeplabels;shot:m3-edited-dark;\
axpress:Cancel;wait:1;mark:m4-confirm;deeplabels;axpress:Keep Editing;wait:0.6;mark:m4-kept;deeplabels;\
axpress:Apply Changes;wait:4;mark:m5-applied;deeplabels;text;mark:done;quit"
wait_mark done 90; finish 15

LOG=$ART/logs/merge.log
MERGE_FILE=$(cat "$C/main.go" 2>/dev/null)
MERGE_STATUS=$(git -C "$C" status --porcelain 2>/dev/null | tr '\n' ' ')
check M0b "Mark as Resolved on an unresolved conflict warns and offers Open in Merge Editor" \
  'labels m0-unresolved | grep -q "Couldn’t Mark “main.go” as Resolved" && labels m0-unresolved | grep -q "Open in Merge Editor"' ""
check M1a "The conflict banner opens the merge editor with Left, Result and Right columns and two unresolved conflicts" \
  'after ready "menustate Source Control/Open in Merge Editor" | grep -q "enabled=1" && labels m1-open | grep -q "Merge “main.go”" && labels m1-open | grep -q "2 conflicts left" && labels m1-open | grep -q "Conflict 1 of 2, unresolved" && labels m1-open | grep -q "Unchanged Lines"' \
  "— shots/m1-editor-dark.png, shots/m1-editor-light.png"
check M1b "Accept Left resolves the first conflict; typing in Result resolves the second" \
  'labels m2-left | grep -q "Conflict 1 of 2, resolved with Left" && labels m2-left | grep -q "1 conflict left" && sed -n "/mark m2-left$/,/mark m3-edited$/p" "$LOG" | grep -q "axtext Result of Conflict 2 -> ok" && labels m3-edited | grep -q "Conflict 2 of 2, resolved with Edited" && labels m3-edited | grep -q "All conflicts resolved"' \
  "$(sed -n "/mark m2-left$/,/mark m3-edited$/p" "$LOG" | grep -m1 axtext | cut -c7-) — shots/m3-edited-dark.png"
check M1c "Cancel with choices asks before discarding them, and Keep Editing keeps them" \
  'labels m4-confirm | grep -q "Discard your merge choices?" && labels m4-kept | grep -q "All conflicts resolved"' ""
check M1d "Apply Changes writes the result, leaves no markers and stages the file as resolved" \
  'echo "$MERGE_FILE" | grep -q "return \"hi\"" && echo "$MERGE_FILE" | grep -q "^	return 42$" && ! echo "$MERGE_FILE" | grep -q "<<<<<<<\|>>>>>>>\|=======" && echo "$MERGE_STATUS" | grep -q "^M  main.go"' \
  "status: $MERGE_STATUS"
! grep -q "DRIVE mark done$" "$LOG" && record M0a "The merge editor journey ran to the end" FAIL "no done mark"

ER=$WORK/err-remote.git
E=$WORK/errors
EO=$WORK/err-other
gitq init --bare "$ER"
gitq clone "$ER" "$E"
printf 'module example.com/err\n\ngo 1.22\n' > "$E/go.mod"
printf 'package main\n\nconst ver = 1\n\nfunc main() {}\n' > "$E/main.go"
gitq -C "$E" add -A; gitq -C "$E" commit -m "base"; gitq -C "$E" push -u origin HEAD:main
gitq -C "$E" checkout -b topic
printf 'package main\n\nconst ver = 99\n\nfunc main() {}\n' > "$E/main.go"
gitq -C "$E" commit -am "topic change"
gitq -C "$E" checkout main
gitq clone "$ER" "$EO"
printf 'remote\n' > "$EO/remote.txt"
gitq -C "$EO" add remote.txt; gitq -C "$EO" commit -m "remote advance"; gitq -C "$EO" push origin HEAD:main
printf 'local\n' > "$E/local.txt"
gitq -C "$E" add local.txt; gitq -C "$E" commit -m "local ahead"
gitq -C "$E" config pull.rebase true
printf 'package main\n\nconst ver = 2\n\nfunc main() {}\n' > "$E/main.go"

launch errors "$E" "$E/main.go" "wait:10;fakeactive;mark:ready;axpress:Source Control;wait:2;\
mark:e1-ready;waitfile:$WORK/e1-lock;\
menu:Source Control/Stage All Changes;wait:3.5;mark:e1-stage;deeplabels;axfind:index.lock;\
lightmode;wait:0.6;shot:e1-alert-light;darkmode;wait:0.6;shot:e1-alert-dark;\
mark:e1-unlock-ready;waitfile:$WORK/e1-unlock;\
sheetpress:Try Again;wait:3;mark:e1-recovered;\
waitfile:$WORK/e2-lock;\
menu:Source Control/Unstage All Changes;wait:3.5;mark:e2-unstage;deeplabels;axfind:index.lock;sheetpress:Cancel;wait:0.8;\
mark:e2-unlock-ready;waitfile:$WORK/e2-unlock;\
menu:Source Control/Commit…;wait:1.5;focusclass:CommitComposer;fr:blocked commit;wait:0.5;\
mark:e3-lock-ready;waitfile:$WORK/e3-lock;\
menu:Source Control/Commit Changes;wait:3.5;mark:e3-commit;deeplabels;axfind:index.lock;sheetpress:OK;wait:0.8;axpress:Close Commit Editor;wait:1.2;\
menu:Source Control/Discard Changes in Selected Files…;wait:1.5;sheetpress:Discard Changes;wait:3.5;mark:e4-discard;deeplabels;axfind:index.lock;sheetpress:Cancel;wait:0.8;\
mark:e4-unlock-ready;waitfile:$WORK/e4-unlock;axpress:Refresh Git Status;wait:1.5;\
axpress:Push;wait:3.5;mark:e5-push;deeplabels;\
sheetpress:Pull;wait:3.5;mark:e5-pull;deeplabels;sheetpress:Cancel;wait:0.8;\
axpress:Repositories;wait:2;rowmenu:topic|Switch to “topic”…;wait:1.5;sheetpress:Switch;wait:3;mark:e6-switch;deeplabels;sheetpress:Cancel;wait:0.8;\
axpress:Changes;wait:1.5;mark:e7-mv-ready;waitfile:$WORK/e7-mv;\
axpress:Refresh Git Status;wait:3;mark:e7-refresh;deeplabels;\
mark:e7-restore-ready;waitfile:$WORK/e7-restore;\
sheetpress:Try Again;wait:2.5;mark:e7-recovered;mark:done;quit"

E1_STAGED=; E7_STATUS=
if wait_mark e1-ready 60; then touch "$E/.git/index.lock"; fi; touch "$WORK/e1-lock"
if wait_mark e1-unlock-ready 30; then rm -f "$E/.git/index.lock"; fi; touch "$WORK/e1-unlock"
if wait_mark e1-recovered 30; then E1_STAGED=$(git -C "$E" status --porcelain 2>/dev/null | tr '\n' ' '); touch "$E/.git/index.lock"; fi; touch "$WORK/e2-lock"
if wait_mark e2-unlock-ready 30; then rm -f "$E/.git/index.lock"; fi; touch "$WORK/e2-unlock"
if wait_mark e3-lock-ready 30; then touch "$E/.git/index.lock"; fi; touch "$WORK/e3-lock"
if wait_mark e4-unlock-ready 40; then rm -f "$E/.git/index.lock"; gitq -C "$E" reset -q HEAD -- main.go; fi; touch "$WORK/e4-unlock"
if wait_mark e7-mv-ready 40; then cp "$E/.git/index" "$E/.git/index.bak"; printf 'BADINDEX' > "$E/.git/index"; fi; touch "$WORK/e7-mv"
if wait_mark e7-restore-ready 30; then mv -f "$E/.git/index.bak" "$E/.git/index"; fi; touch "$WORK/e7-restore"
if wait_mark e7-recovered 30; then E7_STATUS=$(git -C "$E" status --porcelain 2>/dev/null | tr '\n' ' '); fi
wait_mark done 40; finish 15

LOG=$ART/logs/errors.log
check E1a "Stage All Changes with index.lock shows Couldn’t Stage All Changes with index.lock details and Try Again" \
  'multilabels e1-stage | grep -q "Couldn’t Stage All Changes" && after e1-stage "axfind index.lock" | grep -Eq "axfind index\.lock -> [1-9]" && multilabels e1-stage | grep -q "Try Again"' \
  "— shots/e1-alert-light.png, shots/e1-alert-dark.png"
check E1b "Clicking Try Again after removing index.lock dismisses the alert and stages main.go" \
  'echo "$E1_STAGED" | grep -q "^M  main.go"' "status: ${E1_STAGED:-empty}"
check E2a "Unstage All Changes with index.lock shows Couldn’t Unstage All Changes and dismisses on Cancel" \
  'multilabels e2-unstage | grep -q "Couldn’t Unstage All Changes" && after e2-unstage "axfind index.lock" | grep -Eq "axfind index\.lock -> [1-9]" && sed -n "/mark e2-unstage/,/mark e2-unlock-ready/p" "$LOG" | grep -q "sheetpress Cancel -> 1"' ""
check E3a "Commit Changes with index.lock shows Couldn’t Commit and closes cleanly" \
  'multilabels e3-commit | grep -q "Couldn’t Commit" && after e3-commit "axfind index.lock" | grep -Eq "axfind index\.lock -> [1-9]" && sed -n "/mark e3-commit/,/mark e4-discard/p" "$LOG" | grep -q "sheetpress OK -> 1"' ""
check E4a "Discard Changes with index.lock shows Couldn’t Discard “main.go” and dismisses cleanly" \
  'multilabels e4-discard | grep -q "Couldn’t Discard “main.go”" && after e4-discard "axfind index.lock" | grep -Eq "axfind index\.lock -> [1-9]" && sed -n "/mark e4-discard/,/mark e4-unlock-ready/p" "$LOG" | grep -q "sheetpress Cancel -> 1"' ""
check E5a "Push rejected by non-fast-forward remote shows Couldn’t Push with Pull recovery" \
  'multilabels e5-push | grep -q "Couldn’t Push" && multilabels e5-push | grep -q "Pull" && sed -n "/mark e5-push/,/mark e5-pull/p" "$LOG" | grep -q "sheetpress Pull -> 1"' ""
check E5b "Pull recovery on dirty working tree shows Couldn’t Pull with Stash Changes… recovery" \
  'multilabels e5-pull | grep -q "Couldn’t Pull" && multilabels e5-pull | grep -q "cannot pull with rebase" && multilabels e5-pull | grep -q "Stash Changes…"' ""
check E6a "Switching branches with conflicting local changes shows Couldn’t Switch to “topic” with Stash and Switch" \
  'multilabels e6-switch | grep -q "Couldn’t Switch to “topic”" && multilabels e6-switch | grep -q "overwritten by checkout" && multilabels e6-switch | grep -q "Stash and Switch" && sed -n "/mark e6-switch/,/mark e7-mv-ready/p" "$LOG" | grep -q "sheetpress Cancel -> 1"' ""
check E7a "Explicit Refresh with a corrupt Git index shows Couldn’t Refresh File Status with Try Again" \
  'multilabels e7-refresh | grep -q "Couldn’t Refresh File Status" && multilabels e7-refresh | grep -q "index file smaller than expected" && multilabels e7-refresh | grep -q "Try Again"' ""
check E7b "Try Again after restoring the Git index recovers cleanly" \
  'sed -n "/mark e7-restore-ready/,/mark e7-recovered/p" "$LOG" | grep -q "sheetpress Try Again -> 1" && echo "$E7_STATUS" | grep -q "M main.go"' "status: ${E7_STATUS:-empty}"
! grep -q "DRIVE mark done$" "$LOG" && record E0a "The source control errors journey ran to the end" FAIL "no done mark"

WT=$WORK/wt-base
WT_LINK=$WORK/wt-branch
mkdir -p "$WT"
gitq init "$WT"
printf 'module example.com/worktrees\n\ngo 1.22\n' > "$WT/go.mod"
printf 'package main\n\nfunc main() {}\n' > "$WT/main.go"
gitq -C "$WT" add -A; gitq -C "$WT" commit -m "initial commit"

launch worktrees "$WT" "$WT/main.go" "wait:10;fakeactive;mark:ready;axpress:Source Control;wait:2;axpress:Repositories;wait:2;\
menu:Source Control/New Worktree…;wait:2;field:0:wt-feature;wait:0.4;field:1:$WT_LINK;wait:0.4;mark:w1-sheet;deeplabels;lightmode;wait:0.6;sheetshot:w1-sheet-light;darkmode;wait:0.6;sheetshot:w1-sheet-dark;\
axpress:Create Worktree;wait:4;mark:w1-created;windows;winkey:wt-base;wait:1.5;axpress:Repositories;wait:1.5;mark:w1-sidebar;wintable:wt-base;axfind:wt-branch;lightmode;wait:0.6;winshot:wt-base|w1-sidebar-light;darkmode;wait:0.6;winshot:wt-base|w1-sidebar-dark;\
winclose:wt-branch;wait:1.5;winkey:wt-base;wait:1.5;\
rowmenu:wt-feature|Switch to “wt-feature”…;wait:2.5;mark:w2-conflict;deeplabels;lightmode;wait:0.6;sheetshot:w2-conflict-light;darkmode;wait:0.6;sheetshot:w2-conflict-dark;\
sheetpress:Open Worktree;wait:3.5;mark:w3-opened;windows;\
winclose:wt-branch;wait:1.5;winkey:wt-base;wait:1.5;axpress:Repositories;wait:1.5;rowmenu:wt-branch|Remove Worktree…;wait:1.5;mark:w4-confirm;deeplabels;sheetpress:Remove;wait:3;mark:w4-removed;wintable:wt-base;axfind:wt-branch;winshot:wt-base|w4-removed-dark;mark:done;quit"
wait_mark done 120; finish 15

LOG=$ART/logs/worktrees.log
WT_LIST_AFTER=$(git -C "$WT" worktree list --porcelain 2>/dev/null | tr '\n' '|')
WT_HAS_FEATURE_BRANCH=$(git -C "$WT" branch --list wt-feature 2>/dev/null | tr -d ' *')
check W1a "New Worktree sheet creates a linked worktree and shows it under Repositories ▸ Worktrees" \
  'multilabels w1-sheet | grep -q "New Worktree" && multilabels w1-sheet | grep -q "Create Worktree" && after w1-sidebar "axfind wt-branch" | grep -Eq "axfind wt-branch -> [1-9]"' \
  "— shots/w1-sheet-light.png, shots/w1-sheet-dark.png, shots/w1-sidebar-light.png, shots/w1-sidebar-dark.png"
check W1b "Creating a worktree with Open in New Window opens the linked worktree window alongside the primary window" \
  'sed -n "/mark w1-created/,/mark w1-sidebar/p" "$LOG" | grep -q "window wt-base" && sed -n "/mark w1-created/,/mark w1-sidebar/p" "$LOG" | grep -q "window wt-branch"' ""
check W2 "Switching to a branch already checked out elsewhere shows Couldn’t Switch with Open Worktree recovery" \
  'multilabels w2-conflict | grep -q "Couldn’t Switch to “wt-feature”" && multilabels w2-conflict | grep -q "Open Worktree"' \
  "— shots/w2-conflict-light.png, shots/w2-conflict-dark.png"
check W3 "Choosing Open Worktree opens the existing worktree window from the recovery alert" \
  'sed -n "/mark w2-conflict/,/mark w3-opened/p" "$LOG" | grep -q "sheetpress Open Worktree -> 1" && sed -n "/mark w3-opened/,/mark w4-confirm/p" "$LOG" | grep -q "window wt-branch"' ""
check W4 "Removing the linked worktree deletes its folder and entry while keeping the branch intact" \
  'multilabels w4-confirm | grep -q "Remove the worktree “wt-branch”?" && sed -n "/mark w4-confirm/,/mark w4-removed/p" "$LOG" | grep -q "sheetpress Remove -> 1" && [ ! -d "$WT_LINK" ] && ! echo "$WT_LIST_AFTER" | grep -q "wt-branch" && [ "$WT_HAS_FEATURE_BRANCH" = "wt-feature" ] && after w4-removed "axfind wt-branch" | grep -q "axfind wt-branch -> 0:"' \
  "— shots/w4-removed-dark.png"
! grep -q "DRIVE mark done$" "$LOG" && record W0a "The worktrees journey ran to the end" FAIL "no done mark"

printf '\n%-5s %-6s  %s\n' ID RESULT CHECK
fails=0
ran=0
while IFS=$'\t' read -r id name res_status ev; do
  ran=$((ran + 1))
  [ "$res_status" = FAIL ] && fails=$((fails + 1))
  printf '%-5s %-6s  %s\n        %s\n' "$id" "$res_status" "$name" "$ev"
done < "$RESULTS"
echo "Runtime: $(( $(date +%s) - START ))s. Artifacts: $ART"
if [ ! -s "$RESULTS" ] || [ "$ran" -eq 0 ]; then
  echo "No checks recorded in $RESULTS."
  exit 1
fi
[ $fails -eq 0 ] && echo "No failures." || echo "$fails failure(s)."
exit $([ $fails -eq 0 ] && echo 0 || echo 1)
