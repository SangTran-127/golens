#!/bin/bash
# End-to-end smoke suite for GoLens: real app, real fixtures, in-process driver, no system events.
# Usage: scripts/smoke/run.sh [path/to/GoLensApp] [--keep]
# Prefs live in the dev.golens.test.smoke domain (never the owner's GoLensApp domain).
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
export GOLENS_VM_MEMORY_MB=512
pkill -9 -f "Containers/dev.golens.test.smoke/" 2>/dev/null || true
pkill -9 -f "golens-smoke" 2>/dev/null || true
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=$REPO/.build/release/GoLensApp
KEEP=0
for a in "$@"; do case $a in --keep) KEEP=1 ;; *) BIN=$a ;; esac; done
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }

DOMAIN=dev.golens.test.smoke
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
rm -rf "$CONTAINER_DIR/Library/Preferences" 2>/dev/null || true
PORT=${SMOKE_PORT:-47123}
PORT2=$((PORT + 1))
if [ "${GOLENS_EXECUTION_MODE:-host}" = "vm" ]; then
  mkdir -p "$CONTAINER_DIR/tmp"
  WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-smoke.XXXXXX")" && pwd -P)
  ART=${SMOKE_ARTIFACTS:-$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-smoke-artifacts.XXXXXX")" && pwd -P)}
else
  WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/golens-smoke.XXXXXX")" && pwd -P)
  ART=${SMOKE_ARTIFACTS:-$(cd "$(mktemp -d "${TMPDIR:-/tmp}/golens-smoke-artifacts.XXXXXX")" && pwd -P)}
fi
mkdir -p "$ART/shots" "$ART/logs"
RESULTS=$ART/results.tsv
: > "$RESULTS"
START=$(date +%s)
APP_PID=
OWNED_PIDS=

for p in $PORT $PORT2; do
  lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1 && { echo "port $p is busy; set SMOKE_PORT"; exit 2; }
done

descendants() { local k; for k in $(pgrep -P "$1" 2>/dev/null); do echo "$k"; descendants "$k"; done; }

cleanup() {
  [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null && kill -TERM "$APP_PID" 2>/dev/null
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  sleep 1
  for k in $OWNED_PIDS $APP_PID; do kill -KILL "$k" 2>/dev/null; done
  # Both ports were free at start, so any listener left on them is ours.
  for p in $PORT $PORT2; do for k in $(lsof -ti tcp:$p -sTCP:LISTEN 2>/dev/null); do kill -TERM "$k" 2>/dev/null; done; done
  defaults delete $DOMAIN >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  [ -n "${ERRPROJ:-}" ] && [ -d "$ERRPROJ/ro" ] && chmod 755 "$ERRPROJ/ro" 2>/dev/null || true
  [ $KEEP = 1 ] && echo "kept fixtures: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# ---- build the test app and the injected libraries
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

# ---- fixtures
A=$WORK/smoke
B=$WORK/other
mkdir -p "$A/cmd/server" "$A/broken" "$A/typed" "$A/empty" "$B"
printf 'module example.com/smoke\n\ngo 1.22\n' > "$A/go.mod"
cat > "$A/main.go" <<EOF
package main

import (
	"fmt"
	"net"
	"os"
)

func main() {
	s := NewStore()
	s.Apply("set", "k", "v")
	fmt.Println("value:", s.Get("k"))
	ln, err := net.Listen("tcp", "127.0.0.1:$PORT")
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	fmt.Println("listening")
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		c.Close()
	}
}

func use(v string) string {
	// smoke:typing-here
	return v
}
EOF
cat > "$A/store.go" <<'EOF'
package main

// Store keeps values by key.
type Store struct {
	data map[string]string
}

// NewStore returns an empty store.
func NewStore() *Store {
	return &Store{data: map[string]string{}}
}

// Apply runs one operation.
func (s *Store) Apply(op, k, v string) {
	if op == "set" {
		s.data[k] = v
	}
}

// Get returns the value for k.
func (s *Store) Get(k string) string {
	return s.data[k]
}
EOF
cat > "$A/store_test.go" <<'EOF'
package main

import "testing"

func TestStore(t *testing.T) {
	t.Run("set_and_get", func(t *testing.T) {
		s := NewStore()
		s.Apply("set", "a", "1")
		if s.Get("a") != "1" {
			t.Fatal("want 1")
		}
	})
	t.Run("broken_expectation", func(t *testing.T) {
		if NewStore().Get("a") != "x" {
			t.Fatal("deliberate failure")
		}
	})
}
EOF
cat > "$A/cmd/server/server.go" <<EOF
package main

import (
	"fmt"
	"net"
)

func main() {
	ln, err := net.Listen("tcp", "127.0.0.1:$PORT2")
	if err != nil {
		fmt.Println(err)
		return
	}
	fmt.Println("server listening")
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		c.Close()
	}
}
EOF
printf 'package broken\n\nfunc f() {\n\tg(.x)\n}\n' > "$A/broken/broken.go"
printf 'package typed\n\n// Value refers to a name that does not exist.\nvar Value = missingThing\n' > "$A/typed/typed.go"
printf 'module example.com/other\n\ngo 1.22\n' > "$B/go.mod"
printf 'package main\n\nfunc main() {}\n' > "$B/bonly.go"
(cd "$A" && git init -q && git add -A && git -c user.email=smoke@golens -c user.name=smoke commit -qm fixture && printf '\n// modified for the git badge\n' >> cmd/server/server.go)
cp "$A/main.go" "$WORK/main.go.orig"
cp "$A/store.go" "$WORK/store.go.orig"

# ---- helpers
record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }   # id name PASS|FAIL evidence
check() { if eval "$3"; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "$4"; fi; }

launch() { # name workspace file steps
  LOG=$ART/logs/$1.log
  DRIVE="$4" DRIVE_OUT=$LOG DRIVE_SHOTS=$ART/shots DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
    "$APP" -GoLensLastWorkspacePath "$2" -GoLensLastFilePath "$3" -GoLensShowConsole '<true/>' ${LAUNCH_EXTRA_ARGS:-} > "$ART/logs/$1.app.log" 2>&1 &
  APP_PID=$!
}

wait_mark() { # mark timeoutSeconds
  local i=0
  while [ $i -lt $(($2 * 5)) ]; do
    grep -q "DRIVE mark $1\$" "$LOG" 2>/dev/null && return 0
    kill -0 "$APP_PID" 2>/dev/null || return 1
    OWNED_PIDS="$OWNED_PIDS $(descendants "$APP_PID" | tr '\n' ' ')"
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

finish() { # timeoutSeconds: wait for the driver's quit, then make sure nothing is left
  local i=0
  OWNED_PIDS="$OWNED_PIDS $(descendants "$APP_PID" | tr '\n' ' ')"
  while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt $(($1 * 5)) ]; do sleep 0.2; i=$((i + 1)); done
  if kill -0 "$APP_PID" 2>/dev/null; then echo "  (app did not quit; killing)" >&2; kill -TERM "$APP_PID"; sleep 1; kill -KILL "$APP_PID" 2>/dev/null; fi
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  APP_PID=
}

line() { grep -m1 "$1" "$LOG" 2>/dev/null; }          # first driver line matching
lines() { grep "$1" "$LOG" 2>/dev/null; }
listening() { lsof -nP -iTCP:$1 -sTCP:LISTEN >/dev/null 2>&1; }
wait_listen() { local i=0; while [ $i -lt $(($2 * 5)) ]; do listening "$1" && return 0; sleep 0.2; i=$((i + 1)); done; return 1; }
wait_free() { local i=0; while [ $i -lt $(($2 * 10)) ]; do listening "$1" || return 0; sleep 0.1; i=$((i + 1)); done; return 1; }
shell_cwd() { # cwd of the app's zsh child (the terminal), resolved
  local k
  for k in $(pgrep -P "$APP_PID"); do
    case $(ps -o comm= -p "$k") in *zsh*) lsof -a -p "$k" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1; return ;; esac
  done
}
real() { (cd "$1" 2>/dev/null && pwd -P); }

echo "GoLens smoke suite — $(basename "$BIN") — artifacts: $ART"

# ---- L1: navigator, rename, hover, issues
launch nav "$A" "$A/main.go" "wait:10;fakeactive;mark:ready;\
axexists:cmd;axexists:broken;axexists:empty;axexists:store.go;\
rowexpand:broken;wait:1;axexists:broken.go;\
axpress:main.go;wait:1;axpress:store.go;wait:1.5;outlinesel:store.go;shot:j1-navigator;\
axpress:main.go;wait:4;hover:NewStore();wait:3;hover:NewStore();wait:3;mark:j3-symbol;wininfo;shot:j3-hover-symbol;\
rowexpand:typed;wait:1;axpress:typed.go;wait:7;hover:missingThing;wait:3;hover:missingThing;wait:3;mark:j3-error;wininfo;underline:missingThing;shot:j3-hover-error;\
deeplabels;\
axpress:main.go;wait:2;select:NewSto;mark:j4-pre;line;postkey:120;wait:3;mark:j4-open;wininfo;focus;line;shot:j4-rename;postkey:53;wait:1;mark:j4-esc;wininfo;line;mark:done;quit"
wait_mark done 90; finish 15
check J1a "Navigator lists top-level items" '[ "$(lines "axexists \(cmd\|broken\|empty\|store.go\) -> 1" | wc -l)" -eq 4 ]' "$(lines 'axexists' | head -4 | tr '\n' ' ')"
check J1b "Expanded folder shows its children" 'line "axexists broken.go -> 1" >/dev/null' "$(line 'axexists broken.go')"
SEL=$(line outlinesel)
ROW=$(echo "$SEL" | sed -n 's/.*store.go=\(row[0-9]*\).*/\1/p')
check J1c "Selecting two rows leaves only the last selected" '[ -n "$ROW" ] && echo "$SEL" | grep -Eq "selected=\[($ROW|store\.go)\] drawnSelected=\[($ROW|store\.go)\]"' "$SEL — shots/j1-navigator.png"
REN=$(sed -n '/mark j4-open/,/mark j4-esc/p' "$LOG" | grep "InlineRenameHintView" | head -1 | cut -c1-200)
RSEL=$(sed -n '/mark j4-open/,$p' "$LOG" | grep -m1 "line:" | grep -o "sel=.*")
RFOCUS=$(sed -n '/mark j4-open/,$p' "$LOG" | grep -m1 "firstResponder=" | cut -c1-120)
check J4a "F2 renames in place: NewStore is selected and the hint shows while the editor keeps the keyboard" '[ -n "$REN" ] && echo "$RFOCUS" | grep -q "GoLensTextView" && echo "$RSEL" | grep -q ", 8}"' "${REN:-no hint} $RFOCUS $RSEL — shots/j4-rename.png"
AFTER=$(sed -n '/mark j4-esc/,/wininfo end/p' "$LOG" | grep -c "InlineRenameHintView")
PSEL=$(sed -n '/mark j4-pre/,$p' "$LOG" | grep -m1 "line:" | grep -o "sel=.*")
ESEL=$(sed -n '/mark j4-esc/,$p' "$LOG" | grep -m1 "line:" | grep -o "sel=.*")
check J4b "Esc ends renaming and restores the selection" '[ "$AFTER" -eq 0 ] && [ -n "$PSEL" ] && [ "$PSEL" = "$ESEL" ]' "hints after Esc: $AFTER, selection $PSEL -> $ESEL"
HS=$(sed -n '/mark j3-symbol/,/wininfo end/p' "$LOG" | grep "HoverPopoverView" | head -1 | cut -c1-220)
check J3a "Hovering a symbol shows the hover panel" 'echo "$HS" | grep -q "NewStore"' "${HS:-no popup panel} — shots/j3-hover-symbol.png"
HE=$(sed -n '/mark j3-error/,/wininfo end/p' "$LOG" | grep "HoverPopoverView" | head -1 | cut -c1-220)
check J3b "Hovering an error shows its message" 'echo "$HE" | grep -q "missingThing"' "${HE:-no popup panel} — shots/j3-hover-error.png"
UL=$(line "underline missingThing")
check J11a "Error range is underlined (attribute + red pixels)" 'echo "$UL" | grep -q "attr=1" && [ "$(echo "$UL" | sed -n "s/.*redPixels=\([0-9]*\).*/\1/p")" -gt 0 ]' "$UL"
ISS=$(line "deeplabels:")
check J11b "The toolbar issues badge counts the errors" 'echo "$ISS" | grep -q "[1-9][0-9]* errors"' "$(echo "$ISS" | grep -o '[0-9]* errors, [0-9]* warnings' | head -1)"

# ---- L2: completion, close-tab review, external change
launch edit "$A" "$A/main.go" "wait:10;fakeactive;mark:ready;\
click:// smoke:typing-here;key:insertNewline:;type:fmt.Pri;wait:2;panel;postkey:53;wait:0.8;mark:j5-esc;panel;\
key:insertNewline:;type:x := v;wait:2;key:insertNewline:;type:_ = x;wait:0.5;mark:j5-line;line;\
edited;labels;shot:j6-edited;postkey:13,w,1048576;wait:2;mark:j6-sheet;wininfo;shot:j6-save-sheet;button:Don’t Save;wait:1.5;\
axpress:store.go;wait:2;mark:j7-ready;waitfile:$WORK/j7-go;wait:3;find:external-change-marker;shot:j7-reload;mark:done;quit"
if wait_mark j7-ready 90; then printf '\n// external-change-marker\n' >> "$A/store.go"; fi
touch "$WORK/j7-go"
wait_mark done 40; finish 15
P1=$(sed -n '1,/mark j5-esc/p' "$LOG" | grep -m1 "DRIVE panel")
check J5a "Typing fmt.Pri shows the completion popup" 'echo "$P1" | grep -q "panel visible"' "$(echo "$P1" | cut -c1-160)"
P2=$(sed -n '/mark j5-esc/,$p' "$LOG" | grep -m1 "DRIVE panel")
check J5b "Esc closes the completion popup" 'echo "$P2" | grep -q "panel hidden"' "$(echo "$P2" | cut -c1-80)"
LN=$(sed -n '/mark j5-line/,$p' "$LOG" | grep -m1 "DRIVE line:")
check J5c "Return after a 1-letter local inserts a newline" 'echo "$LN" | grep -q "x := v⏎.*_ = x"' "$LN"
check J6a "Edited tab shows the edited state" 'line "edited 1" >/dev/null && lines "labels(" | grep -q "\[Edited\]"' "$(line 'DRIVE edited') / $(lines 'labels(' | grep -o '[^|]*\[Edited\]' | head -1)"
SH=$(sed -n '/mark j6-sheet/,/wininfo end/p' "$LOG" | grep -m1 "sheet=1.*Don’t Save" | cut -c1-160)
check J6b "Close Tab on an edited file asks to save" '[ -n "$SH" ]' "${SH:-no save sheet} — shots/j6-save-sheet.png"
check J6c "Don't Save leaves the file on disk unchanged" 'line "button Don’t Save -> 1" >/dev/null && cmp -s "$A/main.go" "$WORK/main.go.orig"' "$(line 'button Don')"
check J7 "Unedited open file reloads after an external change" 'line "find .external-change-marker. -> present" >/dev/null' "$(line 'find .external-change-marker') — shots/j7-reload.png"
cp "$WORK/store.go.orig" "$A/store.go"

# ---- L3: run/stop, run from a subpackage, test, debug
launch run "$A" "$A/main.go" "wait:10;fakeactive;mark:ready;\
menu:Product/Run;mark:j8-run;waitfile:$WORK/j8-stop;menu:Product/Stop;mark:j8-stopped;wait:2.5;\
rowexpand:cmd;wait:1;rowexpand:server;wait:1;axpress:server.go;wait:2;menu:Product/Run;mark:j8b-run;waitfile:$WORK/j8b-stop;menu:Product/Stop;mark:j8b-stopped;wait:2.5;\
axpress:Test;wait:2;menu:Product/Test;wait:20;mark:j9;deeplabels;mark:j9-read;shot:j9-tests;axpress:Files;wait:1;\
axpress:store.go;wait:2;bpclick:return &Store;wait:0.5;menu:Product/Debug;wait:25;mark:j10;deeplabels;shot:j10-debug;menu:Product/Stop;wait:2;mark:done;quit"
RUN_OK=1; STOP_OK=1
if wait_mark j8-run 60; then wait_listen $PORT 45 || RUN_OK=0; else RUN_OK=0; fi
touch "$WORK/j8-stop"
if wait_mark j8-stopped 20; then wait_free $PORT 2 || STOP_OK=0; else STOP_OK=0; fi
check J8a "Run starts the program (port $PORT listening)" '[ $RUN_OK = 1 ]' "lsof :$PORT listening=$RUN_OK"
check J8b "Stop frees the port within 2 s" '[ $RUN_OK = 1 ] && [ $STOP_OK = 1 ]' "port free after Stop=$STOP_OK"
SUB_OK=1
if wait_mark j8b-run 30; then wait_listen $PORT2 45 || SUB_OK=0; else SUB_OK=0; fi
ROOT_INSTEAD=$(listening $PORT && echo yes || echo no)
touch "$WORK/j8b-stop"
wait_mark j8b-stopped 20
check J8c "Run from cmd/server/server.go runs that package (port $PORT2)" '[ $SUB_OK = 1 ]' "port $PORT2 listening=$SUB_OK; root package ran instead=$ROOT_INSTEAD"
wait_mark j9-read 60
TS=$(sed -n '/mark j9/,$p' "$LOG" | grep -m1 "deeplabels:" | grep -o 'Tests [a-z]*: [^|]*' | head -1)
check J9 "Test summary counts leaf tests (1 passed, 1 failed)" 'echo "$TS" | grep -q "1 passed, 1 failed"' "${TS:-no summary} — shots/j9-tests.png"
wait_mark done 60; finish 15
DB=$(sed -n '/mark j10/,$p' "$LOG" | grep -m1 "deeplabels:")
check J10 "Debug a 2-file package stops at the breakpoint" 'echo "$DB" | grep -q "Goroutine.*main.NewStore"' "$(echo "$DB" | grep -o 'Goroutine[^|]*' | head -1 | cut -c1-80)$(grep -m1 -o 'Build Error[^"]*' "$ART/logs/run.app.log" | cut -c1-80) — shots/j10-debug.png"

# ---- L4: Open Project opens the project in a new window (DESIGN_SYSTEM.md 3.1): its terminal and tree are the new project's, the original window is unchanged
launch switch "$A" "$A/main.go" "wait:10;fakeactive;axpress:Terminal;wait:5;mark:term-a;waitfile:$WORK/j2-a;\
stubpanel:$B;menu:File/Open Project…;wait:6;windows;winkey:other;winpress:other|Terminal;wait:5;mark:term-b;waitfile:$WORK/j2-b;\
winexists:other|bonly.go;winexists:other|store.go;winexists:smoke|store.go;winexists:smoke|bonly.go;winshot:other|j2-new-window;winshot:smoke|j2-original-window;mark:done;quit"
CWD_A=; CWD_B=; CWD_A_AFTER=; SHELL_A=
shell_pids() { local k; for k in $(pgrep -P "$APP_PID"); do case $(ps -o comm= -p "$k") in *zsh*) echo "$k" ;; esac; done; }
pid_cwd() { lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1; }
wait_mark term-a 60 && { SHELL_A=$(shell_pids | head -1); CWD_A=$(shell_cwd); }; touch "$WORK/j2-a"
if wait_mark term-b 60; then
  sleep 1
  for k in $(shell_pids); do [ "$k" = "$SHELL_A" ] && CWD_A_AFTER=$(pid_cwd "$k") || CWD_B=$(pid_cwd "$k"); done
fi
touch "$WORK/j2-b"
wait_mark done 30; finish 15
check J2a "Terminal starts in the project folder" '[ -n "$CWD_A" ] && [ "$(real "$CWD_A")" = "$(real "$A")" ]' "shell cwd=${CWD_A:-none}"
check J2b "Open Project opens a new window whose terminal starts in the new project, and the original terminal stays in its project" '[ -n "$CWD_B" ] && [ "$(real "$CWD_B")" = "$(real "$B")" ] && [ "$(real "${CWD_A_AFTER:-/nonexistent}")" = "$(real "$A")" ]' "new window shell cwd=${CWD_B:-none}; original shell cwd=${CWD_A_AFTER:-none}"
check J2c "The new window's tree shows the new project and the original window's tree is unchanged" 'line "winexists other|bonly.go -> 1" >/dev/null && line "winexists other|store.go -> 0" >/dev/null && line "winexists smoke|store.go -> 1" >/dev/null && line "winexists smoke|bonly.go -> 0" >/dev/null' "$(lines 'winexists' | sed 's/^DRIVE //' | tr '\n' ' ') — shots/j2-new-window.png, shots/j2-original-window.png"

# ---- L5: a pull that conflicts (main.go conflicted, helper.go merged and staged), then Abort Merge
GR=$WORK/merge-remote.git; GM=$WORK/merge; GO=$WORK/merge-other
gitq() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=Smoke -c user.email=smoke@example.com -c init.defaultBranch=main -c pull.rebase=false "$@" >/dev/null 2>&1; }
gitq init --bare "$GR"
gitq clone "$GR" "$GM"
printf 'module example.com/merge\n\ngo 1.22\n' > "$GM/go.mod"
printf 'package main\n\nfunc message() string { return "base" }\n\nfunc main() { println(message(), helper()) }\n' > "$GM/main.go"
printf 'package main\n\nfunc helper() int { return 1 }\n' > "$GM/helper.go"
gitq -C "$GM" add -A; gitq -C "$GM" commit -m base; gitq -C "$GM" push origin HEAD:main
gitq clone "$GR" "$GO"
sed -i '' 's/"base"/"remote"/' "$GO/main.go"; sed -i '' 's/return 1/return 2/' "$GO/helper.go"
gitq -C "$GO" commit -am remote; gitq -C "$GO" push origin HEAD:main
sed -i '' 's/"base"/"local"/' "$GM/main.go"
gitq -C "$GM" commit -am local; LOCAL_HEAD=$(git -C "$GM" rev-parse HEAD)
gitq -C "$GM" pull --no-edit origin main
PRE=$(git -C "$GM" status --porcelain | tr '\n' ' ')
launch merge "$GM" "$GM/main.go" "wait:10;fakeactive;mark:ready;axpress:Source Control;wait:2;mark:j12-conflict;deeplabels;\
axpress:Uncommitted Changes;wait:2.5;focusclass:CommitComposer;fr:Merge remote changes;wait:0.6;mark:j12-editor;deeplabels;axstate:Commit;menustate:Source Control/Commit Changes;shot:j12-conflict-light;darkmode;wait:0.6;shot:j12-conflict-dark;\
axpress:Close Commit Editor;wait:2.5;axpress:Abort Merge…;wait:1;button:Abort Merge;wait:3;mark:j12-aborted;deeplabels;shot:j12-aborted;mark:done;quit"
wait_mark done 60; finish 15
CONFLICT_UI=$(sed -n '/mark j12-conflict/,/focusclass/p' "$LOG" | grep -m1 "deeplabels:")
ABORTED_UI=$(sed -n '/mark j12-aborted/,$p' "$LOG" | grep -m1 "deeplabels:")
POST=$(git -C "$GM" status --porcelain | tr '\n' ' ')
check J12a "A conflicted pull shows Merge in Progress with Abort Merge and lists the file under Merge Conflicts" \
  'echo "$PRE" | grep -q "UU main.go" && echo "$CONFLICT_UI" | grep -q "Merge in Progress" && echo "$CONFLICT_UI" | grep -q "Abort Merge…" && echo "$CONFLICT_UI" | grep -q "Merge Conflicts, 1 files"' \
  "git before: $PRE — shots/j12-conflict-dark.png, shots/j12-conflict-light.png"
check J12b "In the commit editor, Commit stays disabled while a conflict remains, even with a staged file and a message" \
  'line "focusclass CommitComposer -> 1" >/dev/null && line "axstate Commit -> 0" >/dev/null && line "menustate Source Control/Commit Changes enabled=0" >/dev/null && sed -n "/mark j12-editor/,/axstate/p" "$LOG" | grep -m1 "deeplabels:" | grep -q "Resolve 1 merge conflict before committing"' "$(line 'axstate Commit') $(line 'menustate Source Control/Commit Changes')"
check J12c "Abort Merge restores the branch: no MERGE_HEAD, clean tree, HEAD back on the local commit" \
  '[ ! -e "$GM/.git/MERGE_HEAD" ] && [ -z "$POST" ] && [ "$(git -C "$GM" rev-parse HEAD)" = "$LOCAL_HEAD" ] && ! echo "$ABORTED_UI" | grep -q "Merge in Progress"' \
  "git after: ${POST:-clean} — shots/j12-aborted.png"

# ---- L6: Dockerfile completion, Go-aware findings, engine state, compose validation
D=$WORK/dock
mkdir -p "$D"
printf 'module example.com/dock\n\ngo 1.23\n' > "$D/go.mod"
printf 'package main\n\nfunc main() {}\n' > "$D/main.go"
cat > "$D/Dockerfile" <<'EOF'
FROM golang:1.21 AS builder
WORKDIR /src
COPY . .
RUN go mod download
RUN go build -o /out/app ./cmd/api
FROM scratch
COPY --from=builder /out/app /app
ENTRYPOINT ["/app"]
# smoke:dockerfile-end
EOF
cat > "$D/compose.yaml" <<'EOF'
services:
  web:
    image: nginx:1.27
    ports:
      - "8080:80"
     environment:
      - A=1
EOF
ENGINE_UP=0; docker version --format '{{.Server.Version}}' >/dev/null 2>&1 && ENGINE_UP=1
launch dock "$D" "$D/Dockerfile" "wait:10;fakeactive;mark:ready;wait:4;mark:j13-open;deeplabels;underline:1.21;shot:j13-dockerfile;\
click:# smoke:dockerfile-end;key:insertNewline:;type:FR;wait:1;mark:j13-fr;panel;postkey:48;wait:0.6;postkey:53;wait:0.4;line;\
key:insertNewline:;type:COP;wait:1;panel;postkey:48;wait:0.6;postkey:53;wait:0.3;type:--from=;wait:1;mark:j13-from;panel;postkey:48;wait:0.5;line;postkey:53;wait:0.4;mark:j13-esc;panel;save;wait:1;\
menu:View/Show Services;wait:6;mark:j13-engine;deeplabels;shot:j13-engine;\
axpress:compose.yaml;wait:2;menu:Tools/Containers & Compose/Validate Compose File;wait:8;mark:j13-compose;line;deeplabels;shot:j13-compose;mark:done;quit"
wait_mark done 120; finish 15
DF_OPEN=$(sed -n '/mark j13-open/,/underline/p' "$LOG" | grep -m1 "deeplabels:")
DF_UL=$(line "underline 1.21")
check J13a "Dockerfile findings: the golang:1.21 version older than go.mod is underlined as an error" \
  'echo "$DF_UL" | grep -q "attr=1" && [ "$(echo "$DF_UL" | sed -n "s/.*redPixels=\([0-9]*\).*/\1/p")" -gt 0 ] && echo "$DF_OPEN" | grep -q "[1-9][0-9]* error"' \
  "$DF_UL — $(echo "$DF_OPEN" | grep -o '[0-9]* errors\?, [0-9]* warnings\?' | head -1) — shots/j13-dockerfile.png"
DF_FR=$(sed -n '/mark j13-fr/,/mark j13-from/p' "$LOG")
check J13b "Typing FR suggests FROM and Tab inserts it" \
  'echo "$DF_FR" | grep -m1 "DRIVE panel" | grep -q "panel visible.*FROM" && echo "$DF_FR" | grep -q "DRIVE line:.*FROM "' "$(echo "$DF_FR" | grep -m1 'DRIVE panel' | cut -c1-140)"
DF_FROM=$(sed -n '/mark j13-from/,/mark j13-esc/p' "$LOG")
check J13c "COPY --from= lists the declared stage and Tab inserts it" \
  'echo "$DF_FROM" | grep -m1 "DRIVE panel" | grep -q "panel visible.*builder" && echo "$DF_FROM" | grep -q "DRIVE line:.*COPY --from=builder"' "$(echo "$DF_FROM" | grep 'DRIVE line:' | cut -c1-140)"
check J13d "Esc closes the Dockerfile completion list" \
  'sed -n "/mark j13-esc/,\$p" "$LOG" | grep -m1 "DRIVE panel" | grep -q "panel hidden"' "$(sed -n '/mark j13-esc/,$p' "$LOG" | grep -m1 'DRIVE panel' | cut -c1-60)"
DF_ENGINE=$(sed -n '/mark j13-engine/,/shot/p' "$LOG" | grep -m1 "deeplabels:")
if [ $ENGINE_UP = 1 ]; then
  check J13e "Engine running: status shows the Docker context and no engine banner" \
    'echo "$DF_ENGINE" | grep -q "Docker: " && ! echo "$DF_ENGINE" | grep -q "Isn’t Running"' "$(echo "$DF_ENGINE" | grep -o 'Docker: [^|]*' | head -1) — shots/j13-engine.png"
else
  check J13e "Engine stopped: banner names the cause and offers Retry" \
    'echo "$DF_ENGINE" | grep -q "Docker Engine Isn’t Running" && echo "$DF_ENGINE" | grep -q "Retry" && echo "$DF_ENGINE" | grep -q "Docker: "' "$(echo "$DF_ENGINE" | grep -o 'Docker Engine Isn’t Running[^|]*\|Docker: [^|]*\|Open [A-Za-z ]*' | head -3 | tr '\n' ' ') — shots/j13-engine.png"
fi
DF_COMPOSE=$(sed -n '/mark j13-compose/,$p' "$LOG")
check J13f "Validate Compose File reports the broken key and jumps to its line" \
  'echo "$DF_COMPOSE" | grep -m1 "DRIVE line:" | grep -q "environment\|ports" && echo "$DF_COMPOSE" | grep -m1 "deeplabels:" | grep -q "[1-9][0-9]* error"' \
  "$(echo "$DF_COMPOSE" | grep -m1 'DRIVE line:' | cut -c1-120) — shots/j13-compose.png"

# ---- L7: stage and unstage one hunk of a file with two changes, from the diff view
SG=$WORK/stage
gitq init "$SG"
printf 'module example.com/stage\n\ngo 1.22\n' > "$SG/go.mod"
{ printf 'package main\n\nconst first = 1\n'; for i in $(seq 1 12); do printf 'const pad%d = %d\n' "$i" "$i"; done; printf 'const last = 2\n\nfunc main() {}\n'; } > "$SG/main.go"
gitq -C "$SG" add -A; gitq -C "$SG" commit -m base
sed -i '' 's/const first = 1/const first = 10/; s/const last = 2/const last = 20/' "$SG/main.go"
launch stage "$SG" "$SG/main.go" "wait:10;fakeactive;mark:ready;axpress:Source Control;wait:2;axpress:main.go;wait:2;mark:j14-diff;deeplabels;shot:j14-diff-dark;lightmode;wait:0.6;shot:j14-diff-light;\
axpress:Stage Hunk;wait:2;mark:j14-staged;waitfile:$WORK/j14-a;deeplabels;\
axpress:Staged;wait:1.5;axpress:Unstage Hunk;wait:2;mark:j14-unstaged;waitfile:$WORK/j14-b;mark:done;quit"
STAGED_ONE=; STAGED_NONE=
if wait_mark j14-staged 60; then STAGED_ONE=$(git -C "$SG" diff --cached | grep '^[-+]const' | tr '\n' ' '); fi; touch "$WORK/j14-a"
if wait_mark j14-unstaged 30; then STAGED_NONE=$(git -C "$SG" diff --cached --name-only | wc -l | tr -d ' '); fi; touch "$WORK/j14-b"
wait_mark done 30; finish 15
J14_STAGED_UI=$(sed -n '/mark j14-staged/,/axpress Staged/p' "$LOG" | grep -m1 "deeplabels:")
check J14a "Stage Hunk stages only the first change; the file shows under Staged Changes and Changes" \
  'echo "$STAGED_ONE" | grep -q "+const first = 10" && ! echo "$STAGED_ONE" | grep -q "last" && echo "$J14_STAGED_UI" | grep -q "Staged Changes"' \
  "index: ${STAGED_ONE:-empty} — shots/j14-diff-light.png, shots/j14-diff-dark.png"
check J14b "Unstage Hunk on the Staged side empties the index again" '[ "$STAGED_NONE" = 0 ]' "files still staged: ${STAGED_NONE:-unknown}"

# ---- L7b: the workspace is a folder inside a larger repository; odd file names; Discard Change on the clicked hunk
SR=$WORK/sub-repo
gitq init "$SR"
mkdir -p "$SR/app" "$SR/other"
printf 'module example.com/app\n\ngo 1.22\n' > "$SR/app/go.mod"
{ printf 'package main\n\nconst a3 = 3\n'; for i in $(seq 4 39); do printf 'const pad%d = %d\n' "$i" "$i"; done; printf 'const b40 = 40\n\nfunc main() {}\n'; } > "$SR/app/main.go"
printf 'package other\n' > "$SR/other/keep.go"
gitq -C "$SR" add -A; gitq -C "$SR" commit -m base
sed -i '' 's/const a3 = 3/const a3 = 300/; s/const b40 = 40/const b40 = 400/' "$SR/app/main.go"
printf 'package main\n' > "$SR/app/é x.go"
printf 'package other\n' > "$SR/other/outside.go"
launch subrepo "$SR/app" "$SR/app/main.go" "wait:10;fakeactive;mark:ready;caret:const a3;wait:0.5;gutterctx:const b40|Discard Change;wait:1.5;mark:j19-revert;find:const b40 = 400;find:const a3 = 300;undo;wait:1;save;wait:1;caret:package main;wait:0.5;mark:j19-caret;menustate:Editor/Discard Change at Cursor;\
axpress:Source Control;wait:2;mark:j19-list;deeplabels;shot:j19-list;axpress:Stage All;wait:2;mark:j19-staged;waitfile:$WORK/j19-a;wait:3;mark:j19-staged-ui;deeplabels;shot:j19-staged;mark:done;quit"
J19_STAGED=
if wait_mark j19-staged 60; then J19_STAGED=$(git -C "$SR" -c core.quotePath=false diff --cached --name-only | tr '\n' ' '); fi; touch "$WORK/j19-a"
wait_mark done 30; finish 15
J19_LIST=$(sed -n '/mark j19-list/,/shot j19-list/p' "$LOG" | grep -m1 "deeplabels:")
J19_REVERT=$(sed -n '/mark j19-revert/,/mark j19-list/p' "$LOG")
J19_STAGED_UI=$(sed -n '/mark j19-staged-ui/,$p' "$LOG" | grep -m1 "deeplabels:")
check J19a "A workspace inside a repository lists its own changes, including a file named “é x.go”, and nothing outside it" \
  'echo "$J19_LIST" | grep -q "é x.go" && ! echo "$J19_LIST" | grep -q "outside.go"' "$(echo "$J19_LIST" | grep -o '[^|]*é x.go[^|]*' | head -1) — shots/j19-list.png"
check J19b "Stage All stages the workspace's files and leaves the file outside the workspace unstaged" \
  'echo "$J19_STAGED" | grep -q "app/é x.go" && echo "$J19_STAGED" | grep -q "app/main.go" && ! echo "$J19_STAGED" | grep -q "other/outside.go" && echo "$J19_STAGED_UI" | grep -q "Staged Changes, 2"' \
  "index: ${J19_STAGED:-empty}; list: $(echo "$J19_STAGED_UI" | grep -o 'Staged Changes, [0-9]*') — shots/j19-staged.png"
check J19c "Discard on the gutter of the second change reverts that change, not the one at the caret; with no change at the caret the command is unavailable" \
  'echo "$J19_REVERT" | grep -q "find .const b40 = 400. -> absent" && echo "$J19_REVERT" | grep -q "find .const a3 = 300. -> present" && line "menustate Editor/Discard Change at Cursor enabled=0" >/dev/null' \
  "$(echo "$J19_REVERT" | grep -E 'gutterctx|find' | tr '\n' ' ' | cut -c1-200) $(line "menustate Editor/Discard" | cut -c1-80)"

# ---- L7c: Source Control menu and shortcuts, Jump to Next Change, change bar popover, Stage Selected Files, Pull sheet
SCR=$WORK/scm-remote.git; SC=$WORK/scm
gitq init --bare "$SCR"
gitq clone "$SCR" "$SC"
printf 'module example.com/scm\n\ngo 1.22\n' > "$SC/go.mod"
{ printf 'package main\n\nconst a3 = 3\n'; for i in $(seq 4 29); do printf 'const pad%d = %d\n' "$i" "$i"; done; printf 'const b30 = 30\n\nfunc main() {}\n'; } > "$SC/main.go"
gitq -C "$SC" add -A; gitq -C "$SC" commit -m base; gitq -C "$SC" push -u origin HEAD:main
gitq -C "$SC" checkout -b feat2 --track origin/main; printf '# notes\n' > "$SC/NOTES.md"; gitq -C "$SC" add NOTES.md; gitq -C "$SC" commit -m "ahead of main"
sed -i '' 's/const a3 = 3$/const a3 = 300/; s/const b30 = 30$/const b30 = 3000/' "$SC/main.go"
printf 'package main\n' > "$SC/é x.go"
launch scm "$SC" "$SC/main.go" "wait:10;fakeactive;mark:ready;\
menu:Source Control/Commit…;wait:1.5;mark:j20-commit;focus;axpress:Close Commit Editor;wait:2.5;\
menustate:Source Control/Commit…;menustate:Source Control/Pull…;menustate:Navigate/Jump to Next Change;menustate:View/Show Code Review;\
caret:package main;wait:0.5;menu:Navigate/Jump to Next Change;wait:0.8;mark:j20-next1;line;menu:Navigate/Jump to Next Change;wait:0.8;mark:j20-next2;line;\
changebar:const b30;wait:1.5;mark:j20-popover;popoverlabels;shot:j20-popover-dark;axpress:Stage Change;wait:2.5;mark:j20-staged;waitfile:$WORK/j20-a;\
lightmode;wait:0.6;changebar:const a3;wait:1.5;shot:j20-popover-light;postkey:53;wait:0.5;\
axpress:Source Control;wait:1.5;axpress:é x.go;wait:1.5;menu:Source Control/Stage Selected Files;wait:2.5;mark:j20-selected;waitfile:$WORK/j20-b;\
menu:Source Control/Pull…;wait:10;mark:j20-pull;deeplabels;shot:j20-pull-light;darkmode;wait:0.6;shot:j20-pull-dark;axpress:Cancel;wait:1;\
menu:Source Control/Push…;wait:5;mark:j20-push;deeplabels;postkey:36;wait:5;mark:j20-pushed;axclick:scm;wait:1.5;mark:j20-branches;popoverlabels;shot:j20-branches-dark;lightmode;wait:0.6;shot:j20-branches-light;postkey:53;wait:0.5;mark:done;quit"
J20_STAGED=; J20_SELECTED=
if wait_mark j20-staged 60; then J20_STAGED=$(git -C "$SC" diff --cached | grep '^[-+]const' | tr '\n' ' '); fi; touch "$WORK/j20-a"
if wait_mark j20-selected 30; then J20_SELECTED=$(git -C "$SC" -c core.quotePath=false diff --cached --name-only | tr '\n' ' '); fi; touch "$WORK/j20-b"
wait_mark done 40; finish 15
J20_POP=$(sed -n '/mark j20-popover/,$p' "$LOG" | grep -m1 "popoverlabels:")
J20_PULL=$(sed -n '/mark j20-pull/,$p' "$LOG" | grep -m1 "deeplabels:")
J20_PUSH=$(sed -n '/mark j20-push$/,$p' "$LOG" | grep -m1 "deeplabels:")
J20_REMOTE=$(git --git-dir="$SCR" log --format=%s main 2>/dev/null | tr '\n' ' ')
check J20f "Source Control ▸ Commit… from the Files navigator opens the commit editor and puts the caret in its message" \
  'sed -n "/mark j20-commit/,/menustate/p" "$LOG" | grep -q "firstResponder=.*CommitComposer"' "$(sed -n '/mark j20-commit/,/menustate/p' "$LOG" | grep -m1 'firstResponder' | cut -c1-80)"
check J20a "Source Control menu has Commit… ⌥⌘C and Pull… ⌥⌘X; Navigate has Jump to Next Change ⌃\; View has Show Code Review" \
  'line "menustate Source Control/Commit… enabled=1 key=c mods=1572864" >/dev/null && line "menustate Source Control/Pull… enabled=1 key=x mods=1572864" >/dev/null && line "menustate Navigate/Jump to Next Change enabled=1 key=\\\\ mods=262144" >/dev/null && line "menustate View/Show Code Review enabled=1" >/dev/null' \
  "$(lines 'menustate' | cut -c1-80 | tr '\n' ' ')"
check J20b "Jump to Next Change moves the caret to the first change, then to the next one" \
  'sed -n "/mark j20-next1/,/mark j20-next2/p" "$LOG" | grep -q "DRIVE line:.*const a3 = 300" && sed -n "/mark j20-next2/,/mark j20-popover/p" "$LOG" | grep -q "DRIVE line:.*const b30 = 3000"' \
  "$(lines 'DRIVE line:' | head -2 | cut -c1-70 | tr '\n' ' ')"
check J20c "The change bar popover offers Show Change, Stage Change and Discard Change; Stage Change stages only that change" \
  'echo "$J20_POP" | grep -q "Show Change" && echo "$J20_POP" | grep -q "Stage Change" && echo "$J20_POP" | grep -q "Discard Change" && echo "$J20_STAGED" | grep -q "+const b30 = 3000" && ! echo "$J20_STAGED" | grep -q "a3"' \
  "index: ${J20_STAGED:-empty} — shots/j20-popover-light.png, shots/j20-popover-dark.png"
check J20d "Source Control ▸ Stage Selected Files stages the selected é x.go" \
  'echo "$J20_SELECTED" | grep -q "é x.go"' "index: ${J20_SELECTED:-empty}"
check J20e "Pull… opens “Pull remote changes from:” with origin/main and the rebase option" \
  'echo "$J20_PULL" | grep -q "Pull remote changes from:" && echo "$J20_PULL" | grep -q "origin/main" && echo "$J20_PULL" | grep -q "Rebase local changes onto upstream changes"' \
  "$(echo "$J20_PULL" | grep -o 'Pull remote changes from:[^|]*|[^|]*' | head -1) — shots/j20-pull-light.png, shots/j20-pull-dark.png"
J20_BRANCHES=$(sed -n '/mark j20-branches/,$p' "$LOG" | grep -m1 "popoverlabels:")
check J20h "Clicking the project title opens the branch popover: Find, Current Branch feat2 with its author, Branches with main, New Branch…" \
  'echo "$J20_BRANCHES" | grep -q "Find" && echo "$J20_BRANCHES" | grep -q "Current Branch" && echo "$J20_BRANCHES" | grep -q "feat2" && echo "$J20_BRANCHES" | grep -q "Smoke committed" && echo "$J20_BRANCHES" | grep -q "| main" && echo "$J20_BRANCHES" | grep -q "New Branch…"' \
  "$(echo "$J20_BRANCHES" | cut -c1-160) — shots/j20-branches-light.png, shots/j20-branches-dark.png"
check J20g "Push… from feat2, which tracks origin/main, offers origin/main and pushes the local commit there" \
  'echo "$J20_PUSH" | grep -q "origin/main" && echo "$J20_REMOTE" | grep -q "ahead of main"' "remote main: ${J20_REMOTE:-unknown}"

# ---- L7d: the toolbar activity names what is actually running and never sticks after a run ends
RP=$WORK/runpill
mkdir -p "$RP/cmd/server"
printf 'module example.com/runpill\n\ngo 1.22\n' > "$RP/go.mod"
printf 'package main\n\nimport "fmt"\n\nfunc main() { fmt.Println("root ran") }\n' > "$RP/main.go"
printf 'package main\n\nimport (\n\t"fmt"\n\t"net"\n\t"net/http"\n)\n\nfunc main() {\n\tl, _ := net.Listen("tcp", "127.0.0.1:0")\n\tfmt.Println("serving on " + l.Addr().String())\n\t_ = http.Serve(l, nil)\n}\n' > "$RP/cmd/server/main.go"
launch runpill "$RP" "$RP/cmd/server/main.go" "wait:10;fakeactive;mark:ready;menu:Product/Run;wait:8;mark:j21-server;deeplabels;shot:j21-pill-running;\
menu:Product/Stop;wait:3;axpress:main.go;wait:2;menu:Product/Run;wait:8;mark:j21-finished;deeplabels;shot:j21-pill-finished;mark:done;quit"
wait_mark done 90; finish 15
J21_SERVER=$(sed -n '/mark j21-server/,/mark j21-finished/p' "$LOG" | grep -m1 "deeplabels:")
J21_DONE=$(sed -n '/mark j21-finished/,$p' "$LOG" | grep -m1 "deeplabels:")
check J21a "While a program runs the activity reads Running Default on My Mac (also to VoiceOver) and the button is Stop" \
  'echo "$J21_SERVER" | grep -q "Activity \[runpill: Running Default on My Mac\]" && echo "$J21_SERVER" | grep -q "| Stop |"' \
  "$(echo "$J21_SERVER" | grep -o 'Activity \[[^]]*\]' | head -1) — shots/j21-pill-running.png"
check J21c "After Stop and a run that exits at once the activity shows Finished, not Running, and Run and Debug sit after it on the right" \
  'echo "$J21_DONE" | grep -q "Activity \[runpill: Finished Running" && ! echo "$J21_DONE" | grep -q "Running Default on My Mac" && echo "$J21_DONE" | grep -q "Activity \[[^]]*\] |.*| Run | Debug"' \
  "$(echo "$J21_DONE" | grep -o 'Activity \[[^]]*\]' | head -1) — shots/j21-pill-finished.png"

# ---- L7e: Quick Documentation from the View menu (⌃⌘?), ⌃⇧⌘/ and F1, the context menu and the palette; its states; Esc returns to the editor
QD=$WORK/quickdoc
mkdir -p "$QD"
printf 'module example.com/quickdoc\n\ngo 1.22\n' > "$QD/go.mod"
printf 'package main\n\nimport "strings"\n\n// Shout returns s in capitals.\nfunc Shout(s string) string { return strings.ToUpper(s) }\n\nfunc whisper(s string) string { return strings.ToLower(s) }\n\nfunc main() {\n\t_ = Shout("hi")\n\n\t_ = whisper("HI")\n\t_ = missingThing\n}\n' > "$QD/main.go"
LAUNCH_EXTRA_ARGS='-GoLensAutoSaveOnFocusLoss <false/>' launch quickdoc "$QD" "$QD/main.go" "wait:12;fakeactive;mark:ready;menustate:View/Quick Documentation;caret:func main() {;typefast:\n\t// unsaved;wait:0.5;edited;\
caret:= Shout;wait:0.5;mark:j22-caret;line;menu:View/Quick Documentation;wait:3;mark:j22-open;wininfo;darkmode;wait:0.6;panelshot:j22-doc-dark;lightmode;wait:0.6;panelshot:j22-doc-light;\
wait:1;mark:j22-still;wininfo;panelkey:53;wait:1;mark:j22-esc;wininfo;line;focus;edited;undo;find:// unsaved;\
caret:= whisper;wait:0.5;postkey:44,?,1441792;wait:3;mark:j22-nodoc;wininfo;panelshot:j22-nodoc-light;darkmode;wait:0.6;panelshot:j22-nodoc-dark;\
axpress:Open Source;wait:3;mark:j22-source;wininfo;line;menu:Navigate/Back;wait:2;mark:j22-back;line;\
caret:Shout(\"hi\")\n;wait:0.5;postkey:122;wait:1.5;mark:j22-blank;wininfo;panelshot:j22-blank-dark;lightmode;wait:0.6;panelshot:j22-blank-light;key:cancelOperation:;wait:1;mark:j22-blank-esc;wininfo;\
editorctx:missingThing|Quick Documentation;wait:3;mark:j22-unresolved;wininfo;panelshot:j22-unresolved-light;darkmode;wait:0.6;panelshot:j22-unresolved-dark;axpress:Retry;wait:3;mark:j22-retry;wininfo;panelkey:53;wait:1;\
caret:= Shout;wait:0.5;menu:View/Command Palette…;wait:1;fieldp:Type a command…:Quick Documentation;wait:0.5;postkey:36;wait:3;mark:j22-palette;wininfo;panelkey:53;wait:1;\
lightmode;pausegopls;wait:0.3;caret:= Shout;menu:View/Quick Documentation;wait:0.3;mark:j22-loading;wininfo;panelshot:j22-loading-light;darkmode;wait:0.3;panelshot:j22-loading-dark;panelkey:53;wait:0.5;mark:j22-loading-esc;wininfo;resumegopls;mark:done;quit"
wait_mark done 120; finish 15
qd_win() { sed -n "/mark $1\$/,/wininfo end/p" "$LOG" | grep "PopupPanel"; }
qd_line() { sed -n "/mark $1\$/,\$p" "$LOG" | grep -m1 "DRIVE line:"; }
J22_CARET=$(qd_line j22-caret | sed -n 's/.*sel=\({[0-9]*, [0-9]*}\).*/\1/p')
J22_OPEN=$(qd_win j22-open | head -1 | cut -c1-400)
J22_STILL=$(qd_win j22-still | grep -c .)
J22_ESC=$(qd_win j22-esc | grep -c .)
J22_ESC_LINE=$(qd_line j22-esc)
J22_FOCUS=$(sed -n '/mark j22-esc$/,$p' "$LOG" | grep -m1 "firstResponder=")
J22_NODOC=$(qd_win j22-nodoc | head -1 | cut -c1-300)
J22_BLANK=$(qd_win j22-blank | head -1 | cut -c1-200)
J22_UNRES=$(qd_win j22-unresolved | head -1 | cut -c1-200)
J22_PALETTE=$(qd_win j22-palette | head -1 | cut -c1-400)
J22_LOADING=$(qd_win j22-loading | head -1 | cut -c1-200)
check J22a "View ▸ Quick Documentation is ⌃⌘? and shows the documentation of the symbol at the caret in a key panel" \
  'line "menustate View/Quick Documentation enabled=1 key=? mods=1310720" >/dev/null && echo "$J22_OPEN" | grep -q "key=1" && echo "$J22_OPEN" | grep -q "Shout returns s in capitals" && echo "$J22_OPEN" | grep -q "Open Source"' \
  "$(line 'menustate View/Quick Documentation' | cut -c1-90) ${J22_OPEN:-no popover} — shots/j22-doc-light.png, shots/j22-doc-dark.png"
check J22b "It stays open; Esc closes it and returns focus, caret, unsaved text and undo to the editor" \
  '[ "$J22_STILL" -gt 0 ] && [ "$J22_ESC" -eq 0 ] && [ -n "$J22_CARET" ] && echo "$J22_ESC_LINE" | grep -qF "sel=$J22_CARET" && echo "$J22_FOCUS" | grep -q "GoLensTextView" && [ "$(lines "DRIVE edited 1" | wc -l)" -ge 2 ] && line "find .// unsaved. -> absent" >/dev/null' \
  "still open: $J22_STILL, after Esc: $J22_ESC, caret $J22_CARET -> $(echo "$J22_ESC_LINE" | grep -o 'sel=.*'), $(echo "$J22_FOCUS" | cut -c1-60), $(line 'find .// unsaved')"
check J22c "⌃⇧⌘/ on a symbol without a doc comment shows its signature, the missing-comment note and Open Source" \
  'echo "$J22_NODOC" | grep -q "func whisper" && echo "$J22_NODOC" | grep -q "No documentation comment is available for this symbol." && echo "$J22_NODOC" | grep -q "Open Source"' \
  "${J22_NODOC:-no popover} — shots/j22-nodoc-light.png, shots/j22-nodoc-dark.png"
check J22d "Open Source goes to the declaration and Navigate ▸ Back returns to the call" \
  'qd_line j22-source | grep -q "func whisper(s string)" && qd_line j22-back | grep -q "_ = whisper(\"HI\")" && [ "$(qd_win j22-source | grep -c .)" -eq 0 ]' \
  "$(qd_line j22-source | cut -c1-90) / $(qd_line j22-back | cut -c1-90)"
check J22e "F1 on a blank line explains what to do and Esc closes it" \
  'echo "$J22_BLANK" | grep -q "Place the cursor on a Go symbol to view its documentation." && [ "$(qd_win j22-blank-esc | grep -c .)" -eq 0 ]' \
  "${J22_BLANK:-no popover} — shots/j22-blank-light.png, shots/j22-blank-dark.png"
check J22f "The editor context menu offers Quick Documentation; an unresolved symbol says so and offers Retry" \
  'line "editorctx perform Quick Documentation -> 1" >/dev/null && echo "$J22_UNRES" | grep -q "GoLens couldn’t resolve this symbol in the current project." && echo "$J22_UNRES" | grep -q "Retry" && [ "$(qd_win j22-retry | grep -c "resolve")" -gt 0 ]' \
  "${J22_UNRES:-no popover} — shots/j22-unresolved-light.png, shots/j22-unresolved-dark.png"
check J22g "The command palette looks up the symbol at the caret the editor had before the palette opened" \
  'echo "$J22_PALETTE" | grep -q "Shout returns s in capitals"' "${J22_PALETTE:-no popover}"
check J22h "While gopls is busy the panel shows Loading documentation… and Esc cancels it" \
  'echo "$J22_LOADING" | grep -q "Loading documentation…" && [ "$(qd_win j22-loading-esc | grep -c .)" -eq 0 ]' \
  "${J22_LOADING:-no popover} — shots/j22-loading-light.png, shots/j22-loading-dark.png"

# ---- L7f: Repositories tab (branches, remotes, tags, stashes) and History in the editor area
RR=$WORK/repos-remote.git; RS=$WORK/repos
gitq init --bare "$RR"
gitq clone "$RR" "$RS"
printf 'module example.com/repos\n\ngo 1.22\n' > "$RS/go.mod"
printf 'package main\n\nfunc main() {}\n' > "$RS/main.go"
gitq -C "$RS" add -A; gitq -C "$RS" commit -m "first commit"
gitq -C "$RS" tag -a v1.0 -m "release one"; gitq -C "$RS" tag light
printf '# notes\n' > "$RS/notes.md"; gitq -C "$RS" add notes.md; gitq -C "$RS" commit -m "second commit"
gitq -C "$RS" push -u origin HEAD:main
gitq -C "$RS" checkout -b feature/x; printf 'package main\n\nfunc feature() {}\n' > "$RS/feature.go"; gitq -C "$RS" add feature.go; gitq -C "$RS" commit -m "feature work"
gitq -C "$RS" push -u origin feature/x; gitq -C "$RS" checkout main
printf 'package main\n\nfunc main() { println() }\n' > "$RS/main.go"; gitq -C "$RS" stash push -m "wip stash"
launch repos "$RS" "$RS/main.go" "wait:10;fakeactive;mark:ready;axpress:Source Control;wait:1.5;axpress:Repositories;wait:2.5;mark:j23-tree;axexists:feature/x;axexists:origin;axexists:v1.0;axexists:light;axexists:wip stash;shot:j23-repositories-dark;lightmode;wait:0.6;shot:j23-repositories-light;\
axpress:Changes;wait:1;mark:j23-changes;axexists:Recent Commits (2);axpress:Show History;wait:3;mark:j23-history;axexists:second commit;axexists:first commit;deeplabels;shot:j23-history-light;\
fieldp:Filter by message, author or hash:second;wait:2.5;mark:j23-filtered;axexists:second commit;axexists:first commit;\
rowclick:second commit;wait:2.5;mark:j23-detail;deeplabels;shot:j23-detail-light;darkmode;wait:0.6;shot:j23-detail-dark;mark:done;quit"
wait_mark done 90; finish 15
J23_TREE=$(sed -n '/mark j23-tree/,/mark j23-history/p' "$LOG" | grep -m1 "deeplabels:")
J23_HISTORY=$(sed -n '/mark j23-history/,/mark j23-filtered/p' "$LOG" | grep -m1 "deeplabels:")
J23_FILTERED=$(sed -n '/mark j23-filtered/,/mark j23-detail/p' "$LOG" | grep -m1 "deeplabels:")
J23_DETAIL=$(sed -n '/mark j23-detail/,$p' "$LOG" | grep -m1 "deeplabels:")
check J23a "Repositories lists Branches (main, feature/x), Remotes (origin), Tags (v1.0, light) and Stashed Changes (wip stash)" \
  '[ "$(sed -n "/mark j23-tree/,/mark j23-changes/p" "$LOG" | grep -c "axexists .* -> 1")" -eq 5 ]' \
  "$(sed -n '/mark j23-tree/,/mark j23-history/p' "$LOG" | grep axexists | tr '\n' ' ') — shots/j23-repositories-light.png, shots/j23-repositories-dark.png"
check J23e "Right after opening the repository the Changes tab lists both commits of main under Recent Commits" \
  'sed -n "/mark j23-changes/,/mark j23-history/p" "$LOG" | grep -q "axexists Recent Commits (2) -> 1"' "$(sed -n '/mark j23-changes/,/mark j23-history/p' "$LOG" | grep axexists)"
check J23b "Show History opens the commit list in the editor area with the time filters" \
  'sed -n "/mark j23-history/,/mark j23-filtered/p" "$LOG" | grep -q "axexists second commit -> 1" && sed -n "/mark j23-history/,/mark j23-filtered/p" "$LOG" | grep -q "axexists first commit -> 1" && echo "$J23_HISTORY" | grep -q "Last 24 Hours"' "— shots/j23-history-light.png"
check J23c "Filtering by second leaves only the matching commit" \
  'sed -n "/mark j23-filtered/,/mark j23-detail/p" "$LOG" | grep -q "axexists second commit -> 1" && sed -n "/mark j23-filtered/,/mark j23-detail/p" "$LOG" | grep -q "axexists first commit -> 0"' "$(sed -n '/mark j23-filtered/,/mark j23-detail/p' "$LOG" | grep axexists | tr '\n' ' ')"
check J23d "Selecting a commit shows its detail: 1 File Changed with notes.md" \
  'echo "$J23_DETAIL" | grep -q "1 File Changed" && echo "$J23_DETAIL" | grep -q "notes.md"' "— shots/j23-detail-light.png, shots/j23-detail-dark.png"

# ---- L7g: the commit editor: stage one change, commit it, then commit the rest through the No Staged Changes alert
CE=$WORK/commit-editor
gitq init "$CE"
printf 'module example.com/ce\n\ngo 1.22\n' > "$CE/go.mod"
{ printf 'package main\n\nconst first = 1\n'; for i in $(seq 1 12); do printf 'const pad%d = %d\n' "$i" "$i"; done; printf 'const last = 2\n\nfunc main() {}\n'; } > "$CE/main.go"
gitq -C "$CE" add -A; gitq -C "$CE" commit -m base
gitq -C "$CE" config user.name Smoke; gitq -C "$CE" config user.email smoke@example.com
sed -i '' 's/const first = 1/const first = 10/; s/const last = 2/const last = 20/' "$CE/main.go"
printf 'package main\n\nfunc notes() {}\n' > "$CE/notes.go"
launch commited "$CE" "$CE/main.go" "wait:10;fakeactive;mark:ready;\
menu:Source Control/Commit…;wait:2.5;mark:j24-open;focus;deeplabels;axexists:All Changes;axexists:Unstaged;axexists:Staged;axexists:Collapse main.go;axexists:Collapse notes.go;shot:j24-editor-light;darkmode;wait:0.6;shot:j24-editor-dark;lightmode;wait:0.6;\
axpress:Stage Change;wait:3;mark:j24-staged;waitfile:$WORK/j24-a;\
focusclass:CommitComposer;fr:Add first change;wait:0.6;menu:Source Control/Commit Changes;wait:2;mark:j24-committed;waitfile:$WORK/j24-b;deeplabels;axexists:Show in History;shot:j24-banner-light;\
axpress:Discard Change;wait:1;mark:j24-discarded;waitfile:$WORK/j24-d;\
focusclass:CommitComposer;fr:Add the rest;wait:0.6;menu:Source Control/Commit Changes;wait:4;mark:j24-alert;deeplabels;shot:j24-alert-light;button:Stage All and Commit;wait:4;mark:j24-all;waitfile:$WORK/j24-c;deeplabels;darkmode;wait:0.6;shot:j24-clean-dark;\
focusclass:CommitComposer;postkey:53;wait:1.5;mark:j24-closed;axexists:Close Commit Editor;mark:done;quit"
J24_STAGED=; J24_SUBJECT=; J24_LEFT=; J24_COUNT=; J24_LAST=; J24_DISCARDED=; J24_DISCARD_TREE=
poll_until() { local n=0; while [ $n -lt 100 ]; do eval "$1" && return 0; sleep 0.3; n=$((n + 1)); done; return 1; }
if wait_mark j24-staged 60; then poll_until '[ -n "$(git -C "$CE" diff --cached --name-only)" ]'; J24_STAGED=$(git -C "$CE" diff --cached | grep '^[-+]const' | tr '\n' ' '); fi; touch "$WORK/j24-a"
if wait_mark j24-committed 30; then poll_until '[ "$(git -C "$CE" log -1 --format=%s)" = "Add first change" ]'; J24_SUBJECT=$(git -C "$CE" log -1 --format=%s); fi; touch "$WORK/j24-b"
if wait_mark j24-discarded 30; then poll_until '! grep -q "const last = 20" "$CE/main.go"'; J24_DISCARDED=$(grep 'const last' "$CE/main.go"); J24_DISCARD_TREE=$(git -C "$CE" status --porcelain | tr '\n' ' '); fi; touch "$WORK/j24-d"
J24_TRACKED=
if wait_mark j24-all 30; then poll_until '[ -z "$(git -C "$CE" status --porcelain)" ]'; J24_LEFT=$(git -C "$CE" status --porcelain | tr '\n' ' '); J24_TRACKED=$(git -C "$CE" ls-files .golens | tr '\n' ' '); J24_COUNT=$(git -C "$CE" rev-list --count HEAD); J24_LAST=$(git -C "$CE" log -1 --format=%s); fi; touch "$WORK/j24-c"
wait_mark done 40; finish 15
J24_OPEN=$(sed -n '/mark j24-open/,/mark j24-staged/p' "$LOG" | grep -m1 "deeplabels:")
J24_BANNER=$(sed -n '/mark j24-committed/,/mark j24-alert/p' "$LOG" | grep -m1 "deeplabels:")
J24_ALERT=$(sed -n '/mark j24-alert/,/mark j24-all/p' "$LOG" | grep -m1 "deeplabels:")
J24_CLEAN=$(sed -n '/mark j24-all/,$p' "$LOG" | grep -m1 "deeplabels:")
check J24a "Source Control ▸ Commit… opens the commit editor with the three tabs and a card per file, and the caret is in the message" \
  'sed -n "/mark j24-open/,/mark j24-staged/p" "$LOG" | grep -q "firstResponder=.*CommitComposerNSTextView" && ( for t in "All Changes" "Unstaged" "Staged" "Collapse main.go" "Collapse notes.go"; do sed -n "/mark j24-open/,/mark j24-staged/p" "$LOG" | grep -q "axexists $t -> 1" || exit 1; done )' \
  "$(sed -n '/mark j24-open/,/mark j24-staged/p' "$LOG" | grep -E 'firstResponder|axexists' | cut -c1-80 | tr '\n' ' ') — shots/j24-editor-light.png, shots/j24-editor-dark.png"
check J24b "Stage Change on the first change stages only that change" \
  'echo "$J24_STAGED" | grep -q "+const first = 10" && ! echo "$J24_STAGED" | grep -q "last"' "index: ${J24_STAGED:-empty}"
check J24c "Commit makes a commit with the typed message and shows the Committed banner with Show in History" \
  '[ "$J24_SUBJECT" = "Add first change" ] && echo "$J24_BANNER" | grep -q "Committed" && sed -n "/mark j24-committed/,/mark j24-alert/p" "$LOG" | grep -q "axexists Show in History -> 1"' \
  "subject: ${J24_SUBJECT:-none} — shots/j24-banner-light.png"
check J24d "Committing with nothing staged asks first (No Staged Changes); Stage All and Commit commits everything" \
  'echo "$J24_ALERT" | grep -q "No Staged Changes" && [ -z "$J24_LEFT" ] && [ -z "$J24_TRACKED" ] && [ "$J24_COUNT" = 3 ] && [ "$J24_LAST" = "Add the rest" ] && echo "$J24_CLEAN" | grep -q "No Uncommitted Changes"' \
  "tree after: ${J24_LEFT:-clean}, tracked .golens: ${J24_TRACKED:-none}, commits: ${J24_COUNT:-?}, last: ${J24_LAST:-none} — shots/j24-alert-light.png, shots/j24-clean-dark.png"
check J24e "Discard Change on the remaining change restores its line in the file and leaves only the untracked file" \
  '[ "$J24_DISCARDED" = "const last = 2" ] && ! echo "$J24_DISCARD_TREE" | grep -q "main.go"' "main.go: ${J24_DISCARDED:-none}, tree: ${J24_DISCARD_TREE:-clean}"

check J24f "Esc in the message closes the commit editor" \
  'sed -n "/mark j24-closed/,\$p" "$LOG" | grep -q "axexists Close Commit Editor -> 0"' "$(sed -n '/mark j24-closed/,$p' "$LOG" | grep -m1 axexists)"

# ---- L7h: Discard Change reverts only its own hunk when an earlier hunk added lines and a block repeats
CD=$WORK/commit-dup
gitq init "$CD"
dup_block() { printf '// keep one\n// keep two\n// keep three\n// %s\n// keep four\n// keep five\n// keep six\n' "$1"; }
dup_filler() { printf '// filler\n'; }
dup_added() { for i in $(seq 1 7); do printf '// added %d\n' "$i"; done; }
{ printf 'package main\n\n'; dup_block TARGET; dup_filler; dup_block TARGET; printf '\nfunc main() {}\n'; } > "$CD/dup.go"
printf 'module example.com/dup\n\ngo 1.22\n' > "$CD/go.mod"
gitq -C "$CD" add -A; gitq -C "$CD" commit -m base
{ printf 'package main\n\n'; dup_added; dup_block CHANGED; dup_filler; dup_block CHANGED; printf '\nfunc main() {}\n'; } > "$CD/dup.go"
{ printf 'package main\n\n'; dup_added; dup_block CHANGED; dup_filler; dup_block TARGET; printf '\nfunc main() {}\n'; } > "$WORK/dup.expected"
launch dupdisc "$CD" "$CD/dup.go" "wait:10;fakeactive;mark:ready;\
menu:View/Console;wait:1;menu:Source Control/Commit…;wait:2.5;mark:j24g-open;shot:j24g-light;darkmode;wait:0.6;shot:j24g-dark;lightmode;wait:0.4;\
axpresslast:Discard Change;wait:3;mark:j24g-discarded;waitfile:$WORK/j24g-a;mark:done;quit"
J24G_COUNT=
if wait_mark j24g-discarded 60; then poll_until '[ "$(grep -c CHANGED "$CD/dup.go")" != 2 ]'; J24G_COUNT=$(grep -c CHANGED "$CD/dup.go"); fi; touch "$WORK/j24g-a"
wait_mark done 40; finish 15
check J24g "Discard Change on the second of two hunks, below a hunk that added lines, reverts only the second block" \
  'cmp -s "$CD/dup.go" "$WORK/dup.expected" && line "axpresslast Discard Change (2 matches)" >/dev/null' "CHANGED lines left: ${J24G_COUNT:-unknown}, tree: $(git -C "$CD" status --porcelain | tr '\n' ' ') — shots/j24g-light.png, shots/j24g-dark.png"

# ---- L7i: conflict choices (Xcode's Left / Right vocabulary), then the merge is committed from the commit editor
RR=$WORK/rc-remote.git; RM=$WORK/rc; RO=$WORK/rc-other
gitq init --bare "$RR"
gitq clone "$RR" "$RM"
printf 'module example.com/rc\n\ngo 1.22\n' > "$RM/go.mod"
{ printf 'package main\n\n// first: base\n\n'; for i in 1 2 3 4 5; do printf 'func filler%d() {}\n' "$i"; done; printf '\n// second: base\n\nfunc main() {}\n'; } > "$RM/main.go"
gitq -C "$RM" add -A; gitq -C "$RM" commit -m base; gitq -C "$RM" push origin HEAD:main
gitq clone "$RR" "$RO"
sed -i '' 's#// first: base#// first: remote#; s#// second: base#// second: remote#' "$RO/main.go"
gitq -C "$RO" commit -am remote; gitq -C "$RO" push origin HEAD:main
sed -i '' 's#// first: base#// first: local#; s#// second: base#// second: local#' "$RM/main.go"
gitq -C "$RM" commit -am local
gitq -C "$RM" config core.commentChar ';'
gitq -C "$RM" pull --no-edit origin main
J25_MSG=$(grep -v '^;' "$RM/.git/MERGE_MSG" | head -1)
J25_COMMENT_LINES=$(grep -c '^;' "$RM/.git/MERGE_MSG")
J25_PRE=$(git -C "$RM" status --porcelain | tr '\n' ' ')
J25_LENS='<<<<<<< HEAD|Choose Left,Choose Right,Left Then Right,Right Then Left,Compare'
launch conflictchoice "$RM" "$RM/main.go" "wait:10;fakeactive;mark:ready;axpress:Source Control;wait:2;focus;\
mark:j25-open;editorctx:<<<<<<<;deeplabels;lightmode;wait:0.6;shot:j25-lens-light;darkmode;wait:0.6;shot:j25-lens-dark;lightmode;wait:0.6;\
lensclick:$J25_LENS|3;wait:1;lensclick:$J25_LENS|0;wait:1;menu:File/Save;wait:1;mark:j25-chosen;deeplabels;waitfile:$WORK/j25-a;\
axpress:Mark “main.go” as Resolved;wait:2;mark:j25-marked;waitfile:$WORK/j25-b;wait:2.5;\
axpress:Continue;wait:3;mark:j25-editor;deeplabels;shot:j25-editor-light;darkmode;wait:0.6;shot:j25-editor-dark;lightmode;wait:0.6;\
focusclass:CommitComposer;menu:Source Control/Commit Changes;wait:3;mark:j25-committed;waitfile:$WORK/j25-c;deeplabels;mark:done;quit"
J25_DISK=; J25_STAGED=; J25_COUNT=; J25_PARENTS=
if wait_mark j25-chosen 60; then poll_until '! grep -q "^<<<<<<<" "$RM/main.go"'; J25_DISK=$(grep -E '^(<<<<<<<|=======|>>>>>>>|// (first|second):)' "$RM/main.go" | tr '\n' ' '); fi; touch "$WORK/j25-a"
if wait_mark j25-marked 30; then poll_until '[ -z "$(git -C "$RM" ls-files -u)" ]'; J25_STAGED=$(git -C "$RM" diff --cached --name-only | tr '\n' ' '); fi; touch "$WORK/j25-b"
if wait_mark j25-committed 30; then poll_until '[ "$(git -C "$RM" rev-list --parents -n 1 HEAD | wc -w | tr -d " ")" = 3 ] && [ -z "$(git -C "$RM" status --porcelain)" ]'; J25_PARENTS=$(git -C "$RM" rev-list --parents -n 1 HEAD | wc -w | tr -d ' '); fi; touch "$WORK/j25-c"
wait_mark done 40; finish 15
J25_CTX=$(sed -n '/mark j25-open/,/mark j25-chosen/p' "$LOG" | grep -m1 "editorctx")
J25_CHOSEN=$(sed -n '/mark j25-chosen/,/mark j25-marked/p' "$LOG" | grep -m1 "deeplabels:")
J25_EDITOR=$(sed -n '/mark j25-editor/,/mark j25-committed/p' "$LOG" | grep -m1 "deeplabels:")
check J25a "The conflict lens and context menu offer Choose Left, Choose Right, Left Then Right and Right Then Left, and both lens clicks land" \
  '( for t in "Choose Left" "Choose Right" "Left Then Right" "Right Then Left"; do echo "$J25_CTX" | grep -q "$t" || exit 1; done ) && [ "$(grep -c "^DRIVE lensclick \(Right Then Left\|Choose Left\) at" "$LOG")" = 2 ] && ! echo "$J25_CTX" | grep -q "Accept"' \
  "$(echo "$J25_CTX" | cut -c1-200) — shots/j25-lens-light.png, shots/j25-lens-dark.png"
check J25b "Right Then Left on the first region and Choose Left on the second leave incoming-then-current, then current only, and no markers" \
  '[ "$J25_DISK" = "// first: remote // first: local // second: local " ]' "main.go lines: ${J25_DISK:-none}"
check J25c "Mark “main.go” as Resolved stages it, Continue opens the commit editor with the merge note and git's MERGE_MSG text as the message" \
  'echo "$J25_CHOSEN" | grep -q "Mark “main.go” as Resolved" && echo "$J25_STAGED" | grep -q "main.go" && echo "$J25_EDITOR" | grep -q "Merging — committing completes the merge" && [ "$(git -C "$RM" log -1 --format=%s)" = "$J25_MSG" ] && [ -n "$J25_MSG" ]' \
  "staged: ${J25_STAGED:-none}, MERGE_MSG: ${J25_MSG:-none}, subject: $(git -C "$RM" log -1 --format=%s) — shots/j25-editor-light.png, shots/j25-editor-dark.png"
check J25e "With core.commentChar set to a semicolon, the merge message drops git's own comment lines, so the commit body has no line starting with a semicolon" \
  '[ "${J25_COMMENT_LINES:-0}" -gt 0 ] && ! git -C "$RM" log -1 --format=%B | grep -q "^[;#]"' \
  "comment lines in MERGE_MSG: ${J25_COMMENT_LINES:-?}, comment lines committed: $(git -C "$RM" log -1 --format=%B | grep -c '^[;#]')"
check J25d "Commit records a merge commit with two parents, MERGE_HEAD is gone and the tree is clean" \
  '[ "$J25_PARENTS" = 3 ] && [ ! -e "$RM/.git/MERGE_HEAD" ] && [ -z "$(git -C "$RM" status --porcelain)" ]' \
  "parents+self words: ${J25_PARENTS:-?}, before: $J25_PRE, after: $(git -C "$RM" status --porcelain | tr '\n' ' ')"

# ---- L7j: Settings ▸ Source Control: author and rebase in the global git config, change bars, comparison view, status, ignored files
SS=$WORK/settings-sc; S26_CFG=$WORK/gitconfig26; S26_IGN=$WORK/ignore26
gitq init "$SS"
printf 'module example.com/sset\n\ngo 1.22\n' > "$SS/go.mod"
{ printf 'package main\n\nconst first = 1\n'; for i in $(seq 1 12); do printf 'const pad%d = %d\n' "$i" "$i"; done; printf 'func main() {}\n'; } > "$SS/main.go"
gitq -C "$SS" add -A; gitq -C "$SS" commit -m base
gitq -C "$SS" config user.name "Local Dev"; gitq -C "$SS" config user.email local@example.com
sed -i '' 's/const first = 1/const first = 10/' "$SS/main.go"
printf '[user]\n\tname = Before Name\n\temail = before@example.com\n[core]\n\texcludesFile = %s\n' "$S26_IGN" > "$S26_CFG"
printf '*.log\nbuild/\n' > "$S26_IGN"
S26_REAL_BEFORE=$(shasum ~/.gitconfig 2>/dev/null | cut -d' ' -f1)
GIT_CONFIG_GLOBAL=$S26_CFG launch settingssc "$SS" "$SS/main.go" "wait:10;fakeactive;mark:ready;\
changebar:const first;wait:1.5;mark:j26-bar-on;popoverlabels;postkey:53;wait:0.8;\
menu:GoLens/Settings…;wait:2.5;mark:j26-open;winpress:Settings|Source Control;wait:4;mark:j26-local-pane;winlabels:Settings;\
winpress:Settings|Global (~/.gitconfig);wait:1.2;mark:j26-pane;winlabels:Settings;\
winsize:Settings|1000;wait:0.8;darkmode;wait:0.8;winshot:Settings|j26-pane-dark;lightmode;wait:0.8;winshot:Settings|j26-pane-light;\
winscrollend:Settings;wait:0.8;mark:j26-bottom;winpress:Settings|*.log;winshot:Settings|j26-bottom-light;darkmode;wait:0.8;winshot:Settings|j26-bottom-dark;lightmode;wait:0.8;\
fieldl:Settings|Author Name|Jane Doe;wait:1.5;fieldl:Settings|Author Email|jane@example.com;wait:1.5;mark:j26-author;waitfile:$WORK/j26-a;\
wintoggle:Settings|Prefer to Rebase When Pulling;wait:1.5;mark:j26-rebase;waitfile:$WORK/j26-b;\
winscrollend:Settings;wait:0.5;winpress:Settings|Add Pattern;wait:1;fieldp:Pattern:*.tmp;wait:1.5;winscrollend:Settings;wait:0.5;winpress:Settings|Add Pattern;wait:1;fieldp:Pattern:*.bak;wait:1.5;mark:j26-added;waitfile:$WORK/j26-c;\
winpress:Settings|Remove Pattern;wait:1.5;mark:j26-removed;waitfile:$WORK/j26-d;\
wintoggle:Settings|Refresh Local Status Automatically;wait:1;mark:j26-refresh-off;waitfile:$WORK/j26-e;wait:3;\
axpress:Source Control;wait:1.5;mark:j26-stale;deeplabels;menu:Source Control/Refresh File Status;wait:4;mark:j26-refreshed;deeplabels;\
wintoggle:Settings|Show Source Control Changes;wait:1;mark:j26-changes-off;winlabels:Settings;winclose:Settings;wait:1;\
changebar:const first;wait:1.5;mark:j26-bar-off;popoverlabels;\
axpress:Source Control;wait:1.5;axpress:main.go;wait:2;mark:j26-diff-right;deeplabels;\
defaultbool:GoLensComparisonLocalOnLeft|1;wait:1.5;mark:j26-diff-left;deeplabels;shot:j26-diff-left;\
menu:GoLens/Settings…;wait:2;mark:j26-reopen;winlabels:Settings;winclose:Settings;wait:0.5;mark:done;quit"
S26_AUTHOR=; S26_REBASE=; S26_IGNORED=; S26_IGNORED2=
if wait_mark j26-author 90; then poll_until '[ "$(git config -f "$S26_CFG" user.email)" = jane@example.com ]'; S26_AUTHOR="$(git config -f "$S26_CFG" user.name) <$(git config -f "$S26_CFG" user.email)>"; fi; touch "$WORK/j26-a"
if wait_mark j26-rebase 30; then poll_until '[ "$(git config -f "$S26_CFG" pull.rebase)" = true ]'; S26_REBASE=$(git config -f "$S26_CFG" pull.rebase); fi; touch "$WORK/j26-b"
if wait_mark j26-added 30; then poll_until 'grep -q "^\*\.bak$" "$S26_IGN"'; S26_IGNORED=$(tr '\n' ' ' < "$S26_IGN"); fi; touch "$WORK/j26-c"
if wait_mark j26-removed 30; then poll_until '! grep -q "^\*\.bak$" "$S26_IGN"'; S26_IGNORED2=$(tr '\n' ' ' < "$S26_IGN"); fi; touch "$WORK/j26-d"
if wait_mark j26-refresh-off 30; then printf 'package main\n' > "$SS/fresh26.go"; fi; touch "$WORK/j26-e"
wait_mark done 60; finish 15
S26_REAL_AFTER=$(shasum ~/.gitconfig 2>/dev/null | cut -d' ' -f1)
S26_PREF_CHANGES=$(defaults read $DOMAIN GoLensShowSourceControlChanges 2>/dev/null)
S26_PREF_REFRESH=$(defaults read $DOMAIN GoLensRefreshGitStatusAutomatically 2>/dev/null)
S26_PREF_LEFT=$(defaults read $DOMAIN GoLensComparisonLocalOnLeft 2>/dev/null)
S26_PREF_FETCH=$(defaults read $DOMAIN GoLensFetchAutomatically 2>/dev/null)
for k in GoLensShowSourceControlChanges GoLensRefreshGitStatusAutomatically GoLensComparisonLocalOnLeft GoLensFetchAutomatically; do defaults delete $DOMAIN $k >/dev/null 2>&1; done
S26_PANE=$(sed -n '/mark j26-pane/,/mark j26-author/p' "$LOG" | grep -m1 "winlabels:")
S26_BOTTOM=$(sed -n '/mark j26-bottom/,/mark j26-author/p' "$LOG" | grep -m1 "winpress Settings|\*\.log")
S26_BAR_ON=$(sed -n '/mark j26-bar-on/,/mark j26-open/p' "$LOG" | grep -m1 "popoverlabels:")
S26_BAR_OFF=$(sed -n '/mark j26-bar-off/,/mark j26-diff-right/p' "$LOG" | grep -m1 "popoverlabels:")
S26_STALE=$(sed -n '/mark j26-stale/,/mark j26-refreshed/p' "$LOG" | grep -m1 "deeplabels:")
S26_FRESH=$(sed -n '/mark j26-refreshed/,/mark j26-changes-off/p' "$LOG" | grep -m1 "deeplabels:")
S26_RIGHT=$(sed -n '/mark j26-diff-right/,/mark j26-diff-left/p' "$LOG" | grep -m1 "deeplabels:")
S26_LEFT=$(sed -n '/mark j26-diff-left/,/mark j26-reopen/p' "$LOG" | grep -m1 "deeplabels:")
S26_REOPEN=$(sed -n '/mark j26-reopen/,/mark done/p' "$LOG" | grep -m1 "winlabels:")
check J26a "Settings ▸ Source Control shows Git, Editor, Status and Ignored Files with the global author, the repository override and the excludes file" \
  '( for t in "Git" "Editor" "Status" "Ignored Files" "Author Name" "Prefer to Rebase When Pulling" "Show Source Control Changes" "Comparison View" "Refresh Local Status Automatically" "Fetch and Refresh Server Status Automatically" "Add Pattern" "Before Name" "before@example.com" "This repository uses Local Dev local@example.com."; do echo "$S26_PANE" | grep -qF "$t" || { echo "missing: $t" >&2; exit 1; }; done )' \
  "$(echo "$S26_PANE" | cut -c1-260) — shots/j26-pane-light.png, shots/j26-pane-dark.png"
check J26i "The Ignored Files list exposes an accessibility element for each pattern, labelled with the pattern" \
  '[ -n "$S26_BOTTOM" ] && ! echo "$S26_BOTTOM" | grep -q -- "-> none"' "${S26_BOTTOM:-no winpress line}"
check J26b "Editing the author in Settings writes the temporary global config and leaves ~/.gitconfig untouched" \
  '[ "$S26_AUTHOR" = "Jane Doe <jane@example.com>" ] && [ "$S26_REAL_BEFORE" = "$S26_REAL_AFTER" ]' "config: ${S26_AUTHOR:-unchanged}, ~/.gitconfig unchanged: $([ "$S26_REAL_BEFORE" = "$S26_REAL_AFTER" ] && echo yes || echo NO)"
check J26c "Prefer to Rebase When Pulling writes pull.rebase = true" '[ "$S26_REBASE" = true ]' "pull.rebase: ${S26_REBASE:-unset}"
check J26d "Add and Remove on Ignored Files keep the existing patterns, edit the excludes file, and git honours it" \
  'echo "$S26_IGNORED" | grep -qF "*.log" && echo "$S26_IGNORED" | grep -qF "build/" && echo "$S26_IGNORED" | grep -qF "*.tmp" && echo "$S26_IGNORED" | grep -qF "*.bak" && ! echo "$S26_IGNORED2" | grep -qF "*.bak" && echo "$S26_IGNORED2" | grep -qF "*.tmp" && echo "$S26_IGNORED2" | grep -qF "*.log" && GIT_CONFIG_GLOBAL=$S26_CFG git -C "$SS" check-ignore -q x.tmp' "after add: ${S26_IGNORED:-none}, after remove: ${S26_IGNORED2:-none}"
check J26e "With Show Source Control Changes on the change bar opens its popover; with it off the same click opens nothing" \
  'echo "$S26_BAR_ON" | grep -q "Show Change" && echo "$S26_BAR_ON" | grep -q "Stage Change" && ! echo "$S26_BAR_OFF" | grep -q "Show Change" && ! echo "$S26_BAR_OFF" | grep -q "Stage Change" && [ -n "$S26_BAR_OFF" ]' "on: $(echo "$S26_BAR_ON" | cut -c1-90) | off: $(echo "$S26_BAR_OFF" | cut -c1-90)"
check J26f "With Refresh Local Status Automatically off a new file does not reach the Changes navigator until Refresh File Status" \
  '! echo "$S26_STALE" | grep -q "fresh26.go" && echo "$S26_FRESH" | grep -q "fresh26.go"' "before refresh: $(echo "$S26_STALE" | grep -c fresh26.go), after: $(echo "$S26_FRESH" | grep -c fresh26.go)"
check J26g "The Original column is on the left by default and moves to the right with Local Revision on Left Side" \
  'echo "$S26_RIGHT" | grep -o "Original (HEAD)\|Local Changes" | tr "\n" ">" | grep -q "^Original (HEAD)>Local Changes>" && echo "$S26_LEFT" | grep -o "Original (HEAD)\|Local Changes" | tr "\n" ">" | grep -q "^Local Changes>Original (HEAD)>"' \
  "default: $(echo "$S26_RIGHT" | grep -o 'Original (HEAD)\|Local Changes' | tr '\n' '>'), swapped: $(echo "$S26_LEFT" | grep -o 'Original (HEAD)\|Local Changes' | tr '\n' '>') — shots/j26-diff-left.png"
check J26h "The choices made in Settings are kept: Local Revision on Left Side shown on reopen, pull.rebase on, Show Source Control Changes off, Refresh Local Status Automatically off" \
  'echo "$S26_REOPEN" | grep -q "Local Revision on Left Side" && [ "$S26_REBASE" = true ] && [ "$S26_PREF_CHANGES" = 0 ] && [ "$S26_PREF_REFRESH" = 0 ] && [ "$S26_PREF_LEFT" = 1 ]' "$(echo "$S26_REOPEN" | cut -c1-120) | rebase: ${S26_REBASE:-unset}, changes: ${S26_PREF_CHANGES:-default}, refresh: ${S26_PREF_REFRESH:-default}, left: ${S26_PREF_LEFT:-default}, fetch: ${S26_PREF_FETCH:-default}"

# ---- L8: generate a Dockerfile for a Go module that has none
GN=$WORK/gen
mkdir -p "$GN"
printf 'module example.com/gen\n\ngo 1.22\n' > "$GN/go.mod"
printf 'package main\n\nimport (\n\t"net/http"\n\t"time"\n)\n\nfunc main() {\n\tsrv := &http.Server{Addr: ":8080", ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second}\n\t_ = srv.ListenAndServe()\n}\n' > "$GN/main.go"
launch gen "$GN" "$GN/main.go" "wait:10;fakeactive;mark:ready;menu:Tools/Containers & Compose/Generate Dockerfile for Go Project…;wait:3;mark:j15-sheet;deeplabels;shot:j15-sheet-dark;lightmode;wait:0.6;shot:j15-sheet-light;\
axpress:Create;wait:3;mark:j15-created;deeplabels;shot:j15-created;\
menu:Tools/Containers & Compose/Generate Dockerfile for Go Project…;wait:3;axpress:Create;wait:1.5;mark:j15-replace;labels;button:Cancel;wait:1;mark:done;quit"
wait_mark done 90; finish 15
J15_SHEET=$(sed -n '/mark j15-sheet/,/shot/p' "$LOG" | grep -m1 "deeplabels:")
J15_CREATED=$(sed -n '/mark j15-created/,/shot/p' "$LOG" | grep -m1 "deeplabels:")
check J15a "Generate Dockerfile detects the port and Go version and shows a preview" \
  'echo "$J15_SHEET" | grep -q "8080" && echo "$J15_SHEET" | grep -q "1.22"' "$(echo "$J15_SHEET" | grep -o 'Found [^|]*' | head -1) — shots/j15-sheet-light.png, shots/j15-sheet-dark.png"
check J15b "Create writes a Dockerfile (EXPOSE 8080, non-root) and a .dockerignore with no Dockerfile findings" \
  'grep -q "EXPOSE 8080" "$GN/Dockerfile" && grep -q "USER" "$GN/Dockerfile" && [ -f "$GN/.dockerignore" ] && ! echo "$J15_CREATED" | grep -q "[1-9][0-9]* \(error\|warning\)"' \
  "$(grep -m1 '^FROM' "$GN/Dockerfile" 2>/dev/null) … $(grep -m1 '^EXPOSE' "$GN/Dockerfile" 2>/dev/null) — shots/j15-created.png"
check J15c "Generating again asks before replacing the existing Dockerfile" \
  'sed -n "/mark j15-replace/,\$p" "$LOG" | grep -m1 "labels(" | grep -q "Cancel | Replace"' "$(sed -n '/mark j15-replace/,$p' "$LOG" | grep -m1 'labels(' | cut -c1-80)"

# ---- L9: a missing import is fixed from the issue popup with go get, offline from a file proxy
GG=$WORK/goget
PROXY=$WORK/goproxy
mkdir -p "$GG" "$PROXY/example.com/greet/@v" "$WORK/zsrc/example.com/greet@v1.0.0"
printf 'module example.com/greet\n\ngo 1.22\n' > "$PROXY/example.com/greet/@v/v1.0.0.mod"
cp "$PROXY/example.com/greet/@v/v1.0.0.mod" "$WORK/zsrc/example.com/greet@v1.0.0/go.mod"
printf 'package greet\n\nfunc Hello() string { return "hello" }\n' > "$WORK/zsrc/example.com/greet@v1.0.0/greet.go"
printf 'v1.0.0\n' > "$PROXY/example.com/greet/@v/list"
printf '{"Version":"v1.0.0","Time":"2026-01-01T00:00:00Z"}\n' > "$PROXY/example.com/greet/@v/v1.0.0.info"
(cd "$WORK/zsrc" && zip -qrD "$PROXY/example.com/greet/@v/v1.0.0.zip" example.com)
printf 'module example.com/goget\n\ngo 1.22\n' > "$GG/go.mod"
printf 'package main\n\nimport "example.com/greet"\n\nfunc main() { println(greet.Hello()) }\n' > "$GG/main.go"
GOPROXY=file://$PROXY GOSUMDB=off GOTOOLCHAIN=local GOFLAGS=-modcacherw GOMODCACHE=$WORK/modcache \
launch goget "$GG" "$GG/main.go" "wait:10;fakeactive;mark:ready;waitlabel:1 error;issueclick:example.com/greet;wait:2;\
axpress:go get package example.com/greet;wait:20;mark:j16-added;deeplabels;shot:j16-added;\
menu:Product/Add Go Module…;wait:2;mark:j16-sheet;deeplabels;shot:j16-sheet-dark;lightmode;wait:0.6;shot:j16-sheet-light;button:Cancel;wait:1;mark:done;quit"
wait_mark done 90; finish 15
J16_ADDED=$(sed -n '/mark j16-added/,$p' "$LOG" | grep -m1 "deeplabels:")
check J16a "A missing module offers the go get quick fix in the issue popup" \
  'grep -q "axpress go get package example.com/greet -> .* ok=1" "$LOG"' "$(grep -m1 'axpress go get package' "$LOG")"
check J16b "go get runs in the console, go.mod requires the module directly and the error clears" \
  'grep -q "^require example.com/greet v1.0.0$" "$GG/go.mod" && echo "$J16_ADDED" | grep -q "go mod tidy" && ! echo "$J16_ADDED" | grep -q "[1-9][0-9]* error"' \
  "$(grep -m1 'example.com/greet' "$GG/go.mod" 2>/dev/null) — shots/j16-added.png"
J16_SHEET=$(sed -n '/mark j16-sheet/,$p' "$LOG" | grep -m1 "deeplabels:")
check J16c "Product ▸ Add Go Module… opens a sheet with the module field and Add" \
  'echo "$J16_SHEET" | grep -q "Module or package" && echo "$J16_SHEET" | grep -q "| Add"' "$(echo "$J16_SHEET" | grep -o 'Add Go Module[^|]*' | head -1) — shots/j16-sheet-light.png, shots/j16-sheet-dark.png"

# ---- L10: sqlc, jump between a generated Go method and its SQL query, Usages lens, Run sqlc generate
SQ=$WORK/sqlc
mkdir -p "$SQ"
cp -R "$HERE/../../core/sqlc/testdata/sqlite/." "$SQ/"
printf 'module example.com/sq\n\ngo 1.22\n' > "$SQ/go.mod"
printf 'package main\n\nimport (\n\t"context"\n\t"database/sql"\n\n\t"example.com/sq/db"\n)\n\nfunc main() {\n\tq := db.New((*sql.DB)(nil))\n\t_, _ = q.GetUser(context.Background(), 1)\n}\n' > "$SQ/main.go"
printf '\n-- name: CountUsers :one\nSELECT count(*) FROM users;\n' >> "$SQ/sql/queries/users.sql"
SQLC_OK=0; command -v sqlc >/dev/null 2>&1 && SQLC_OK=1
launch sqlc "$SQ" "$SQ/main.go" "wait:10;fakeactive;mark:ready;wait:8;cmdclick:GetUser(context;wait:3;mark:j17-sql;line;wait:2;shot:j17-lenses-dark;lightmode;wait:0.6;shot:j17-lenses-light;\
cmdclick:GetUser :one;wait:3;mark:j17-go;line;menu:Navigate/Back;wait:2;\
lensclick:-- name: GetUser|Go Method,Usages|1;wait:5;mark:j17-usages;line;menu:Navigate/Back;wait:2;\
lensclick:-- name: CountUsers|Not Generated — Run sqlc generate|0;wait:10;mark:j17-generated;wait:3;cmdclick:CountUsers :one;wait:3;mark:j17-count;line;mark:done;quit"
wait_mark done 120; finish 15
check J17a "Go to Definition on a sqlc method opens its -- name: query in the .sql file" \
  'sed -n "/mark j17-sql/,\$p" "$LOG" | grep -m1 "DRIVE line:" | grep -q -- "-- name: GetUser :one"' "$(sed -n '/mark j17-sql/,$p' "$LOG" | grep -m1 'DRIVE line:' | cut -c1-100) — shots/j17-lenses-light.png, shots/j17-lenses-dark.png"
check J17b "Cmd-click on the query name opens the generated Go method" \
  'sed -n "/mark j17-go/,\$p" "$LOG" | grep -m1 "DRIVE line:" | grep -q "func (q \*Queries) GetUser("' "$(sed -n '/mark j17-go/,$p' "$LOG" | grep -m1 'DRIVE line:' | cut -c1-100)"
check J17c "Usages lens jumps to the only call outside generated code" \
  'sed -n "/mark j17-usages/,\$p" "$LOG" | grep -m1 "DRIVE line:" | grep -q "q.GetUser(context.Background(), 1)"' "$(sed -n '/mark j17-usages/,$p' "$LOG" | grep -m1 'DRIVE line:' | cut -c1-100)"
if [ $SQLC_OK = 1 ]; then
  check J17d "Run sqlc generate from the Not Generated lens creates the method and Cmd-click reaches it" \
    'grep -q "func (q \*Queries) CountUsers(" "$SQ/db/users.sql.go" && sed -n "/mark j17-count/,\$p" "$LOG" | grep -m1 "DRIVE line:" | grep -q "func (q \*Queries) CountUsers("' \
    "$(sed -n '/mark j17-count/,$p' "$LOG" | grep -m1 'DRIVE line:' | cut -c1-100)"
fi

# ---- L11: toolchain health, a module that needs a newer Go than this Mac may use, and a gopls built with an older Go
TC=$WORK/toolchain
mkdir -p "$TC"
printf 'module example.com/tc\n\ngo 1.99\n' > "$TC/go.mod"
printf 'package main\n\nfunc main() {}\n' > "$TC/main.go"
GOTOOLCHAIN=local launch tclocal "$TC" "$TC/main.go" "wait:10;fakeactive;mark:ready;wait:4;mark:j18-status;deeplabels;\
axpress:Go 1.99 Required;wait:1.5;mark:j18-popover;popoverlabels;shot:j18-popover-dark;lightmode;wait:0.6;shot:j18-popover-light;mark:done;quit"
wait_mark done 60; finish 15
J18_STATUS=$(sed -n '/mark j18-status/,/mark j18-popover/p' "$LOG" | grep -m1 "deeplabels:")
J18_POP=$(sed -n '/mark j18-popover/,$p' "$LOG" | grep -m1 "popoverlabels:")
check J18a "go 1.99 with GOTOOLCHAIN=local: the status bar says Go 1.99 Required" \
  'echo "$J18_STATUS" | grep -q "Go 1.99 Required"' "$(echo "$J18_STATUS" | grep -o 'Go 1.99 Required' | head -1)"
check J18b "The popover names GOTOOLCHAIN=local, says where it is set and offers Download Go…" \
  'echo "$J18_POP" | grep -q "GOTOOLCHAIN=local" && echo "$J18_POP" | grep -q "environment GoLens was opened with" && echo "$J18_POP" | grep -q "Download Go…"' \
  "$(echo "$J18_POP" | grep -o 'This module needs Go[^|]*' | cut -c1-110) — shots/j18-popover-light.png, shots/j18-popover-dark.png"
GOTOOLCHAIN=path launch tcpath "$TC" "$TC/main.go" "wait:10;fakeactive;mark:ready;wait:6;mark:j18-gopls;deeplabels;\
axpress:gopls Is Out of Date;wait:1.5;mark:j18-gopls-popover;popoverlabels;shot:j18-gopls-popover;mark:done;quit"
wait_mark done 60; finish 15
J18_GOPLS=$(sed -n '/mark j18-gopls$/,/mark j18-gopls-popover/p' "$LOG" | grep -m1 "deeplabels:")
J18_GOPLS_POP=$(sed -n '/mark j18-gopls-popover/,$p' "$LOG" | grep -m1 "popoverlabels:")
check J18c "gopls built with an older Go than go.mod: gopls Out of Date with Update gopls and the exact command" \
  'echo "$J18_GOPLS" | grep -q "gopls Is Out of Date" && echo "$J18_GOPLS_POP" | grep -q "Update gopls" && echo "$J18_GOPLS_POP" | grep -q "GOTOOLCHAIN=go1.99.0+auto go install golang.org/x/tools/gopls@latest"' \
  "$(echo "$J18_GOPLS_POP" | grep -o 'gopls was built with[^|]*' | cut -c1-110) — shots/j18-gopls-popover.png"

# ---- L12: Source Control right after the VM starts and after reopening a project shows the branch and changes without switching navigators
GRO=$WORK/git-reopen; GRN=$WORK/git-plain
mkdir -p "$GRO" "$GRN"
printf 'module example.com/gitreopen\n\ngo 1.22\n' > "$GRO/go.mod"
printf 'package main\n\nfunc main() {}\n' > "$GRO/main.go"
gitq init -b reopen-check "$GRO"; gitq -C "$GRO" add -A; gitq -C "$GRO" commit -m base
printf '\n// reopened\n' >> "$GRO/main.go"
printf 'module example.com/plain\n\ngo 1.22\n' > "$GRN/go.mod"
launch gitreopen "$GRO" "$GRO/main.go" "wait:10;fakeactive;mark:ready;axpress:Source Control;wait:4;mark:j27-open;deeplabels;\
stubpanel:$GRN;menu:File/Open Project…;wait:5;winkey:git-plain;winpress:git-plain|Source Control;wait:3;mark:j27-plain;winlabels:git-plain;stubpanel:$GRO;menu:File/Open Project…;wait:6;winkey:git-reopen;mark:j27-reopen;winlabels:git-reopen;\
shot:j27-reopen-light;darkmode;wait:0.6;shot:j27-reopen-dark;lightmode;mark:done;quit"
wait_mark done 90; finish 15
J27_OPEN=$(sed -n '/mark j27-open/,/deeplabels:/p' "$LOG" | grep -m1 "deeplabels:")
J27_PLAIN=$(sed -n '/mark j27-plain/,/winlabels:/p' "$LOG" | grep -m1 "winlabels:")
J27_REOPEN=$(sed -n '/mark j27-reopen/,/winlabels:/p' "$LOG" | grep -m1 "winlabels:")
j27_shows_repo() { echo "$1" | grep -q "reopen-check" && echo "$1" | grep -q "Uncommitted Changes \[1 file\]" && echo "$1" | grep -q "Recent Commits (1)" && ! echo "$1" | grep -q "Not a Git Repository"; }
check J27a "Source Control opened while the VM starts shows the branch, the changed file and the commit, not Not a Git Repository" \
  'j27_shows_repo "$J27_OPEN"' "$(echo "$J27_OPEN" | grep -o 'Not a Git Repository\|reopen-check\|Loading branch…\|Uncommitted Changes \[[^]]*\]\|Recent Commits ([0-9]*)' | sort -u | tr '\n' ' ')"
check J27b "A folder without a repository, opened in its own window, says Not a Git Repository" \
  'echo "$J27_PLAIN" | grep -q "Not a Git Repository"' "$(echo "$J27_PLAIN" | grep -o 'Not a Git Repository' | head -1)"
check J27c "After opening another project and reopening this one, Source Control shows the branch, the changed file and the commit without switching navigators" \
  'j27_shows_repo "$J27_REOPEN"' "$(echo "$J27_REOPEN" | grep -o 'Not a Git Repository\|reopen-check\|Loading branch…\|Uncommitted Changes \[[^]]*\]\|Recent Commits ([0-9]*)' | sort -u | tr '\n' ' ') — shots/j27-reopen-light.png, shots/j27-reopen-dark.png"

# ---- L13: two project windows stay isolated while running; a relaunch shows one window that belongs entirely to the last active project
ISA=$WORK/iso-alpha; ISB=$WORK/iso-beta
mkdir -p "$ISA/apkg" "$ISB/bpkg"
printf 'module example.com/isoalpha\n\ngo 1.22\n' > "$ISA/go.mod"
printf 'package main\n\nfunc main() {\n\tundefinedAlpha()\n}\n' > "$ISA/alpha.go"
printf 'package apkg\n\nfunc A() int { return 1 }\n' > "$ISA/apkg/a.go"
printf 'package apkg\n\nimport (\n\t"fmt"\n\t"testing"\n\t"time"\n)\n\nfunc TestIsoAlpha(t *testing.T) {\n\tfmt.Println("iso-alpha-test-marker")\n\ttime.Sleep(4 * time.Second)\n}\n' > "$ISA/apkg/a_test.go"
printf 'module example.com/isobeta\n\ngo 1.22\n' > "$ISB/go.mod"
printf 'package main\n\nfunc main() {}\n' > "$ISB/beta.go"
printf 'package bpkg\n\nfunc B() int { return 2 }\n' > "$ISB/bpkg/b.go"
mkdir -p "$ISB/bbroken"
printf 'package bbroken\n\nvar _ = undefinedIsoBetaBuildMarker\n' > "$ISB/bbroken/x.go"
ISO_SWITCH=""
for n in 1 2 3 4 5 6; do ISO_SWITCH="${ISO_SWITCH}winkey:iso-alpha;wait:0.3;winkey:iso-beta;wait:0.3;"; done
ISO_START=$(date '+%Y-%m-%d %H:%M:%S')
launch iso "$ISA" "$ISA/alpha.go" "wait:10;fakeactive;mark:ready;stubpanel:$ISB;menu:File/Open Project…;wait:8;winkey:iso-beta;rowclick:beta.go;wait:3;\
winpress:iso-alpha|Terminal;wait:4;winpress:iso-beta|Terminal;wait:4;mark:j28-terms;waitfile:$WORK/j28-t;\
winkey:iso-beta;wintype:iso-beta|// typed in beta\n;wait:1;${ISO_SWITCH}fakeinactive;wait:2;fakeactive;winkey:iso-beta;wait:6;mark:j28-state;waitfile:$WORK/j28-s;windows;\
wineditor:iso-alpha;wineditor:iso-beta;winexists:iso-alpha|apkg;winexists:iso-alpha|bpkg;winexists:iso-beta|bpkg;winexists:iso-beta|apkg;winlabels:iso-alpha;winlabels:iso-beta;\
winshot:iso-alpha|j28-alpha;winshot:iso-beta|j28-beta;\
winkey:iso-alpha;menu:Product/Test;wait:1.5;winkey:iso-beta;menu:Product/Build;wait:15;mark:j28-tasks;winconsole:iso-alpha;winconsole:iso-beta;\
winshot:iso-alpha|j28-alpha-test;winshot:iso-beta|j28-beta-build;winkey:iso-beta;menu:File/Save;wait:1;mark:done;askquit"
ISO_PID=$APP_PID; ISO_CWDS=; GOPLS_T=; GOPLS_S=
gopls_pids() { pgrep -P "$ISO_PID" -f gopls | sort | tr '\n' ' '; }
if wait_mark j28-terms 90; then sleep 1; ISO_CWDS=$(for k in $(shell_pids); do real "$(pid_cwd "$k")"; done | sort | tr '\n' ' '); GOPLS_T=$(gopls_pids); fi
touch "$WORK/j28-t"
wait_mark j28-state 90 && GOPLS_S=$(gopls_pids); touch "$WORK/j28-s"
wait_mark done 120; finish 20
ISO_LOOPS=$("$HERE/layout-loop-check.sh" "$ISO_PID" "$ISO_START")
ISO_ALPHA=$(line "winlabels: iso-alpha")
ISO_BETA=$(line "winlabels: iso-beta")
check J28a "Two project windows each carry their own project's title" 'line "window iso-alpha " >/dev/null && line "window iso-beta " >/dev/null' "$(lines 'DRIVE window ' | sed 's/ class=.*//;s/^DRIVE //' | tr '\n' ' ')"
check J28b "Each window's tree shows only its own project" 'line "winexists iso-alpha|apkg -> 1" >/dev/null && line "winexists iso-alpha|bpkg -> 0" >/dev/null && line "winexists iso-beta|bpkg -> 1" >/dev/null && line "winexists iso-beta|apkg -> 0" >/dev/null' "$(lines 'winexists' | sed 's/^DRIVE //' | tr '\n' ' ') — shots/j28-alpha.png, shots/j28-beta.png"
ISA_STD=${ISA#/private}; ISB_STD=${ISB#/private}
check J28c "Typing in one window changes only that window's editor, after switching key windows and deactivating the app" '(line "wineditor iso-alpha -> window=iso-alpha file=$ISA/alpha.go" || line "wineditor iso-alpha -> window=iso-alpha file=$ISA_STD/alpha.go") | grep -q "first=package main" && (line "wineditor iso-beta -> window=iso-beta file=$ISB/beta.go" || line "wineditor iso-beta -> window=iso-beta file=$ISB_STD/beta.go") | grep -q "first=// typed in beta"' "$(lines 'wineditor' | sed 's/^DRIVE //;s/ len=.*first=/ first=/' | tr '\n' ' ')"
check J28d "Each window shows only its own project's issues" 'echo "$ISO_ALPHA" | grep -q "undefinedAlpha" && ! echo "$ISO_BETA" | grep -q "undefinedAlpha"' "alpha: $(echo "$ISO_ALPHA" | grep -o 'Line [0-9]*: [^|]*' | head -1); beta: $(echo "$ISO_BETA" | grep -o 'Line [0-9]*: [^|]*' | head -1)"
check J28e "Each window's terminal starts in its own project" 'echo "$ISO_CWDS" | grep -qF "$(real "$ISA")" && echo "$ISO_CWDS" | grep -qF "$(real "$ISB")"' "shell cwds: ${ISO_CWDS:-none}"
check J28f "Switching key windows and deactivating the app keeps one gopls running, not restarted" '[ -n "$GOPLS_T" ] && [ "$GOPLS_T" = "$GOPLS_S" ]' "gopls pids after opening both: ${GOPLS_T:-none}; after switching: ${GOPLS_S:-none}"
ISO_ALPHA_CONSOLE=$(line "winconsole iso-alpha ")
ISO_BETA_CONSOLE=$(line "winconsole iso-beta ")
check J28i "A test run in one window and a build in the other at the same time each show only their own output and result" \
  'echo "$ISO_ALPHA_CONSOLE" | grep -q "iso-alpha-test-marker" && echo "$ISO_ALPHA_CONSOLE" | grep -q "Tests " && ! echo "$ISO_ALPHA_CONSOLE" | grep -q "undefinedIsoBetaBuildMarker\|Building iso-beta" && echo "$ISO_BETA_CONSOLE" | grep -q "undefinedIsoBetaBuildMarker" && echo "$ISO_BETA_CONSOLE" | grep -q "Process exited with error" && ! echo "$ISO_BETA_CONSOLE" | grep -q "iso-alpha-test-marker\|Tests "' \
  "alpha: $(echo "$ISO_ALPHA_CONSOLE" | grep -o 'iso-alpha-test-marker\|Tests [a-z]*: [^|]*\|undefinedIsoBetaBuildMarker' | sort -u | tr '\n' ' '); beta: $(echo "$ISO_BETA_CONSOLE" | grep -o 'undefinedIsoBetaBuildMarker\|Process exited with error\|iso-alpha-test-marker\|Tests [a-z]*: [^|]*' | sort -u | tr '\n' ' ') — shots/j28-alpha-test.png, shots/j28-beta-build.png"
check J28g "No AppKit layout or update-constraints loop warnings with two windows" '[ "${ISO_LOOPS:-1}" = 0 ]' "layout loop warnings: ${ISO_LOOPS:-unknown}"
LOG=$ART/logs/iso-relaunch.log
DRIVE="wait:14;fakeactive;mark:ready;windows;wineditor:iso-beta;winexists:iso-beta|bpkg;winexists:iso-beta|apkg;winlabels:iso-beta;winshot:iso-beta|j28-relaunch;mark:done;quit" DRIVE_OUT=$LOG DRIVE_SHOTS=$ART/shots DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
  "$APP" -GoLensShowConsole '<true/>' > "$ART/logs/iso-relaunch.app.log" 2>&1 &
APP_PID=$!
wait_mark done 60; finish 15
ISO_RELAUNCH=$(line "winlabels: iso-beta")
check J28h "A relaunch shows one window whose title, tree, tab and issues all belong to the last active project" '[ "$(lines "DRIVE window " | wc -l | tr -d " ")" = 1 ] && line "window iso-beta " >/dev/null && (line "wineditor iso-beta -> window=iso-beta file=$ISB/beta.go" >/dev/null || line "wineditor iso-beta -> window=iso-beta file=$ISB_STD/beta.go" >/dev/null) && line "winexists iso-beta|bpkg -> 1" >/dev/null && line "winexists iso-beta|apkg -> 0" >/dev/null && ! echo "$ISO_RELAUNCH" | grep -q "undefinedAlpha"' "$(lines 'DRIVE window \|wineditor\|winexists' | sed 's/^DRIVE //;s/ class=.*//;s/ len=.*//' | tr '\n' ' ') — shots/j28-relaunch.png"

# ---- L14: failed Move to Trash shows its error alert after the confirmation alert closes, and unreadable run.json is preserved
ERRPROJ=$WORK/file-errors
mkdir -p "$ERRPROJ/ro" "$ERRPROJ/.golens"
printf 'module example.com/errproj\n\ngo 1.22\n' > "$ERRPROJ/go.mod"
printf 'package main\n\nfunc main() {}\n' > "$ERRPROJ/main.go"
printf 'package main\n\nfunc note() {}\n' > "$ERRPROJ/ro/note.go"
printf '{corrupt-user-config' > "$ERRPROJ/.golens/run.json"
chmod 555 "$ERRPROJ/ro"
launch fileerr "$ERRPROJ" "$ERRPROJ/main.go" "wait:10;fakeactive;mark:ready;waitlabel:Couldn’t Read Run Configurations;wait:1.5;mark:j29-runjson;wininfo;button:OK;wait:1;\
rowexpand:ro;wait:1;rowmenu:note.go|Move to Trash…;wait:1.5;button:Move to Trash;waitlabel:Couldn’t Move;mark:j29-trash;wininfo;\
shot:j29-trash-error-light;darkmode;wait:0.8;shot:j29-trash-error-dark;lightmode;button:Cancel;wait:1;\
rowmenu:ro|New File;wait:0.8;fieldp:File Name or Path:blocked.go;waitlabel:Couldn’t Create;wait:0.8;mark:j29-create;wininfo;\
shot:j29-create-error-light;darkmode;wait:0.8;shot:j29-create-error-dark;lightmode;button:Cancel;wait:1;mark:done;quit"
wait_mark done 90; finish 15
chmod 755 "$ERRPROJ/ro" 2>/dev/null || true
J29_RUNJSON=$(sed -n '/mark j29-runjson/,/wininfo end/p' "$LOG" | grep "DRIVE win " | tr '\n' ' ')
J29_TRASH=$(sed -n '/mark j29-trash/,/wininfo end/p' "$LOG" | grep "DRIVE win " | tr '\n' ' ')
J29_CREATE=$(sed -n '/mark j29-create/,/wininfo end/p' "$LOG" | grep "DRIVE win " | tr '\n' ' ')
check J29a "Failed Move to Trash presents Couldn’t Move “note.go” to the Trash after the confirmation sheet closes and keeps note.go" \
  'echo "$J29_TRASH" | grep -q "Couldn’t Move “note.go” to the Trash" && echo "$J29_TRASH" | grep -q "Try Again" && [ -f "$ERRPROJ/ro/note.go" ]' \
  "${J29_TRASH:-no failure alert} — shots/j29-trash-error-light.png, shots/j29-trash-error-dark.png"
check J29b "Corrupt run.json is kept as run.json.unreadable and reports Couldn’t Read Run Configurations" \
  'echo "$J29_RUNJSON" | grep -q "Couldn’t Read Run Configurations" && echo "$J29_RUNJSON" | grep -q "Show in Finder" && [ ! -e "$ERRPROJ/.golens/run.json" ] && [ "$(cat "$ERRPROJ/.golens/run.json.unreadable" 2>/dev/null)" = "{corrupt-user-config" ]' \
  "${J29_RUNJSON:-no run.json alert}"
check J29c "Failed New File in a read-only folder presents Couldn’t Create with permission denied" \
  'echo "$J29_CREATE" | grep -q "Couldn’t Create “blocked.go”" && echo "$J29_CREATE" | grep -qi "permission denied" && echo "$J29_CREATE" | grep -q "Try Again" && [ ! -e "$ERRPROJ/ro/blocked.go" ]' \
  "${J29_CREATE:-no create failure alert} — shots/j29-create-error-light.png, shots/j29-create-error-dark.png"

# ---- summary
KNOWN=$(grep -v '^#' "$HERE/known-failures.txt" 2>/dev/null | awk '{print $1}')
is_known() { echo "$KNOWN" | grep -qx "$1"; }
unexpected=0
ran=0
printf '\n%-5s %-6s  %s\n' ID RESULT CHECK
while IFS=$'\t' read -r id name status ev; do
  ran=$((ran + 1))
  shown=$status
  if [ "$status" = FAIL ]; then if is_known "$id"; then shown=KNOWN; else unexpected=$((unexpected + 1)); fi
  elif is_known "$id"; then shown="PASS*"; fi
  printf '%-5s %-6s  %s\n        %s\n' "$id" "$shown" "$name" "$ev"
done < "$RESULTS"
echo
echo "KNOWN = listed in known-failures.txt; PASS* = now passes, remove it from that list."
echo "Runtime: $(( $(date +%s) - START ))s. Artifacts: $ART"
if [ ! -s "$RESULTS" ] || [ "$ran" -eq 0 ]; then
  echo "No checks recorded in $RESULTS."
  exit 1
fi
[ $unexpected -eq 0 ] && echo "No unexpected failures." || echo "$unexpected unexpected failure(s)."
exit $([ $unexpected -eq 0 ] && echo 0 || echo 1)
