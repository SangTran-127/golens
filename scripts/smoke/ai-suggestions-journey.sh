#!/bin/bash
# AI Suggestions journey (J19): real app, loopback stub provider, in-process driver, no system events.
# Usage: scripts/smoke/ai-suggestions-journey.sh [path/to/GoLensApp] [--keep]
# Prefs live in the dev.golens.test.aicomplete domain; the Gopilot key is the in-memory dev key, never a real one.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=$REPO/.build/release/GoLensApp
KEEP=0
for a in "$@"; do case $a in --keep) KEEP=1 ;; *) BIN=$a ;; esac; done
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }

DOMAIN=dev.golens.test.aicomplete
PORT=${AI_STUB_PORT:-47231}
lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && { echo "port $PORT is busy; set AI_STUB_PORT"; exit 2; }
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
mkdir -p "$CONTAINER_DIR/tmp"
WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-ai.XXXXXX")" && pwd -P)
ART=${AI_ARTIFACTS:-$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-ai-artifacts.XXXXXX")" && pwd -P)}
mkdir -p "$ART/shots" "$ART/logs"
RESULTS=$ART/results.tsv
: > "$RESULTS"
APP_PID=
STUB_PID=
FAILED=0


others() { pgrep -f 'dev\.golens\.test.*GoLens\.app/Contents/MacOS' | grep -v -e "^$$\$" -e "^${APP_PID:-x}\$"; }
until [ -z "$(others)" ]; do echo "waiting for another GoLens test app to finish"; sleep 5; done

cleanup() {
  [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null && kill -TERM "$APP_PID" 2>/dev/null
  [ -n "$STUB_PID" ] && kill -TERM "$STUB_PID" 2>/dev/null
  sleep 1
  [ -n "$APP_PID" ] && kill -KILL "$APP_PID" 2>/dev/null
  [ -n "$STUB_PID" ] && kill -KILL "$STUB_PID" 2>/dev/null
  for k in $(lsof -ti tcp:$PORT -sTCP:LISTEN 2>/dev/null); do kill -TERM "$k" 2>/dev/null; done
  defaults delete $DOMAIN >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  [ $KEEP = 1 ] && echo "kept fixtures: $WORK" || rm -rf "$WORK"
  echo "artifacts: $ART"
}
trap cleanup EXIT INT TERM

BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
APP=$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/driver.dylib" "$HERE/driver.m" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/quiet.dylib" "$HERE/quiet-launch.m" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
(cd "$WORK" && go build -o "$WORK/completion-stub" "$HERE/completion-stub.go") || { echo "stub build failed"; exit 2; }
STUB_LOG=$ART/logs/stub.log
: > "$STUB_LOG"
"$WORK/completion-stub" -port "$PORT" -log "$STUB_LOG" -delay "${AI_STUB_DELAY:-150ms}" > "$ART/logs/stub.out" 2>&1 &
STUB_PID=$!
i=0; until grep -q listening "$ART/logs/stub.out" 2>/dev/null || [ $i -gt 50 ]; do sleep 0.1; i=$((i + 1)); done

FIX=$WORK/aiproj
mkdir -p "$FIX"
printf 'module example.com/aiproj\n\ngo 1.22\n' > "$FIX/go.mod"
cat > "$FIX/main.go" <<'EOF'
package main

import (
	"errors"
	"fmt"
	"sync"
)

var ErrNotFound = errors.New("not found")

type Store struct {
	mu   sync.RWMutex
	data map[string]string
}

func (s *Store) Len() int { return len(s.data) }

func add(a, b int) int {
}

func (s *Store) Lookup(k string) (string, error) {
}

func sub(a, b int) int {
	return a
}

func main() {
	s := &Store{data: map[string]string{}}
	fmt.Println()
	fmt.Println(add(1, 2))
}
EOF
printf 'API_TOKEN=abc123\n' > "$FIX/.env"
(cd "$FIX" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1

export GOPILOT_DEV_SEED_CONNECTED=1
export GOPILOT_DEV_BASE_URL="http://127.0.0.1:$PORT/v1"
export GOLENS_AI_SUGGESTIONS_DEV_ROUTES=1
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
export GOLENS_MEASURE=1

run() { # run <name> <file> <steps> [extra app args...]
  local name=$1 file=$2 steps=$3; shift 3
  local log=$ART/logs/$name.log
  DRIVE="$steps" DRIVE_OUT=$log DRIVE_SHOTS=$ART/shots DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
    "$APP" -GoLensLastWorkspacePath "$FIX" -GoLensLastFilePath "$file" "$@" > "$ART/logs/$name-app.log" 2>&1 &
  APP_PID=$!
  local i=0
  local quitting=0
  while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt 1500 ] && [ $quitting -lt 25 ]; do
    sleep 0.2; i=$((i + 1))
    grep -q "DRIVE quit" "$log" 2>/dev/null && quitting=$((quitting + 1))
  done
  if kill -0 "$APP_PID" 2>/dev/null; then
    [ $quitting -ge 25 ] || echo "$name: app did not finish its steps; stopping it"
    kill -TERM "$APP_PID"; sleep 1; kill -KILL "$APP_PID" 2>/dev/null
  fi
  APP_PID=
}

check() { # check <id> <description> <condition-command>
  if eval "$3" >/dev/null 2>&1; then echo "PASS $1 $2"; printf 'PASS\t%s\t%s\n' "$1" "$2" >> "$RESULTS"
  else echo "FAIL $1 $2"; printf 'FAIL\t%s\t%s\n' "$1" "$2" >> "$RESULTS"; FAILED=1; fi
}

requests() { grep -c ' POST ' "$STUB_LOG" 2>/dev/null || true; }

# ---- J19a: Settings page off, first-enable explanation, on with Test
defaults delete $DOMAIN >/dev/null 2>&1
run settings "$FIX/main.go" "wait:8;fakeactive;menu:GoLens/Settings…;wait:3;winsize:Settings|900;wait:1;mark:off;winlabels:Settings;\
lightmode;wait:0.8;winshot:Settings|settings-off-light;darkmode;wait:0.8;winshot:Settings|settings-off-dark;lightmode;wait:0.6;\
wintoggle:Settings|Suggest Code While Typing;wait:1.5;sheetshot:first-enable-light;darkmode;wait:0.8;sheetshot:first-enable-dark;lightmode;wait:0.6;\
sheetpress:Turn On;wait:1;mark:on;winpress:Settings|Test Suggestions;wait:3;mark:tested;winlabels:Settings;\
winshot:Settings|settings-on-light;darkmode;wait:0.8;winshot:Settings|settings-on-dark;lightmode;wait:0.4;quit" \
  -GoLensSettingsPane editor -GoLensSettingsPendingPage aiSuggestions -GoLensAICompletionRouteID mistralai/codestral-2508
L=$ART/logs/settings.log
check J19a "Settings ▸ AI Suggestions is off by default with toggle, model, request style, status and privacy copy naming the host" \
  "sed -n '/mark off/,/mark on/p' '$L' | grep 'winlabels' | grep -q 'Suggest Code While Typing' && sed -n '/mark off/,/mark on/p' '$L' | grep 'winlabels' | grep -q 'Request Style' && sed -n '/mark off/,/mark on/p' '$L' | grep -q '127.0.0.1'"
check J19b "Turning on asks first and explains what is sent" "grep -q 'sheetpress Turn On -> 1' '$L'"
check J19c "Test reports a working chat route through the stub" "sed -n '/mark tested/,\$p' '$L' | grep -q 'Responds in'"
check J19d "The first Test request reached the stub with a normal User-Agent" "grep -q 'ua=\"GoLens/' '$STUB_LOG'"

# ---- J19e-l: editor journey with suggestions on
defaults write $DOMAIN GoLensAICompletionEnabled -bool true
defaults write $DOMAIN GoLensAICompletionPrivacyAcknowledged -bool true
defaults write $DOMAIN GoLensAICompletionRouteID mistralai/codestral-2508
BEFORE=$(requests)
run editor "$FIX/main.go" "wait:10;fakeactive;wait:4;\
caret:fmt.Println(;mark:closers;menu:Editor/Show Suggestion;ghostwait:4;ghost;edited;undotitle;shot:ghost-closers-light;darkmode;wait:0.6;shot:ghost-closers-dark;lightmode;wait:0.4;\
key:cancelOperation:;ghost;mark:esc;key:insertTab:;line;ghost;undo;edited;\
mark:single;caret:func add(a, b int) int {;postkey:36;ghostwait:4;ghost;shot:ghost-single-light;darkmode;wait:0.6;shot:ghost-single-dark;lightmode;wait:0.4;\
postkey:48,\t;mark:accepted;ghost;line;edited;undotitle;undo;mark:undone;line;ghost;\
caret:	return a;menu:Editor/Show Suggestion;ghostwait:3;mark:through;ghost;type: ;ghost;type:x;wait:1.5;mark:diverged;ghost;\
mark:multi;caret:Lookup(k string) (string, error) {;code:\n;ghostwait:4;ghost;shot:ghost-multi-light;darkmode;wait:0.6;shot:ghost-multi-dark;lightmode;wait:0.4;\
key:insertTab:;mark:multi-accepted;line;edited;\
mark:gopls;caret:fmt.Println(add(1, 2));code:\n;type:fmt.Pri;wait:2.5;panel;ghost;key:insertTab:;line;mark:done;quit"
L=$ART/logs/editor.log
check J19e "On a clean file a suggestion shows without marking the window edited or adding an Undo step" \
  "sed -n '/mark closers/,/mark esc/p' '$L' | grep -q 'ghost visible' && sed -n '/mark closers/,/mark esc/p' '$L' | grep -q 'edited 0' && sed -n '/mark closers/,/mark esc/p' '$L' | grep -q 'canUndo=0'"
check J19f "Before closers the suggestion stops before the existing closing parenthesis" \
  "sed -n '/mark closers/,/mark esc/p' '$L' | grep -q 'ghost visible|[0-9]*|\"ready\", s.Len()\$'"
check J19g "Esc hides the suggestion and the next Tab indents" \
  "sed -n '/mark esc/,/mark single/p' '$L' | grep -q 'ghost hidden' && sed -n '/mark esc/,/mark single/p' '$L' | grep -q 'line: .*fmt.Println(	)'"
check J19h "A typing pause in a function body shows a single-line suggestion" \
  "sed -n '/mark single/,/mark accepted/p' '$L' | grep -q 'ghost visible|[0-9]*|return a + b'"
check J19i "Tab inserts exactly the drawn text with the caret after it, marks the window edited and is one Undo step named Accept Suggestion" \
  "sed -n '/mark accepted/,/mark undone/p' '$L' | grep -q 'line: .*	return a + b' && sed -n '/mark accepted/,/mark undone/p' '$L' | grep -q 'edited 1' && sed -n '/mark accepted/,/mark undone/p' '$L' | grep -q 'undotitle Accept Suggestion'"
check J19j "One Undo removes the accepted text and no suggestion comes back" \
  "sed -n '/mark undone/,/mark through/p' '$L' | grep -q 'line: func add(a, b int) int {⏎	⏎' && sed -n '/mark undone/,/mark through/p' '$L' | grep -q 'ghost hidden'"
check J19k "Typing matching characters keeps the rest of the suggestion; other typing hides it" \
  "sed -n '/mark through/,/mark diverged/p' '$L' | grep -q 'ghost visible|[0-9]*| - b' && sed -n '/mark through/,/mark diverged/p' '$L' | grep -q 'ghost visible|[0-9]*|- b' && sed -n '/mark diverged/,/mark multi/p' '$L' | grep -q 'ghost hidden'"
check J19l "A block body shows a multi-line suggestion that Tab inserts" \
  "sed -n '/mark multi/,/mark multi-accepted/p' '$L' | grep -q 'ghost visible|[0-9]*|s.mu.RLock()\\\\n\\\\tdefer' && sed -n '/mark multi-accepted/,/mark gopls/p' '$L' | grep -q 'return v, nil'"
check J19m "While the gopls completion list is open there is no suggestion and Tab commits the list" \
  "sed -n '/mark gopls/,/mark done/p' '$L' | grep -q 'panel visible' && sed -n '/mark gopls/,/mark done/p' '$L' | grep -q 'ghost hidden' && sed -n '/mark gopls/,/mark done/p' '$L' | grep -q 'line: .*fmt.Print'"
AFTER_EDITOR=$(requests)

# ---- J19p: fill-in-the-middle request style through /completions with the suffix parameter
defaults write $DOMAIN GoLensAICompletionRouteID text-completion-codestral/codestral-latest
BEFORE=$(requests)
run fim "$FIX/main.go" "wait:10;fakeactive;wait:3;caret:fmt.Println(;menu:Editor/Show Suggestion;ghostwait:4;mark:fim-ghost;ghost;\
menu:GoLens/Settings…;wait:3;winsize:Settings|900;wait:1;winpress:Settings|Test Suggestions;wait:3;mark:fim-tested;winlabels:Settings;\
lightmode;wait:0.6;winshot:Settings|settings-fim-light;darkmode;wait:0.8;winshot:Settings|settings-fim-dark;lightmode;wait:0.4;quit" \
  -GoLensSettingsPane editor -GoLensSettingsPendingPage aiSuggestions
L=$ART/logs/fim.log
check J19p "Fill-in-the-Middle sends prefix and suffix to /completions and shows the suggestion" \
  "grep -q 'POST /v1/completions model=text-completion-codestral/codestral-latest stream=true suffix=true case=closers' '$STUB_LOG' && sed -n '/mark fim-ghost/,/mark fim-tested/p' '$L' | grep -q 'ghost visible|[0-9]*|\"ready\", s.Len()\$'"
check J19q "Test confirms that the code after the cursor is used" "sed -n '/mark fim-tested/,\$p' '$L' | grep -q 'Code after the cursor is used'"
defaults write $DOMAIN GoLensAICompletionRouteID openai/qwen2.5-coder-0.5b-base
run fimraw "$FIX/main.go" "wait:10;fakeactive;wait:3;caret:fmt.Println(;menu:Editor/Show Suggestion;ghostwait:4;mark:raw-ghost;ghost;\
menu:GoLens/Settings…;wait:3;winsize:Settings|900;wait:1;winpress:Settings|Test Suggestions;wait:3;mark:raw-tested;winlabels:Settings;\
winshot:Settings|settings-fim-raw-light;quit" -GoLensSettingsPane editor -GoLensSettingsPendingPage aiSuggestions
L=$ART/logs/fimraw.log
check J19r "A Qwen raw template route sends the template in the prompt without a suffix parameter and shows the suggestion" \
  "grep -q 'POST /v1/completions model=openai/qwen2.5-coder-0.5b-base stream=true suffix=false case=closers' '$STUB_LOG' && sed -n '/mark raw-ghost/,/mark raw-tested/p' '$L' | grep -q 'ghost visible|[0-9]*|\"ready\", s.Len()\$' && sed -n '/mark raw-tested/,\$p' '$L' | grep -q 'FIM Template \\[Qwen2.5-Coder\\]'"
defaults write $DOMAIN GoLensAICompletionRouteID mistralai/codestral-2508

# ---- J19n: a .env file never produces a request
BEFORE=$(requests)
run envfile "$FIX/.env" "wait:9;fakeactive;caret:abc123;code:\n;type:X=1;wait:2;ghost;quit"
check J19n "Typing in .env sends nothing" "[ \"\$(requests)\" = \"$BEFORE\" ]"

# ---- J19o: with the setting off nothing is sent
defaults write $DOMAIN GoLensAICompletionEnabled -bool false
BEFORE=$(requests)
run off "$FIX/main.go" "wait:9;fakeactive;caret:func add(a, b int) int {;code:\n;wait:2;ghost;menu:Editor/Show Suggestion;wait:1.5;ghost;quit"
check J19o "With AI Suggestions off typing sends nothing" "[ \"\$(requests)\" = \"$BEFORE\" ]"

echo "== stub requests"
cat "$STUB_LOG"
echo "== latency (app measure log)"
grep -h "ai suggestion" "$ART"/logs/*-app.log | head -20
echo "== editor driver log"
grep -E "DRIVE (mark|ghost|line|edited|undotitle|panel|menu Editor)" "$ART/logs/editor.log" | cut -c1-200
exit $FAILED
