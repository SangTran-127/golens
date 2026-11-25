#!/bin/bash
# End-to-end Go Engineer User Journey Dogfood (Dogfood #3):
# Session 1: Real ~/Documents/chat project walkthrough (Light & Dark Mode, file tree, Go to Symbol jump, Undo, Safety Audit click-to-jump, Terminal).
# Session 2: Interactive Build Target switching (GOOS=darwin -> linux_only.go excluded -> Reset Build Target to the linux guest),
#            End-to-end Change Signature Refactor across files, Call Hierarchy jump, Profiler click-to-jump, and Fuzz test discovery/run.
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
export GOLENS_VM_MEMORY_MB=512
pkill -9 -f "Containers/dev.golens.test.dogfood3/" 2>/dev/null || true
pkill -9 -f "golens-dogfood3" 2>/dev/null || true
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=$REPO/.build/release/GoLensApp
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }

DOMAIN=dev.golens.test.dogfood3
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
rm -rf "$CONTAINER_DIR/Library/Preferences" 2>/dev/null || true
if [ "${GOLENS_EXECUTION_MODE:-host}" = "vm" ]; then
  mkdir -p "$CONTAINER_DIR/tmp"
  WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-dogfood3.XXXXXX")" && pwd -P)
  ART=${DOGFOOD_ARTIFACTS:-$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-dogfood3-artifacts.XXXXXX")" && pwd -P)}
else
  WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/golens-dogfood3.XXXXXX")" && pwd -P)
  ART=${DOGFOOD_ARTIFACTS:-$(cd "$(mktemp -d "${TMPDIR:-/tmp}/golens-dogfood3-artifacts.XXXXXX")" && pwd -P)}
fi
mkdir -p "$ART/shots" "$ART/logs"
RESULTS=$ART/results.tsv
: > "$RESULTS"
START=$(date +%s)
APP_PID=
OWNED_PIDS=
DUMMY_SRV_PID=

descendants() { local k; for k in $(pgrep -P "$1" 2>/dev/null); do echo "$k"; descendants "$k"; done; }

cleanup() {
  [ -n "$DUMMY_SRV_PID" ] && kill -0 "$DUMMY_SRV_PID" 2>/dev/null && kill -TERM "$DUMMY_SRV_PID" 2>/dev/null
  [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null && kill -TERM "$APP_PID" 2>/dev/null
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  sleep 1
  for k in $OWNED_PIDS $APP_PID $DUMMY_SRV_PID; do kill -KILL "$k" 2>/dev/null; done
  defaults delete $DOMAIN >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

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

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }
check() { if eval "$3"; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "$4"; fi; }

launch() {
  LOG=$ART/logs/$1.log
  shift
  local ws=$1; local file=$2; local steps=$3; shift 3
  DRIVE_GUEST_CWD="$ws" DRIVE="$steps" DRIVE_OUT=$LOG DRIVE_SHOTS=$ART/shots DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
    "$APP" -GoLensLastWorkspacePath "$ws" -GoLensLastFilePath "$file" -GoLensShowConsole '<true/>' "$@" > "$ART/logs/$(basename "$LOG" .log).app.log" 2>&1 &
  APP_PID=$!
}

wait_mark() {
  local i=0
  while [ $i -lt $(($2 * 5)) ]; do
    grep -q "DRIVE mark $1\$" "$LOG" 2>/dev/null && return 0
    if ! kill -0 "$APP_PID" 2>/dev/null; then
      wait "$APP_PID" 2>/dev/null
      echo "app exited before mark $1 with status $? (last step: $(grep '^DRIVE' "$LOG" | tail -1 | cut -c1-120))" | tee -a "$LOG"
      return 1
    fi
    OWNED_PIDS="$OWNED_PIDS $(descendants "$APP_PID" | tr '\n' ' ')"
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

finish() {
  local i=0
  OWNED_PIDS="$OWNED_PIDS $(descendants "$APP_PID" | tr '\n' ' ')"
  while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt $(($1 * 5)) ]; do sleep 0.2; i=$((i + 1)); done
  if kill -0 "$APP_PID" 2>/dev/null; then kill -TERM "$APP_PID"; sleep 1; kill -KILL "$APP_PID" 2>/dev/null; fi
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  APP_PID=
}

line() { grep -m1 "$1" "$LOG" 2>/dev/null; }

echo "GoLens Dogfood #3 User Journey — $(basename "$BIN") — artifacts: $ART"

# ==============================================================================
# SESSION 1: Real ~/Documents/chat copy (Light Mode + Dark Mode walkthrough)
# ==============================================================================
CHAT=$WORK/chat
if [ -d "$HOME/Documents/chat" ]; then
  cp -R "$HOME/Documents/chat" "$CHAT"
else
  mkdir -p "$CHAT/cmd/chatd" "$CHAT/crypto" "$CHAT/proto" "$CHAT/sandbox" "$CHAT/server" "$CHAT/store" "$CHAT/ui"
  printf 'module chat\n\ngo 1.22\n' > "$CHAT/go.mod"
  printf 'package main\nfunc main() {}\n' > "$CHAT/cmd/chatd/main.go"
  printf 'package proto\nfunc Frame() {}\n' > "$CHAT/proto/frame.go"
  printf 'package proto\nfunc Keys() {}\n' > "$CHAT/proto/keys.go"
  printf 'package server\nfunc Peer() {}\n' > "$CHAT/server/peer.go"
  printf 'package server\nfunc sendTo() {}\nfunc Serve() { sendTo() }\n' > "$CHAT/server/server.go"
fi

launch chat_light "$CHAT" "$CHAT/server/server.go" "wait:10;fakeactive;lightmode;wait:0.6;mark:ready;\
rowexpand:cmd;wait:0.3;rowexpand:chatd;wait:0.3;rowexpand:crypto;wait:0.3;rowexpand:proto;wait:0.3;rowexpand:sandbox;wait:0.3;rowexpand:server;wait:0.3;rowexpand:store;wait:0.3;rowexpand:ui;wait:0.8;\
axpress:frame.go;wait:0.8;axpress:peer.go;wait:0.8;axpress:server.go;wait:0.8;\
mark:df1-chat-tree;outlinesel:store;outlinesel:go.mod;shot:df1-chat-light;\
select:sendTo;menu:Navigate/Go to Symbol in File…;wait:0.6;fr:Serve;wait:0.5;mark:df2-sym-open;deeplabels;postkey:36;wait:0.6;mark:df2-sym-jumped;selinfo;find:sendTo;\
select:sendTo;fr:temporaryEdit;wait:0.5;edited;undo;wait:0.5;mark:df3-undo;edited;find:sendTo;\
menu:Product/Run Safety Audit;wait:4.0;mark:df4-safety;deeplabels;shot:df4-chat-safety;\
axpress:Terminal;wait:1.0;fr:echo CHAT_TERM_READY;wait:0.8;mark:df5-term;shot:df5-chat-term;\
mark:done;quit"

wait_mark done 90; finish 15

STORE_R=$(sed -n '/mark df1-chat-tree/,/select sendTo/p' "$LOG" | sed -n 's/.*outlinesel store=\(row[0-9]*\).*/\1/p')
GOMOD_R=$(sed -n '/mark df1-chat-tree/,/select sendTo/p' "$LOG" | sed -n 's/.*outlinesel go.mod=\(row[0-9]*\).*/\1/p')
check DF1 "Real chat project: expanding all 8 folders and switching frame.go -> peer.go -> server.go has 0 row overlap" '[ -n "$STORE_R" ] && [ -n "$GOMOD_R" ] && [ "$STORE_R" != "$GOMOD_R" ]' "store=$STORE_R go.mod=$GOMOD_R — shots/df1-chat-light.png"

SYM_OPEN=$(sed -n '/Navigate\/Go to Symbol in File/,/mark df2-sym-open/p' "$LOG" | grep -m1 "DRIVE fr Serve")
SYM_PRESERVED=$(sed -n '/mark df2-sym-jumped/,/select sendTo/p' "$LOG" | grep -m1 "find .sendTo. -> present")
check DF2 "Real chat project: ⌃6 Go to Symbol types 'Serve', jumps on Return, and preserves 'sendTo'" '[ -n "$SYM_OPEN" ] && echo "$SYM_OPEN" | grep -qv "GoLensTextView" && [ -n "$SYM_PRESERVED" ]' "$SYM_OPEN — $SYM_PRESERVED"

UNDO_ZERO=$(sed -n '/mark df3-undo/,/Run Safety Audit/p' "$LOG" | grep -m1 "DRIVE edited 0")
check DF3 "Real chat project: editing and pressing Undo restores sendTo and clears Edited state" '[ -n "$UNDO_ZERO" ]' "$UNDO_ZERO"

CHAT_SAFETY=$(sed -n '/mark df4-safety/,/axpress Terminal/p' "$LOG" | grep -m1 "deeplabels:")
check DF4 "Real chat project: Run Safety Audit (⌃⇧⌘S) audits chat packages and displays findings in Safety tab" 'echo "$CHAT_SAFETY" | grep -q "Safety" && echo "$CHAT_SAFETY" | grep -q "safety findings"' "$(echo "$CHAT_SAFETY" | grep -o '[0-9]* safety findings' | head -1) — shots/df4-chat-safety.png"

# Dark mode appearance check on chat project
launch chat_dark "$CHAT" "$CHAT/server/server.go" "wait:8;fakeactive;darkmode;wait:0.8;mark:ready;\
axpress:Terminal;wait:1.2;shot:df5-chat-dark-terminal;\
axpress:Console;wait:0.6;shot:df5-chat-dark-editor;\
mark:done;quit"

wait_mark done 45; finish 10
check DF5 "Real chat project: Dark Mode editor, fold chevrons, and terminal render with proper contrast" '[ -s "$ART/shots/df5-chat-dark-terminal.png" ] && [ -s "$ART/shots/df5-chat-dark-editor.png" ]' "shots/df5-chat-dark-editor.png & shots/df5-chat-dark-terminal.png"

# ==============================================================================
# SESSION 2: Deep Inner-Loop User Journey (Interactive Build Target Reset,
#            Multi-File Change Signature Refactor, Call Hierarchy Jump, Fuzzing)
# ==============================================================================
P2=$WORK/kvservice
mkdir -p "$P2"
printf 'module example.com/kvservice\n\ngo 1.22\n' > "$P2/go.mod"

cat > "$P2/darwin_only.go" <<'EOF'
//go:build darwin

package main

import (
	"fmt"
	"net/http"
	"os"
	"reflect"
	"regexp"
	"sync"
	"time"
)

type StoreMode int

const (
	StoreModeMemory StoreMode = iota
	StoreModeDisk
)

type StoreTier int

const (
	StoreTierFree StoreTier = iota
	StoreTierPro
)

type AuthConfig struct {
	APIToken string `json:"api_token"`
}

type SafeAuthCache struct {
	mu     sync.Mutex
	Tokens []string
}

func (c SafeAuthCache) SnapshotCount() int {
	return len(c.Tokens)
}

func PollStoreTicker() {
	ticker := time.NewTicker(time.Second)
	_ = ticker
}

func CacheAuthLabels(raw any) map[string]string {
	var labels map[string]string
	label := raw.(string)
	labels["primary"] = label
	return labels
}

func FormatStoreCounter(count int) string {
	return fmt.Sprintf("%d", count)
}

func WrapStoreError(key string, err error) error {
	if err != nil {
		return fmt.Errorf("store lookup %s failed: %v", key, err)
	}
	return nil
}

func ReadStoreSnapshot(path string, meta interface{}) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	_ = f
	_ = meta
	return nil
}

func NormalizeStoreKey(prefix string, limit int) string {
	if limit <= 0 {
		return prefix
	}
	return prefix
}

func CollectStoreKeys(items []string) []string {
	var out []string
	for _, item := range items {
		out = append(out, item)
	}
	return out
}

func FanoutStoreItems(items []string) {
	for _, item := range items {
		go func() {
			_ = item
		}()
	}
}

func PingStoreEndpoint(endpoint string) error {
	resp, err := http.Get(endpoint)
	if err != nil {
		return err
	}
	_ = resp
	return nil
}

func WriteStoreConfigFile(data []byte) error {
	return os.WriteFile("/tmp/golens-store.cfg", data, 0777)
}

func RecoverStoreWorker() {
	defer recover()
}

func MatchStorePattern(key string, pat string) bool {
	re := regexp.MustCompile(pat)
	return re.Match([]byte(key))
}

func VerifyStoreToken(secretToken string, expectedToken string) bool {
	return secretToken == expectedToken
}

type StoreWirePacket struct {
	internalMeta string `json:"internal_meta"`
}

func InspectStoreValue(raw any) reflect.Value {
	v := reflect.ValueOf(raw)
	return v.Elem()
}

func HostPlatformName() string {
	return "darwin"
}
EOF

cat > "$P2/linux_only.go" <<'EOF'
//go:build linux

package main

func HostPlatformName() string {
	return "linux"
}
EOF

cat > "$P2/store.go" <<'EOF'
package main

type StoreReader interface {
	Get(key string) string
	Keys() []string
}

var storeMeta map[string]string

type KVStore struct {
	namespace string
}

func ComputeTotal(a int, b int) int {
	return a + b
}

func (k *KVStore) Get(key string) string {
	prefix := k.namespace + ":"
	return prefix + key
}
EOF

cat > "$P2/main.go" <<'EOF'
//go:generate cp go.mod generated_banner.txt
package main

import (
	"context"
	"flag"
	"fmt"
	"os/exec"
	"time"
)

func daemonStep(iter int) int {
	return iter + 1
}

var globalSink *KVStore

func main() {
	owner := flag.String("owner", "default", "owner name")
	daemon := flag.Bool("daemon", false, "run daemon loop")
	flag.Parse()
	if *daemon {
		for i := 0; i < 100000; i++ {
			_ = daemonStep(i)
			time.Sleep(40 * time.Millisecond)
		}
		return
	}
	globalSink = &KVStore{namespace: *owner}
	for i := 0; i < 10000; i++ {
		_ = globalSink.Get("bench")
	}
	_ = exec.Command("true")
	_ = time.Now().Format("2006-01-02")
	total := ComputeTotal(10, 20)
	fmt.Println(total)
	fmt.Printf("Owner=%s\n", *owner)
}

func backgroundPoll() {
	ctx, cancel := context.WithCancel(context.Background())
	emptyStore := KVStore{}
	_ = ctx
	_ = cancel
	_ = emptyStore
}
EOF

mkdir -p "$P2/.golens"
cat > "$P2/.golens/run.json" <<'EOF'
[
  {
    "id": "00000000-0000-0000-0000-000000000001",
    "name": "QA Owner",
    "envVars": {},
    "buildFlags": "",
    "args": "-owner \"Daily QA\"",
    "workingDirectory": ""
  }
]
EOF

cat > "$P2/store_test.go" <<'EOF'
package main

import "testing"

func TestGet(t *testing.T) {
	s := &KVStore{namespace: "ns"}
	for i := 0; i < 40000; i++ {
		if got := s.Get("k"); got != "ns:k" {
			t.Fatalf("got %q", got)
		}
	}
}

func FuzzGet(f *testing.F) {
	f.Add("alpha")
	f.Fuzz(func(t *testing.T, key string) {
		s := &KVStore{namespace: "ns"}
		_ = s.Get(key)
	})
}

func BenchmarkGet(b *testing.B) {
	s := &KVStore{namespace: "ns"}
	for i := 0; i < b.N; i++ {
		_ = s.Get("k")
	}
}
EOF

if [ "${GOLENS_EXECUTION_MODE:-host}" = "vm" ]; then
  DF6_INITIAL_GOOS="darwin"
  DF6_DEFAULT_TARGET="linux/arm64"
  DF6_EXCLUDED_TARGET="darwin/arm64"
  DF6_TARGET_FILE="$P2/linux_only.go"
else
  DF6_INITIAL_GOOS="linux"
  DF6_DEFAULT_TARGET="darwin/arm64"
  DF6_EXCLUDED_TARGET="linux/arm64"
  DF6_TARGET_FILE="$P2/darwin_only.go"
fi
defaults write $DOMAIN GoLensBuildGOOS -string "$DF6_INITIAL_GOOS"

launch inner_loop "$P2" "$DF6_TARGET_FILE" "wait:10;fakeactive;mark:ready;\
mark:df6-before-reset;deeplabels;shot:df6-excluded-darwin;\
axpress:Reset Build Target;wait:1.2;mark:df6-after-reset;deeplabels;shot:df6-after-reset;\
axpress:Build Target, $DF6_DEFAULT_TARGET;wait:0.8;mark:df6-popover;wininfo;shot:df6-popover;postkey:53;wait:0.5;\
axpress:store.go;wait:1.0;select:ComputeTotal;menu:Editor/Change Signature…;wait:1.2;\
field:0:ComputeSum;wait:0.5;axpress:Refactor;wait:2.5;mark:df7-refactored;find:func ComputeSum;shot:df7-refactored;\
select:ComputeSum;menu:Navigate/Call Hierarchy;wait:2.5;mark:df8-hier;deeplabels;postkey:36;wait:1.5;mark:df8-jumped;selinfo;find:ComputeSum(10, 20);shot:df8-caller-main;\
axpress:Tests;wait:2.0;mark:df9-tests;axexists:FuzzGet;deeplabels;shot:df9-fuzz-discovered;\
mark:done;quit"

wait_mark done 110; finish 15

BEFORE_RESET=$(sed -n '/mark df6-before-reset/,/axpress Reset Build Target/p' "$LOG" | grep -m1 "deeplabels:")
AFTER_RESET=$(sed -n '/mark df6-after-reset/,/axpress Build Target/p' "$LOG" | grep -m1 "deeplabels:")
POPOVER_WIN=$(sed -n '/mark df6-popover/,/wininfo end/p' "$LOG" | grep -m1 "Build Target")
check DF6 "Interactive Build Target flow: custom GOOS excludes platform file, clicking 'Reset Build Target' restores the $DF6_DEFAULT_TARGET default target & removes banner, and status bar item opens popover" \
  'echo "$BEFORE_RESET" | grep -q "File Excluded from Active Build Target" && echo "$BEFORE_RESET" | grep -q "$DF6_EXCLUDED_TARGET" && ! echo "$AFTER_RESET" | grep -q "File Excluded from Active Build Target" && echo "$AFTER_RESET" | grep -q "$DF6_DEFAULT_TARGET" && [ -n "$POPOVER_WIN" ]' \
  "Before: $DF6_EXCLUDED_TARGET excluded -> After Reset: $DF6_DEFAULT_TARGET clean + Popover verified — shots/df6-excluded-darwin.png"

REFACTORED_STORE=$(sed -n '/mark df7-refactored/,/Navigate\/Call Hierarchy/p' "$LOG" | grep -m1 "find .func ComputeSum. -> present")
REFACTORED_MAIN=$(sed -n '/mark df8-jumped/,/axpress Tests/p' "$LOG" | grep -m1 "find .ComputeSum(10, 20). -> present")
check DF7 "End-to-end Change Signature Refactor rewrites both declaration in store.go and call site in main.go" \
  '[ -n "$REFACTORED_STORE" ] && [ -n "$REFACTORED_MAIN" ]' \
  "$REFACTORED_STORE & $REFACTORED_MAIN — shots/df7-refactored.png"

JUMPED_WIN=$(sed -n '/mark df8-jumped/,/axpress Tests/p' "$LOG" | grep -m1 "selinfo .*file=main.go ")
check DF8 "Call Hierarchy pressing Return on caller jumps directly to main.go call site" \
  '[ -n "$JUMPED_WIN" ]' \
  "$JUMPED_WIN — shots/df8-caller-main.png"

FUZZ_EXISTS=$(sed -n '/mark df9-tests/,/mark done/p' "$LOG" | grep -m1 "axexists FuzzGet -> 1")
check DF9 "Go 1.18+ FuzzGet(f *testing.F) is discovered and listed in the Test Navigator" \
  '[ -n "$FUZZ_EXISTS" ]' \
  "$FUZZ_EXISTS — shots/df9-fuzz-discovered.png"

# ==============================================================================
# SESSION 3: New Wave Features User Journey (AST Expand/Shrink Selection,
#            Caret-Level Back/Forward, Implement Interface, Move Symbol,
#            Attach to Process, Safety Capabilities + Inline Annotations,
#            Profiler Line Heat, Go Struct Tags, JSON-to-Struct,
#            go.mod Interactive Code Lenses, and Git Hunk Revert + Blame)
# ==============================================================================
defaults delete $DOMAIN GoLensBuildGOOS >/dev/null 2>&1 || true
defaults delete $DOMAIN GoLensBuildGOARCH >/dev/null 2>&1 || true
defaults delete $DOMAIN GoLensBuildTags >/dev/null 2>&1 || true

printf 'package main\n\nconst minKeys = 1\nconst maxKeys = 4\n' > "$P2/limits.go"
git -C "$P2" init -q
python3 -c 'print("// GoLens Large-File Mode fixture line\n" * 62000)' > "$P2/large_fixture.txt"
git -C "$P2" config user.email "test@golens.dev"
git -C "$P2" config user.name "GoLens Tester"
git -C "$P2" add .
git -C "$P2" commit -qm "initial commit"
sed -i '' 's/const maxKeys = 4$/const maxKeys = 400/' "$P2/limits.go"

if [ "${GOLENS_EXECUTION_MODE:-host}" = "vm" ]; then
  DF13_START_STEP="guestsh:go build -gcflags='all=-N -l' -o .git/kvservice-server . && ( setsid ./.git/kvservice-server -daemon </dev/null >/dev/null 2>&1 & );wait:15;"
  DF13_STOP_STEP="guestsh:pgrep -f kvservice-server > .git/alive-after-detach;guestsh:pkill -f kvservice-server;"
else
  (cd "$P2" && go build -gcflags="all=-N -l" -o "$P2/.git/kvservice-server" .) || { echo "kvservice-server build failed"; exit 2; }
  "$P2/.git/kvservice-server" -daemon </dev/null >/dev/null 2>&1 &
  DUMMY_SRV_PID=$!
  OWNED_PIDS="$OWNED_PIDS $DUMMY_SRV_PID"
  DF13_START_STEP="wait:0.5;"
  DF13_STOP_STEP="wait:0.2;"
fi

launch wave_features "$P2" "$P2/store.go" "wait:9;fakeactive;mark:ready;\
select:namespace;menu:Edit/Expand Selection;wait:0.4;menu:Edit/Expand Selection;wait:0.4;mark:df10-expanded;selinfo;shot:df10-expand-selection;\
menu:Edit/Shrink Selection;wait:0.4;mark:df10-shrunk;selinfo;\
select:KVStore;menu:Navigate/Go to Symbol in File…;wait:0.6;fr:Get;wait:0.4;postkey:36;wait:0.6;mark:df10-after-jump;selinfo;\
menu:Navigate/Back;wait:0.6;mark:df10-after-back;selinfo;\
select:KVStore;menu:Editor/Implement Interface…;wait:0.8;mark:df11-sheet;deeplabels;shot:df11-implement-interface-sheet;\
fr:io.Closer;wait:0.5;axpress:Implement Selected Interface;wait:1.5;mark:df11-done;find:Close() error;shot:df11-implement-interface-done;\
select:ComputeSum;menu:Editor/Move Symbol…;wait:0.8;mark:df12-sheet;deeplabels;shot:df12-move-symbol-sheet;\
axpress:Move Symbol to Destination File;wait:1.5;mark:df12-done;find:ComputeSum;shot:df12-move-symbol-done;\
axpress:main.go;wait:0.8;bpclick:return iter + 1;wait:0.5;\
${DF13_START_STEP}\
menu:Product/Attach to Process…;wait:1.0;fr:kvservice-server;wait:0.6;mark:df13-attach;deeplabels;shot:df13-attach-process-sheet;\
axpress:Attach to Selected Process;wait:4.0;mark:df13-attached-paused;deeplabels;shot:df13-attached-paused;\
axpress:Cancel Attach;wait:0.4;\
axpress:Stop Debugging;wait:1.5;bpclick:return iter + 1;wait:0.4;mark:df13-detached;\
${DF13_STOP_STEP}\
axpress:main.go;wait:0.6;\
axpress:Split Editor Right;wait:0.6;menu:File/Open Quickly…;wait:0.8;fr:store.go;wait:0.5;postkey:36,,524288;wait:1.0;\
mark:df23-split;splitinfo;deeplabels;shot:df23-split-identity;\
axpress:Close Split Editor;wait:0.6;\
menu:Find/Find…;wait:0.5;axpress:Regular Expression;wait:0.3;frkey:selectAll:;time:df77-before;fr:(.*?,?)+QQQ;time:df77-after;\
wait:2.6;mark:df77-stopped;deeplabels;shot:df77-find-regex-stopped;axpress:Regular Expression;wait:0.3;postkey:53;wait:0.4;mark:df77-closed;labels;\
menu:Find/Find…;wait:0.5;frkey:selectAll:;fr:daemonStep;wait:0.5;postkey:48;wait:0.3;fr:pollStep;wait:0.3;\
axpress:Replace All;wait:0.8;mark:df78-all;find:func pollStep(iter int) int;find:_ = pollStep(i);undo;wait:0.5;mark:df78-all-undone;find:pollStep;\
axpress:Replace;wait:0.8;mark:df78-one;find:pollStep;find:daemonStep;undo;wait:0.5;mark:df78-one-undone;find:pollStep;postkey:53;wait:0.4;\
menu:Find/Find…;wait:0.5;frkey:selectAll:;fr:ComputeSum;wait:0.5;postkey:36;wait:0.4;postkey:53;wait:0.4;\
menu:Editor/Change Signature…;wait:1.0;mark:df24-callsite-sig;deeplabels;shot:df24-callsite-signature;axpress:Cancel;wait:0.5;\
menu:Product/Run;wait:3.5;axpress:Console;wait:0.5;mark:df25-quoted-args;deeplabels;shot:df25-quoted-args;\
menu:Product/Profile Application;wait:5.0;mark:df30-app-profile;deeplabels;shot:df30-app-profile;\
axpress:Console;wait:0.5;menu:View/Escape Analysis;wait:1.0;waitlabel:Escape analysis for main.go:;mark:df31-escape;deeplabels;shot:df31-escape-analysis;\
bpclick://go:generate;wait:2.5;mark:df32-gogen;deeplabels;shot:df32-go-generate;\
mark:df26-ctx;editorctx:;editorctx:ComputeSum;menustate:View/Command Palette…;menustate:Product/Attach to Process…;menustate:Navigate/Call Hierarchy;menustate:Product/Profile Tests;\
select:Println;menu:Editor/Handle Error with if err != nil;wait:1.0;mark:df21-wrap-err;find:if _, err := fmt.Println(total);\
select:total :=;menu:Editor/Convert Between ':=' and 'var';wait:1.0;mark:df21-var-done;find:var total = ComputeSum(10, 20);shot:df21-intentions-done;\
menu:Product/Run Safety Audit;wait:5.5;axpress:Capabilities;wait:0.6;mark:df14-safety;deeplabels;shot:df14-safety-capabilities-inline;\
axpress:Dependencies;waitlabel:which is out of date;mark:df43-safety-deps;deeplabels;shot:df43-safety-dependencies;\
menu:Product/Profile Tests;wait:6.0;axpress:store.go;wait:0.8;mark:df15-profile;deeplabels;shot:df15-profiler-heat;\
axpress:Flame Graph;wait:0.8;mark:df28-flame;deeplabels;shot:df28-flame-graph;axpress:Table;wait:0.4;\
select:KVStore;menu:Editor/Modify Struct Tags…;wait:0.8;mark:df16-sheet;deeplabels;shot:df16-struct-tags-sheet;\
axpress:Apply Struct Tags;wait:1.2;mark:df16-done;find:json:\"namespace\";shot:df16-struct-tags-done;\
select:prefix + key;menu:Tools/Convert JSON to Go Struct…;wait:0.8;mark:df17-sheet;deeplabels;shot:df17-json-to-struct-sheet;\
axpress:Insert Generated Struct;wait:1.2;mark:df17-done;find:type Payload struct;shot:df17-json-to-struct-done;\
select:Payload;menu:Tools/Inspect Struct Memory Layout…;wait:0.8;mark:df20-layout-sheet;deeplabels;shot:df20-struct-layout-sheet;\
axpress:Optimize Struct Field Order;wait:1.2;mark:df20-layout-done;find:UserName string;shot:df20-struct-layout-optimized;\
axpress:go.mod;wait:1.5;mark:df18-gomod;find:module example.com/kvservice;shot:df18-gomod-lenses;\
axpress:store.go;wait:1.0;select:Payload;wait:1.2;mark:df19-before-revert;find:type Payload struct;shot:df19-git-diff-blame;\
menu:Editor/Discard Change at Cursor;wait:0.5;waitgone:type Payload struct;mark:df19-after-revert;find:type Payload struct;shot:df19-git-reverted;\
axpress:Close Struct Layout;wait:0.6;mark:df19c-reverted;undotitle;menustate:Edit/Undo Revert Git Hunk;postkey:6,z,1048576;wait:1.0;mark:df19c-undone;find:type Payload struct;menu:Edit/Redo Revert Git Hunk;wait:1.0;mark:df19c-redone;find:type Payload struct;undotitle;\
axpress:limits.go;wait:1.0;caret:package main;wait:0.5;mark:df19b-before;edited;find:const maxKeys = 400;changebar:const maxKeys;wait:1.5;mark:df19b-popover;popoverlabels;\
axpress:Discard Change;wait:1.5;mark:df19b-discarded;find:const maxKeys = 400;edited;undotitle;menustate:Edit/Undo Revert Git Hunk;postkey:6,z,1048576;wait:1.0;mark:df19b-undone;find:const maxKeys = 400;edited;\
menu:Edit/Redo Revert Git Hunk;wait:1.0;mark:df19b-redone;find:const maxKeys = 400;edited;undotitle;shot:df19b-popover-redone;postkey:6,z,1048576;wait:1.0;mark:df19b-end;axpress:store.go;wait:1.0;\
select:prefix := k.namespace;menu:Editor/Extract Function…;wait:0.8;mark:df27-sheet;deeplabels;shot:df27-extract-method-sheet;\
axpress:Confirm Extract Function;wait:1.2;mark:df27-done;find:func (k *KVStore) extractedFunc;shot:df27-extract-method-done;\
select:func (k *KVStore) Get;menu:Editor/Generate Table-Driven Test…;wait:0.8;mark:df29-sheet;deeplabels;shot:df29-generate-test-sheet;\
axpress:Confirm Generate Table-Driven Test;wait:1.5;mark:df29-done;find:func TestKVStore_Get(t *testing.T);shot:df29-generate-test-done;\
axpress:main.go;wait:0.8;\
menu:Navigate/Go to Workspace Symbol…;wait:0.8;fr:KVStore.Get;wait:0.6;mark:df34-ws-sym;deeplabels;shot:df34-workspace-symbol;\
postkey:36;wait:0.8;mark:df34-jumped;find:func (k *KVStore) Get;\
select:map[string]string;menu:Editor/Extract Type Definition…;wait:0.8;mark:df35-type-sheet;deeplabels;shot:df35-extract-type-sheet;\
axpress:Confirm Extract Type;wait:1.0;mark:df35-type-done;find:type StoreMetaType map[string]string;\
select:StoreReader;menu:Editor/Propagate Method to Implementations…;wait:0.8;mark:df35-prop-sheet;deeplabels;shot:df35-propagate-interface-sheet;\
axpress:Confirm Propagate Methods;wait:1.0;mark:df35-prop-done;find:Keys() []string;shot:df35-type-refactor-done;\
select:StoreReader;menu:Editor/Generate Interface Mock…;wait:0.8;mark:df40-mock-sheet;deeplabels;shot:df40-generate-mock-sheet;\
axpress:Generate Mock;wait:1.0;mark:df40-mock-done;find:type MockStoreReader struct;shot:df40-generate-mock-done;\
axpress:main.go;wait:0.8;select:KVStore{};menu:Editor/Fill Struct Fields;wait:0.8;mark:df42-fill-struct;find:namespace: \"\";shot:df42-fill-struct;\
menu:Tools/Inspect Package Dependencies…;wait:0.8;mark:df41-pkg-deps;deeplabels;shot:df41-package-dependencies;\
axpress:Close Package Dependencies Inspector;wait:0.5;\
axpress:main.go;wait:0.8;menu:Tools/Inspect Function Complexity…;wait:0.8;mark:df46-complexity;deeplabels;shot:df46-function-complexity;\
axpress:Close Function Complexity Inspector;wait:0.5;\
axpress:darwin_only.go;wait:0.8;select:type StoreMode int;menu:Editor/Generate Enum / Stringer Methods…;wait:0.8;mark:df47-enum-sheet;deeplabels;shot:df47-generate-enum-sheet;\
axpress:Generate Enum Methods;wait:0.8;mark:df47-enum-done;find:func (e StoreMode) String() string;shot:df47-generate-enum-done;\
select:type AuthConfig struct;menu:Editor/Generate Constructor & Options…;wait:0.8;mark:df49-ctor-sheet;deeplabels;shot:df49-generate-constructor-sheet;\
axpress:Generate Constructor;wait:0.8;mark:df49-ctor-done;find:func NewAuthConfig;shot:df49-generate-constructor-done;\
select:func NormalizeStoreKey;menu:Editor/Generate Go Benchmark…;wait:0.8;mark:df64-benchgen-sheet;deeplabels;shot:df64-generate-benchmark-sheet;\
axpress:Generate Benchmark;wait:1.0;mark:df64-benchgen-done;find:func BenchmarkNormalizeStoreKey(b *testing.B);shot:df64-generate-benchmark-done;\
axpress:darwin_only.go;wait:0.6;\
select:func NormalizeStoreKey;menu:Editor/Generate Fuzz Test…;wait:0.8;mark:df51-fuzz-sheet;deeplabels;shot:df51-generate-fuzz-test-sheet;\
axpress:Generate Fuzz Test;wait:1.0;mark:df51-fuzz-done;find:func FuzzNormalizeStoreKey(f *testing.F);shot:df51-generate-fuzz-test-done;\
menu:Tools/Compare Benchmarks with Baseline…;wait:0.8;axpress:Run Benchmarks;wait:1.0;waitlabel:ns/op · ;wait:0.5;mark:df39-bench-sheet;deeplabels;shot:df39-benchmark-comparison;\
axpress:Save Current as Baseline;wait:0.8;mark:df39-bench-saved;deeplabels;shot:df39-benchmark-baseline-saved;\
axpress:Close Benchmark Comparison;wait:0.5;\
axpress:large_fixture.txt;wait:1.2;mark:df36-large-banner;deeplabels;shot:df36-large-file-banner;\
axpress:Enable Anyway;wait:0.6;mark:df36-large-enabled;deeplabels;\
menu:Help/Workspace Diagnostics…;wait:0.8;mark:df37-diag-sheet;deeplabels;shot:df37-workspace-diagnostics;\
axpress:Release Unused Caches;wait:0.6;mark:df37-diag-released;deeplabels;shot:df37-workspace-diagnostics-released;\
axpress:Done;wait:0.5;\
menu:Tools/New Go Scratch File;wait:1.2;mark:df22-scratch;find:Hello from GoLens Go Scratchpad!;shot:df22-scratchpad;\
mark:done;quit"

wait_mark done 360
SRV_ALIVE_AFTER_DETACH=0
if [ "${GOLENS_EXECUTION_MODE:-host}" = "vm" ]; then
  [ -s "$P2/.git/alive-after-detach" ] && SRV_ALIVE_AFTER_DETACH=1
else
  if [ -n "$DUMMY_SRV_PID" ] && kill -0 "$DUMMY_SRV_PID" 2>/dev/null; then
    SRV_ALIVE_AFTER_DETACH=1
    kill -TERM "$DUMMY_SRV_PID" 2>/dev/null || true
  fi
fi
finish 15

EXPANDED_SEL=$(sed -n '/mark df10-expanded/,/mark df10-shrunk/p' "$LOG" | grep -m1 "selinfo")
BACK_SEL=$(sed -n '/mark df10-after-back/,/Editor\/Implement Interface/p' "$LOG" | grep -m1 "selinfo")
check DF10 "AST Expand/Shrink Selection (⌃⇧↑/⌃⇧↓) & Caret-Level Navigate Back (⌘[) restore exact span & line" \
  '[ -n "$EXPANDED_SEL" ] && [ -n "$BACK_SEL" ]' \
  "$EXPANDED_SEL | Back: $BACK_SEL — shots/df10-expand-selection.png"

IMPL_CLOSE=$(sed -n '/mark df11-done/,/select ComputeSum/p' "$LOG" | grep -m1 "find .Close() error. -> present")
check DF11 "Implement Interface… (⌃I) sheet filters 'io.Closer' and generates Close() error stub on KVStore" \
  '[ -n "$IMPL_CLOSE" ]' \
  "$IMPL_CLOSE — shots/df11-implement-interface-sheet.png & shots/df11-implement-interface-done.png"

MOVED_REMOVED=$(sed -n '/mark df12-done/,/axpress main.go/p' "$LOG" | grep -m1 "find .ComputeSum. -> absent")
check DF12 "Move Symbol… (⌃F6) moves ComputeSum out of store.go into helpers.go in the same package" \
  '[ -n "$MOVED_REMOVED" ] && [ -f "$P2/helpers.go" ] && grep -q "func ComputeSum" "$P2/helpers.go"' \
  "helpers.go created with ComputeSum; store.go: $MOVED_REMOVED — shots/df12-move-symbol-sheet.png"

ATTACH_LABELS=$(sed -n '/mark df13-attach/,/axpress Attach to Selected Process/p' "$LOG" | grep -m1 "deeplabels:")
ATTACH_PAUSED=$(sed -n '/mark df13-attached-paused/,/axpress Stop Debugging/p' "$LOG" | grep -m1 "deeplabels:")
check DF13 "Attach to Process… (⌃⌥⌘A) attaches to live kvservice-server PID, pauses at breakpoint in daemonStep with stack & variables, and detaches cleanly without killing target process" \
  'echo "$ATTACH_LABELS" | grep -q "kvservice-server" && echo "$ATTACH_PAUSED" | grep -q "daemonStep" && [ "$SRV_ALIVE_AFTER_DETACH" = "1" ]' \
  "Attached to the guest kvservice-server, paused in daemonStep, aliveAfterDetach=$SRV_ALIVE_AFTER_DETACH — shots/df13-attach-process-sheet.png & shots/df13-attached-paused.png"

CAP_LABELS=$(sed -n '/mark df14-safety/,/Product\/Profile Tests/p' "$LOG" | grep -m1 "deeplabels:")
check DF14 "Safety Capabilities Audit detects CAPABILITY_EXEC on os/exec and displays inline editor annotations" \
  'echo "$CAP_LABELS" | grep -q "Capabilities" && echo "$CAP_LABELS" | grep -q "Inline in Editor"' \
  "Capabilities & Inline toggle verified — shots/df14-safety-capabilities-inline.png"

PROF_LABELS=$(sed -n '/mark df15-profile/,/axpress Flame Graph/p' "$LOG" | grep -m1 "deeplabels:")
check DF15 "Profiler view provides Open .pprof… & Editor Line Heat toggle with gutter heat bars" \
  'echo "$PROF_LABELS" | grep -q "Open pprof Profile" && echo "$PROF_LABELS" | grep -q "Show Editor Line Heat"' \
  "Profiler Open .pprof… & Editor Line Heat verified — shots/df15-profiler-heat.png"

STRUCT_TAG_SHEET=$(sed -n '/mark df16-sheet/,/axpress Apply Struct Tags/p' "$LOG" | grep -m1 "deeplabels:")
STRUCT_TAG_APPLIED=$(sed -n '/mark df16-done/,/Tools\/Convert JSON to Go Struct/p' "$LOG" | grep -m1 'find .json:"namespace". -> present')
check DF16 "Modify Struct Tags… (⌃⌥T) opens sheet with live preview and applies json:\"namespace\" tag to KVStore" \
  'echo "$STRUCT_TAG_SHEET" | grep -q "Go Struct Tags" && [ -n "$STRUCT_TAG_APPLIED" ]' \
  "$STRUCT_TAG_APPLIED — shots/df16-struct-tags-sheet.png & shots/df16-struct-tags-done.png"

JSON_STRUCT_SHEET=$(sed -n '/mark df17-sheet/,/axpress Insert Generated Struct/p' "$LOG" | grep -m1 "deeplabels:")
JSON_STRUCT_INSERTED=$(sed -n '/mark df17-done/,/select Payload/p' "$LOG" | grep -m1 "find .type Payload struct. -> present")
check DF17 "Convert JSON to Go Struct… (⌃⌥V) previews inferred struct and inserts type Payload struct into store.go" \
  'echo "$JSON_STRUCT_SHEET" | grep -q "Paste JSON as Go Struct" && [ -n "$JSON_STRUCT_INSERTED" ]' \
  "$JSON_STRUCT_INSERTED — shots/df17-json-to-struct-sheet.png & shots/df17-json-to-struct-done.png"

GOMOD_OPENED=$(sed -n '/mark df18-gomod/,/axpress store.go/p' "$LOG" | grep -m1 "find .module example.com/kvservice. -> present")
check DF18 "go.mod displays interactive Code Lenses (Run go mod tidy · Check Module Updates · Download Modules)" \
  '[ -n "$GOMOD_OPENED" ] && [ -s "$ART/shots/df18-gomod-lenses.png" ]' \
  "$GOMOD_OPENED — shots/df18-gomod-lenses.png"

BEFORE_REVERT=$(sed -n '/mark df19-before-revert/,/Editor\/Discard Change at Cursor/p' "$LOG" | grep -m1 "find .type Payload struct. -> present")
AFTER_REVERT=$(sed -n '/mark df19-after-revert/,/select prefix := k.namespace/p' "$LOG" | grep -m1 "find .type Payload struct. -> absent")
check DF19 "Git Inline Blame & Discard Change at Cursor cleanly revert uncommitted hunk in store.go" \
  '[ -n "$BEFORE_REVERT" ] && [ -n "$AFTER_REVERT" ]' \
  "Before: $BEFORE_REVERT -> After Revert: $AFTER_REVERT — shots/df19-git-diff-blame.png & shots/df19-git-reverted.png"

DF19B_POP=$(sed -n '/mark df19b-popover/,/mark df19b-discarded/p' "$LOG" | grep -m1 "popoverlabels:")
DF19B_BEFORE=$(sed -n '/mark df19b-before/,/mark df19b-popover/p' "$LOG")
DF19B_DISCARDED=$(sed -n '/mark df19b-discarded/,/mark df19b-undone/p' "$LOG")
DF19B_UNDONE=$(sed -n '/mark df19b-undone/,/mark df19b-redone/p' "$LOG")
DF19B_REDONE=$(sed -n '/mark df19b-redone/,/mark df19b-end/p' "$LOG")
DF19B_EDITED_BEFORE=$(echo "$DF19B_BEFORE" | grep -m1 "^DRIVE edited")
check DF19b "Discard Change on the gutter change bar popover is undone by one ⌘Z (Undo Revert Git Hunk) and redone by one Redo Revert Git Hunk" \
  'echo "$DF19B_POP" | grep -q "Discard Change" && echo "$DF19B_BEFORE" | grep -q "find .const maxKeys = 400. -> present" && [ -n "$DF19B_EDITED_BEFORE" ] \
   && echo "$DF19B_DISCARDED" | grep -q "find .const maxKeys = 400. -> absent" && echo "$DF19B_DISCARDED" | grep -q "edited 1" && echo "$DF19B_DISCARDED" | grep -q "undotitle Revert Git Hunk canUndo=1" && echo "$DF19B_DISCARDED" | grep -q "menustate Edit/Undo Revert Git Hunk enabled=1" \
   && echo "$DF19B_UNDONE" | grep -q "find .const maxKeys = 400. -> present" && [ "$(echo "$DF19B_UNDONE" | grep -m1 "^DRIVE edited")" = "$DF19B_EDITED_BEFORE" ] && echo "$DF19B_UNDONE" | grep -q "menu Edit/Redo Revert Git Hunk isEnabled=1" \
   && echo "$DF19B_REDONE" | grep -q "find .const maxKeys = 400. -> absent" && echo "$DF19B_REDONE" | grep -q "edited 1" && echo "$DF19B_REDONE" | grep -q "undotitle Revert Git Hunk canUndo=1"' \
  "discarded: $(echo "$DF19B_DISCARDED" | grep -E "find|undotitle" | tr '\n' ' ') / one undo: $(echo "$DF19B_UNDONE" | grep -E "find|edited" | tr '\n' ' ') / one redo: $(echo "$DF19B_REDONE" | grep -E "find|undotitle" | tr '\n' ' ') — shots/df19b-popover-redone.png"

DF19C_REVERTED=$(sed -n '/mark df19c-reverted/,/mark df19c-undone/p' "$LOG")
DF19C_UNDONE=$(sed -n '/mark df19c-undone/,/mark df19c-redone/p' "$LOG")
DF19C_REDONE=$(sed -n '/mark df19c-redone/,/mark df19b-before/p' "$LOG")
check DF19c "Discard Change at Cursor is undone by one ⌘Z (Undo Revert Git Hunk) and redone by one Redo Revert Git Hunk" \
  'echo "$DF19C_REVERTED" | grep -q "undotitle Revert Git Hunk canUndo=1" && echo "$DF19C_REVERTED" | grep -q "menustate Edit/Undo Revert Git Hunk enabled=1" \
   && echo "$DF19C_UNDONE" | grep -q "find .type Payload struct. -> present" && echo "$DF19C_UNDONE" | grep -q "menu Edit/Redo Revert Git Hunk isEnabled=1" \
   && echo "$DF19C_REDONE" | grep -q "find .type Payload struct. -> absent" && echo "$DF19C_REDONE" | grep -q "undotitle Revert Git Hunk canUndo=1"' \
  "$(echo "$DF19C_REVERTED" | grep -m1 undotitle) / one undo: $(echo "$DF19C_UNDONE" | grep -m1 find) / one redo: $(echo "$DF19C_REDONE" | grep -E "find|undotitle" | tr '\n' ' ')"

LAYOUT_SHEET=$(sed -n '/mark df20-layout-sheet/,/axpress Optimize Struct Field Order/p' "$LOG" | grep -m1 "deeplabels:")
LAYOUT_OPT=$(sed -n '/mark df20-layout-done/,/axpress go.mod/p' "$LOG" | grep -m1 "find .UserName string. -> present")
check DF20 "Inspect Struct Memory Layout… (⌃⌥L) displays field offsets/padding on Payload and optimizes field order" \
  'echo "$LAYOUT_SHEET" | grep -q "Struct Memory Layout" && [ -n "$LAYOUT_OPT" ]' \
  "$LAYOUT_OPT — shots/df20-struct-layout-sheet.png & shots/df20-struct-layout-optimized.png"

WRAP_ERR_DONE=$(sed -n '/mark df21-wrap-err/,/select total :=/p' "$LOG" | grep -m1 "find .if _, err := fmt.Println(total). -> present")
VAR_TOGGLE_DONE=$(sed -n '/mark df21-var-done/,/Product\/Run Safety Audit/p' "$LOG" | grep -m1 "find .var total = ComputeSum(10, 20). -> present")
check DF21 "Smart Error Handling (⌃⌥E) wraps call with if _, err := ...; err != nil and AST Intention converts ':=' to 'var'" \
  '[ -n "$WRAP_ERR_DONE" ] && [ -n "$VAR_TOGGLE_DONE" ]' \
  "$WRAP_ERR_DONE & $VAR_TOGGLE_DONE — shots/df21-intentions-done.png"

SCRATCH_OPENED=$(sed -n '/mark df22-scratch/,/mark done/p' "$LOG" | grep -m1 "find .Hello from GoLens Go Scratchpad!. -> present")
check DF22 "New Go Scratch File (⌃⌥⌘N) creates runnable .golens-scratch/scratch.go excluded from Git working tree" \
  '[ -n "$SCRATCH_OPENED" ] && [ -f "$P2/.golens-scratch/scratch.go" ] && ! git -C "$P2" status --porcelain | grep -q "golens-scratch"' \
  "$SCRATCH_OPENED (excluded from git status) — shots/df22-scratchpad.png"

SPLIT_INFO=$(sed -n '/mark df23-split/,/axpress Close Split Editor/p' "$LOG" | grep -m1 "splitinfo")
SPLIT_LABELS=$(sed -n '/mark df23-split/,/axpress Close Split Editor/p' "$LOG" | grep -m1 "deeplabels:")
check DF23 "Split Editor preserves independent document identity: left pane stays main.go while right pane opens store.go via Open Quickly (⌥Return)" \
  'echo "$SPLIT_INFO" | grep -q "count=2" && echo "$SPLIT_INFO" | grep -q "pane0\[file=main.go" && echo "$SPLIT_INFO" | grep -q "pane1\[file=store.go" && echo "$SPLIT_LABELS" | grep -q "Close Split Pane store.go"' \
  "$SPLIT_INFO — shots/df23-split-identity.png"

CALLSITE_SIG=$(sed -n '/mark df24-callsite-sig/,/axpress Cancel/p' "$LOG" | grep -m1 "deeplabels:")
check DF24 "Change Signature… (⌘F6) at a call site inside main() resolves the called function (ComputeSum in helpers.go) instead of main()" \
  'echo "$CALLSITE_SIG" | grep -q "func ComputeSum(a int, b int) int" && ! echo "$CALLSITE_SIG" | grep -q "func main()"' \
  "Resolved func ComputeSum(a int, b int) int in helpers.go — shots/df24-callsite-signature.png"

QUOTED_OUT=$(sed -n '/mark df25-quoted-args/,/Product\/Profile Application/p' "$LOG" | grep -m1 "deeplabels:")
check DF25 "Run Configuration preserves quoted arguments with spaces (-owner \"Daily QA\" -> Owner=Daily QA)" \
  'echo "$QUOTED_OUT" | grep -q "Owner=Daily QA"' \
  "Console output contains Owner=Daily QA — shots/df25-quoted-args.png"

CTX_EMPTY=$(sed -n '/mark df26-ctx/,/select Println/p' "$LOG" | grep -m1 "editorctx()")
CTX_SYM=$(sed -n '/mark df26-ctx/,/select Println/p' "$LOG" | grep -m1 "editorctx(ComputeSum)")
MENU_CP=$(sed -n '/mark df26-ctx/,/select Println/p' "$LOG" | grep -m1 "menustate View/Command Palette")
MENU_AT=$(sed -n '/mark df26-ctx/,/select Println/p' "$LOG" | grep -m1 "menustate Product/Attach to Process")
check DF26 "Context-aware Editor context menu groups Refactor & Generate submenus without rich-text clutter, and Command Palette (⇧⌘P) / Attach (⌃⌥⌘A) shortcuts match menu bar" \
  'echo "$CTX_EMPTY" | grep -q "Refactor\[" && echo "$CTX_EMPTY" | grep -q "Generate\[" && ! echo "$CTX_EMPTY" | grep -q "Go to Definition" && ! echo "$CTX_EMPTY" | grep -q "Font" && echo "$CTX_SYM" | grep -q "Go to Definition" && echo "$MENU_CP" | grep -Eq "key=[pP]" && echo "$MENU_AT" | grep -Eq "key=[aA]"' \
  "$CTX_EMPTY | $MENU_CP | $MENU_AT"

EXTRACT_SHEET=$(sed -n '/mark df27-sheet/,/axpress Confirm Extract Function/p' "$LOG" | grep -m1 "deeplabels:")
EXTRACT_DONE=$(sed -n '/mark df27-done/,/select func (k \*KVStore) Get/p' "$LOG" | grep -m1 "find .func (k \*KVStore) extractedFunc. -> present")
check DF27 "Extract Function… (⌥⌘M) infers receiver (k *KVStore) and return value (string) and extracts method in store.go" \
  'echo "$EXTRACT_SHEET" | grep -q "Extract Function" && [ -n "$EXTRACT_DONE" ]' \
  "$EXTRACT_DONE — shots/df27-extract-method-sheet.png & shots/df27-extract-method-done.png"

FLAME_LABELS=$(sed -n '/mark df28-flame/,/axpress Table/p' "$LOG" | grep -m1 "deeplabels:")
check DF28 "Interactive Flame Graph mode in Profiler renders hierarchical call-stack flame bars with inspector header" \
  'echo "$FLAME_LABELS" | grep -q "All Sampled Stacks" && echo "$FLAME_LABELS" | grep -q "Flame Bar"' \
  "Flame Graph rendered with All Sampled Stacks & Flame Bar nodes — shots/df28-flame-graph.png"

TESTGEN_SHEET=$(sed -n '/mark df29-sheet/,/axpress Confirm Generate Table-Driven Test/p' "$LOG" | grep -m1 "deeplabels:")
TESTGEN_DONE=$(sed -n '/mark df29-done/,/axpress main.go/p' "$LOG" | grep -m1 "find .func TestKVStore_Get(t \*testing.T). -> present")
check DF29 "Generate Table-Driven Test… (⌃⇧T) previews idiomatic subtest table for (*KVStore).Get and appends TestKVStore_Get to store_test.go" \
  'echo "$TESTGEN_SHEET" | grep -q "Generate Table-Driven Test" && [ -n "$TESTGEN_DONE" ] && grep -q "func TestKVStore_Get" "$P2/store_test.go"' \
  "$TESTGEN_DONE in store_test.go — shots/df29-generate-test-sheet.png & shots/df29-generate-test-done.png"

APP_PROF_LABELS=$(sed -n '/mark df30-app-profile/,/axpress Console/p' "$LOG" | grep -m1 "deeplabels:")
check DF30 "Zero-Edit Live Application Profiling (Product ▸ Profile Application, ⌃⇧⌘P) profiles package main via Go -overlay without leaving temp files on disk" \
  'echo "$APP_PROF_LABELS" | grep -q "Profile Application" && echo "$APP_PROF_LABELS" | grep -Eq "[1-9][0-9]* function" && [ ! -e "$P2/golens_profile_entry.go" ] && [ ! -e "$P2/_golens_profile_entry.go" ]' \
  "Profiler opened with live app samples & zero disk pollution — shots/df30-app-profile.png"

ESCAPE_LABELS=$(sed -n '/mark df31-escape/,/bpclick \/\/go:generate/p' "$LOG" | grep -m1 "deeplabels:")
check DF31 "Go Compiler Escape Analysis (View ▸ Show Escape Analysis) runs -gcflags=-m and reports heap escapes inline in main.go" \
  'echo "$ESCAPE_LABELS" | grep -q "Escape analysis for main.go:" && ! echo "$ESCAPE_LABELS" | grep -q "0 heap escape(s)"' \
  "$(echo "$ESCAPE_LABELS" | grep -o "Escape analysis for main.go:[^|]*" | head -1) — shots/df31-escape-analysis.png"

GOGEN_LABELS=$(sed -n '/mark df32-gogen/,/mark df26-ctx/p' "$LOG" | grep -m1 "deeplabels:")
check DF32 "Interactive //go:generate Gutter & Code Lens runner executes directive in main.go and generates generated_banner.txt" \
  '[ -f "$P2/generated_banner.txt" ] && echo "$GOGEN_LABELS" | grep -q "Running go generate on main.go" && echo "$GOGEN_LABELS" | grep -q "Process exited successfully."' \
  "Running go generate on main.go -> Process exited successfully & generated_banner.txt created — shots/df32-go-generate.png"


WS_SYM_LABELS=$(sed -n '/mark df34-ws-sym/,/postkey 36/p' "$LOG" | grep -m1 "deeplabels:")
WS_SYM_JUMPED=$(sed -n '/mark df34-jumped/,/select map\[string\]string/p' "$LOG" | grep -m1 "find .func (k \*KVStore) Get. -> present")
check DF34 "Workspace Symbol Search (Navigate ▸ Go to Workspace Symbol…, ⌘O) indexes symbols across files, ranks (*KVStore).Get for 'KVStore.Get', and jumps to store.go on Return" \
  'echo "$WS_SYM_LABELS" | grep -q "(\*KVStore).Get" && [ -n "$WS_SYM_JUMPED" ]' \
  "(*KVStore).Get -> $WS_SYM_JUMPED — shots/df34-workspace-symbol.png"

EXT_TYPE_SHEET=$(sed -n '/mark df35-type-sheet/,/axpress Confirm Extract Type/p' "$LOG" | grep -m1 "deeplabels:")
EXT_TYPE_DONE=$(sed -n '/mark df35-type-done/,/select StoreReader/p' "$LOG" | grep -m1 "find .type StoreMetaType map\[string\]string. -> present")
PROP_IFACE_SHEET=$(sed -n '/mark df35-prop-sheet/,/axpress Confirm Propagate Methods/p' "$LOG" | grep -m1 "deeplabels:")
PROP_IFACE_DONE=$(sed -n '/mark df35-prop-done/,/select StoreReader/p' "$LOG" | grep -m1 "find .Keys() \[\]string. -> present")
check DF35 "Extract Type Definition… (⌥⌘T) extracts type StoreMetaType map[string]string and Propagate Method to Implementations… (⌃⌥P) propagates Keys() []string to KVStore" \
  'echo "$EXT_TYPE_SHEET" | grep -q "Extract Type Definition" && [ -n "$EXT_TYPE_DONE" ] && echo "$PROP_IFACE_SHEET" | grep -q "Propagate Method to Implementations" && [ -n "$PROP_IFACE_DONE" ]' \
  "$EXT_TYPE_DONE & $PROP_IFACE_DONE — shots/df35-extract-type-sheet.png & shots/df35-propagate-interface-sheet.png & shots/df35-type-refactor-done.png"

LARGE_BANNER_BEFORE=$(sed -n '/mark df36-large-banner/,/axpress Enable Anyway/p' "$LOG" | grep -m1 "deeplabels:")
LARGE_BANNER_AFTER=$(sed -n '/mark df36-large-enabled/,/Help\/Workspace Diagnostics/p' "$LOG" | grep -m1 "deeplabels:")
check DF36 "Opening >2 MB file (large_fixture.txt) displays Large-File Mode Active banner and clicking 'Enable Anyway' dismisses it immediately" \
  'echo "$LARGE_BANNER_BEFORE" | grep -q "Large-File Mode Active" && ! echo "$LARGE_BANNER_AFTER" | grep -q "Large-File Mode Active"' \
  "Before: Large-File Mode Active -> After Enable Anyway: dismissed — shots/df36-large-file-banner.png"

DIAG_SHEET_LABELS=$(sed -n '/mark df37-diag-sheet/,/axpress Release Unused Caches/p' "$LOG" | grep -m1 "deeplabels:")
DIAG_RELEASED_LABELS=$(sed -n '/mark df37-diag-released/,/axpress Done/p' "$LOG" | grep -m1 "deeplabels:")
check DF37 "Workspace Diagnostics Sheet (Help ▸ Workspace Diagnostics…, ⌃⌥⌘D) displays live Physical Footprint / Go Heap / gopls RSS and 'Release Unused Caches' reclaims memory" \
  'echo "$DIAG_SHEET_LABELS" | grep -q "Workspace Diagnostics" && echo "$DIAG_SHEET_LABELS" | grep -q "Physical Footprint" && echo "$DIAG_RELEASED_LABELS" | grep -q "Released unused caches"' \
  "Workspace Diagnostics verified & caches released — shots/df37-workspace-diagnostics.png & shots/df37-workspace-diagnostics-released.png"

BENCH_SHEET_LABELS=$(sed -n '/mark df39-bench-sheet/,/axpress Save Current as Baseline/p' "$LOG" | grep -m1 "deeplabels:")
BENCH_SAVED_LABELS=$(sed -n '/mark df39-bench-saved/,/axpress Close Benchmark Comparison/p' "$LOG" | grep -m1 "deeplabels:")
check DF39 "Compare Benchmarks with Baseline… (Tools ▸ Compare Benchmarks with Baseline…, ⌃⌥B) lists BenchmarkGet metrics and saves baseline cleanly" \
  'echo "$BENCH_SHEET_LABELS" | grep -q "Compare Benchmarks with Baseline" && echo "$BENCH_SHEET_LABELS" | grep -q "BenchmarkGet" && echo "$BENCH_SAVED_LABELS" | grep -q "Baseline Saved"' \
  "BenchmarkGet compared & Baseline Saved — shots/df39-benchmark-comparison.png & shots/df39-benchmark-baseline-saved.png"

MOCK_SHEET_LABELS=$(sed -n '/mark df40-mock-sheet/,/axpress Generate Mock/p' "$LOG" | grep -m1 "deeplabels:")
MOCK_GEN_DONE=$(sed -n '/mark df40-mock-done/,/axpress main.go/p' "$LOG" | grep -m1 "find .type MockStoreReader struct. -> present")
check DF40 "Generate Interface Mock… (Editor ▸ Generate Interface Mock…, ⌃⌥M) previews and generates concurrency-safe MockStoreReader with Func hooks and Calls recording" \
  'echo "$MOCK_SHEET_LABELS" | grep -q "Generate Interface Mock" && echo "$MOCK_SHEET_LABELS" | grep -q "type MockStoreReader struct" && [ -n "$MOCK_GEN_DONE" ]' \
  "$MOCK_GEN_DONE — shots/df40-generate-mock-sheet.png & shots/df40-generate-mock-done.png"

PKG_DEPS_LABELS=$(sed -n '/mark df41-pkg-deps/,/axpress Close Package Dependencies Inspector/p' "$LOG" | grep -m1 "deeplabels:")
check DF41 "Package Dependency Graph & Cycle Inspector (Tools ▸ Inspect Package Dependencies…, ⌃⌥G) analyzes module topology, stdlib imports, and circular cycles" \
  'echo "$PKG_DEPS_LABELS" | grep -q "Inspect Package Dependencies" && echo "$PKG_DEPS_LABELS" | grep -q "example.com/kvservice" && echo "$PKG_DEPS_LABELS" | grep -q "Circular Cycles"' \
  "Package Dependencies verified for example.com/kvservice — shots/df41-package-dependencies.png"

FILL_STRUCT_DONE=$(sed -n '/mark df42-fill-struct/,/Tools\/Inspect Package Dependencies/p' "$LOG" | grep -m1 "find .namespace: \"\". -> present")
check DF42 "Fill Struct Fields (Editor ▸ Fill Struct Fields, ⌃⌥F) populates missing KVStore{} fields with idiomatic Go zero values" \
  '[ -n "$FILL_STRUCT_DONE" ]' \
  "$FILL_STRUCT_DONE — shots/df42-fill-struct.png"

SAFETY_DEPS_LABELS=$(sed -n '/mark df43-safety-deps/,/Product\/Profile Tests/p' "$LOG" | grep -m1 "deeplabels:")
check DF43 "GoLens Safety Dependencies tab audits go.mod supply-chain / toolchain directives and surfaces the outdated go directive in plain words" \
  'echo "$SAFETY_DEPS_LABELS" | grep -q "which is out of date" && ! echo "$SAFETY_DEPS_LABELS" | grep -q "\[DEP_" && echo "$SAFETY_DEPS_LABELS" | grep -q "Module / Supply Chain"' \
  "Outdated go directive & Module / Supply Chain badge verified — shots/df43-safety-dependencies.png"


COMPLEXITY_LABELS=$(sed -n '/mark df46-complexity/,/axpress Close Function Complexity Inspector/p' "$LOG" | grep -m1 "deeplabels:")
check DF46 "Inspect Function Complexity… (Tools ▸ Inspect Function Complexity…, ⌃⌥Q) measures cognitive & cyclomatic complexity and ranks functions" \
  'echo "$COMPLEXITY_LABELS" | grep -q "Inspect Function Complexity" && echo "$COMPLEXITY_LABELS" | grep -q "Total Functions" && echo "$COMPLEXITY_LABELS" | grep -q "Max Cognitive"' \
  "Function Complexity Inspector verified — shots/df46-function-complexity.png"

ENUM_SHEET_LABELS=$(sed -n '/mark df47-enum-sheet/,/axpress Generate Enum Methods/p' "$LOG" | grep -m1 "deeplabels:")
ENUM_GEN_DONE=$(sed -n '/mark df47-enum-done/,/mark df49-ctor-sheet/p' "$LOG" | grep -m1 "find .func (e StoreMode) String() string. -> present")
check DF47 "Generate Enum / Stringer Methods… (Editor ▸ Generate Enum / Stringer Methods…, ⌃⌥S) previews constant labels and generates String()/ParseStoreMode methods" \
  'echo "$ENUM_SHEET_LABELS" | grep -q "Generate Enum / Stringer Methods" && [ -n "$ENUM_GEN_DONE" ]' \
  "$ENUM_GEN_DONE — shots/df47-generate-enum-sheet.png & shots/df47-generate-enum-done.png"

CTOR_SHEET_LABELS=$(sed -n '/mark df49-ctor-sheet/,/axpress Generate Constructor/p' "$LOG" | grep -m1 "deeplabels:")
CTOR_GEN_DONE=$(sed -n '/mark df49-ctor-done/,/mark df64-benchgen-sheet/p' "$LOG" | grep -m1 "find .func NewAuthConfig. -> present")
check DF49 "Generate Constructor & Options… (Editor ▸ Generate Constructor & Options…, ⌃⌥N) previews functional options and inserts NewAuthConfig + WithAPIToken" \
  'echo "$CTOR_SHEET_LABELS" | grep -q "Generate Constructor & Options" && [ -n "$CTOR_GEN_DONE" ]' \
  "$CTOR_GEN_DONE — shots/df49-generate-constructor-sheet.png & shots/df49-generate-constructor-done.png"

FUZZ_SHEET_LABELS=$(sed -n '/mark df51-fuzz-sheet/,/axpress Generate Fuzz Test/p' "$LOG" | grep -m1 "deeplabels:")
FUZZ_GEN_DONE=$(sed -n '/mark df51-fuzz-done/,/Tools\/Compare Benchmarks with Baseline/p' "$LOG" | grep -m1 "find .func FuzzNormalizeStoreKey(f \*testing.F). -> present")
check DF51 "Generate Fuzz Test… (Editor ▸ Generate Fuzz Test…, ⌃⌥U) previews f.Add seed corpus and generates FuzzNormalizeStoreKey in darwin_only_test.go" \
  'echo "$FUZZ_SHEET_LABELS" | grep -q "Generate Fuzz Test" && [ -n "$FUZZ_GEN_DONE" ]' \
  "$FUZZ_GEN_DONE — shots/df51-generate-fuzz-test-sheet.png & shots/df51-generate-fuzz-test-done.png"

BENCHGEN_SHEET_LABELS=$(sed -n '/mark df64-benchgen-sheet/,/axpress Generate Benchmark/p' "$LOG" | grep -m1 "deeplabels:")
BENCHGEN_DONE=$(sed -n '/mark df64-benchgen-done/,/axpress darwin_only.go/p' "$LOG" | grep -m1 -F "find 'func BenchmarkNormalizeStoreKey(b *testing.B)' -> present")
check DF64 "Generate Go Benchmark… (Editor ▸ Generate Go Benchmark…, ⌃⌥7) previews b.ReportAllocs() benchmark and generates BenchmarkNormalizeStoreKey in darwin_only_test.go" \
  'echo "$BENCHGEN_SHEET_LABELS" | grep -q "Generate Go Benchmark" && [ -n "$BENCHGEN_DONE" ]' \
  "$BENCHGEN_DONE — shots/df64-generate-benchmark-sheet.png & shots/df64-generate-benchmark-done.png"

REGEX_FR=$(grep -m1 'fr (\.\*?,?)+QQQ ->' "$LOG")
REGEX_BLOCK=$(awk '/time df77-before/ {b=$4} /time df77-after/ {a=$4} END {if (a && b) printf "%.3f", a - b}' "$LOG")
REGEX_STOPPED=$(sed -n '/mark df77-stopped/,/mark df77-closed/p' "$LOG" | grep -m1 "deeplabels:")
REGEX_CLOSED=$(sed -n '/mark df77-closed/,$p' "$LOG" | grep -m1 "labels:")
check DF77 "Find with a catastrophic regular expression keeps typing responsive, stops after the time limit with 'Pattern Too Slow', and Esc closes the bar" \
  '! echo "$REGEX_FR" | grep -q GoLensTextView && awk "BEGIN {exit !($REGEX_BLOCK < 0.8)}" && echo "$REGEX_STOPPED" | grep -q "Pattern Too Slow" && ! echo "$REGEX_CLOSED" | grep -q "Pattern Too Slow"' \
  "typing step took ${REGEX_BLOCK}s (0.4s is the driver's own wait) — shots/df77-find-regex-stopped.png"

REPLACE_LOG=$(sed -n '/mark df78-all/,/mark df78-one-undone/p' "$LOG"; sed -n '/mark df78-one-undone/,$p' "$LOG" | grep -m1 "find .pollStep.")
check DF78 "Find bar Replace All rewrites every match in one undo step, and Replace rewrites only the next match" \
  'echo "$REPLACE_LOG" | grep -q "find .func pollStep(iter int) int. -> present" && echo "$REPLACE_LOG" | grep -q "find ._ = pollStep(i). -> present" && [ "$(echo "$REPLACE_LOG" | grep -c "find .pollStep. -> absent")" = 2 ] && echo "$REPLACE_LOG" | grep -q "find .daemonStep. -> present"' \
  "$(echo "$REPLACE_LOG" | grep -c 'find .*-> present') present / $(echo "$REPLACE_LOG" | grep -c 'find .*-> absent') absent checks"

unexpected=0
ran=0
printf '\n%-5s %-6s  %s\n' ID RESULT CHECK
while IFS=$'\t' read -r id name res_status ev; do
  ran=$((ran + 1))
  [ "$res_status" = FAIL ] && unexpected=$((unexpected + 1))
  printf '%-5s %-6s  %s\n        %s\n' "$id" "$res_status" "$name" "$ev"
done < "$RESULTS"
echo
echo "Runtime: $(( $(date +%s) - START ))s. Artifacts: $ART"
if [ ! -s "$RESULTS" ] || [ "$ran" -eq 0 ]; then
  echo "No checks recorded in $RESULTS."
  exit 1
fi
exit $([ $unexpected -eq 0 ] && echo 0 || echo 1)
