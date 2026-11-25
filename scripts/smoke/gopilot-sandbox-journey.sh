#!/bin/bash
# Gopilot run_tests isolation in the Linux machine: a scripted OpenAI-style provider asks for run_tests on a probe test
# that tries to write into the workspace, dial the internet and listen on loopback. The user approves the run in the
# panel. The probe writes what happened to /cache/gobuild, which is the host's build cache folder.
# Usage: scripts/smoke/gopilot-sandbox-journey.sh   (GOPILOT_SANDBOX_OUT=dir keeps logs and screenshots; VM_AGENT=path
# boots a copy of the shared Linux runtime inside the test bundle with that guest agent)
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
export GOLENS_VM_MEMORY_MB=512
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=$REPO/.build/release/GoLensApp
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }
DOMAIN=dev.golens.test.gopilotsandbox
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
FIX=$HOME/Documents/golens-aiprobe
PROBE_OUT="$HOME/Library/Caches/com.golens.app/gobuild/golens-sandbox-probe.txt"
PROVIDER_PORT=${GOPILOT_SANDBOX_PORT:-47321}
LOCK=/private/tmp/golens-smoke.lock
. "$(cd "$(dirname "$0")" && pwd)/smoke-lock.sh"

if pgrep -f com.apple.Virtualization.VirtualMachine >/dev/null; then
  echo "another Linux machine is running; this journey would replace the VMRootfs folder it boots from"; exit 2
fi
lsof -nP -iTCP:$PROVIDER_PORT -sTCP:LISTEN >/dev/null 2>&1 && { echo "port $PROVIDER_PORT is busy; set GOPILOT_SANDBOX_PORT"; exit 2; }
smoke_lock_acquire
pkill -9 -f "Containers/$DOMAIN/" 2>/dev/null || true
mkdir -p "$CONTAINER_DIR/tmp"
WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-gpsandbox.XXXXXX")" && pwd -P)
ART=${GOPILOT_SANDBOX_OUT:-$WORK/art}
mkdir -p "$ART/shots" "$ART/logs"
APP_PID=
OWNED_PIDS=
PROVIDER_PID=

descendants() { local k; for k in $(pgrep -P "$1" 2>/dev/null); do echo "$k"; descendants "$k"; done; }

cleanup() {
  [ -n "$PROVIDER_PID" ] && kill -TERM "$PROVIDER_PID" 2>/dev/null
  [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null && kill -TERM "$APP_PID" 2>/dev/null
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  sleep 1
  for k in $OWNED_PIDS $APP_PID; do kill -KILL "$k" 2>/dev/null; done
  defaults delete $DOMAIN >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  rm -rf "$FIX" "$WORK"
  smoke_lock_release
}
trap cleanup EXIT INT TERM

BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
VMR="$HOME/Library/Application Support/GoLens/VMRuntime"
[ -f "$VMR/vmlinuz" ] || { echo "no Linux runtime in $VMR"; exit 2; }
if [ -n "${VM_AGENT:-}" ]; then
  RT="$WORK/app/GoLens.app/Contents/Resources/VMRuntime"
  mkdir -p "$RT"
  cp -c "$VMR/vmlinuz" "$VMR/rootfs.img" "$RT/" && cp -cR "$VMR/goroot" "$RT/goroot" && cp "$VM_AGENT" "$RT/golens-vm-agent" || { echo "VM_AGENT runtime copy failed"; exit 2; }
fi
APP=$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/driver.dylib" "$HERE/driver.m" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/quiet.dylib" "$HERE/quiet-launch.m" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
defaults delete $DOMAIN >/dev/null 2>&1

rm -rf "$FIX"; mkdir -p "$FIX/probe"
printf 'module example.com/aiprobe\n\ngo 1.22\n' > "$FIX/go.mod"
cat > "$FIX/probe/probe.go" <<'EOF'
package probe

func Answer() int { return 42 }
EOF
cat > "$FIX/probe/probe_test.go" <<'EOF'
package probe

import (
	"fmt"
	"net"
	"os"
	"strings"
	"testing"
	"time"
)

func TestSandboxProbe(t *testing.T) {
	var b strings.Builder
	werr := os.WriteFile("written-by-ai-test.txt", []byte("x"), 0o644)
	fmt.Fprintf(&b, "workspace write: %v\n", werr)
	conn, nerr := net.DialTimeout("tcp", "1.1.1.1:443", 3*time.Second)
	if conn != nil {
		conn.Close()
	}
	fmt.Fprintf(&b, "internet dial: %v\n", nerr)
	ln, lerr := net.Listen("tcp", "127.0.0.1:0")
	if ln != nil {
		ln.Close()
	}
	fmt.Fprintf(&b, "loopback listen: %v\n", lerr)
	_ = os.WriteFile("/cache/gobuild/golens-sandbox-probe.txt", []byte(b.String()), 0o644)
	t.Log(b.String())
	if Answer() != 42 {
		t.Fatal("unexpected answer")
	}
}
EOF
rm -f "$PROBE_OUT"

python3 "$HERE/gopilot-sandbox-provider.py" "$PROVIDER_PORT" "$ART/logs/provider.log" TestSandboxProbe &
PROVIDER_PID=$!
sleep 1

LOG=$ART/logs/journey.log
STEPS="wait:15;fakeactive;mark:ready;wait:3;deeplabels;\
fieldp:Describe a change for Gopilot to make:Run the sandbox probe test;wait:0.5;postkey:36;wait:6;mark:sent;deeplabels;sheetshot:gp-01-sheet;shot:gp-01-sent;\
sheetpress:Allow;wait:4;axpress:Trust This Project;wait:3;fieldp:Describe a change for Gopilot to make:Run the sandbox probe test again;wait:0.5;postkey:36;waitlabel:Allow Once;mark:approval;deeplabels;shot:gp-02-approval;\
axpress:Allow Once;wait:60;mark:ran;deeplabels;shot:gp-03-ran;mark:done;quit"
DRIVE="$STEPS" DRIVE_OUT=$LOG DRIVE_SHOTS=$ART/shots DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
  GOLENS_EXECUTION_MODE=vm GOPILOT_DEV_SEED_CONNECTED=1 GOPILOT_DEV_BASE_URL="http://127.0.0.1:$PROVIDER_PORT/v1" \
  "$APP" -GoLensLastWorkspacePath "$FIX" -GoLensLastFilePath "$FIX/probe/probe_test.go" -GoLensShowGopilot '<true/>' -GoLensGopilotMode agent > "$ART/logs/app.log" 2>&1 &
APP_PID=$!
i=0
while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt 1200 ]; do
  OWNED_PIDS="$OWNED_PIDS $(descendants "$APP_PID" | tr '\n' ' ')"
  sleep 0.2; i=$((i + 1))
done
kill -0 "$APP_PID" 2>/dev/null && { echo "app did not quit; stopping it"; kill -TERM "$APP_PID"; }

echo "== provider"
grep -E "^POST|^TOOL_RESULT" "$ART/logs/provider.log" | cut -c1-600
echo "== probe ($PROBE_OUT)"
cat "$PROBE_OUT" 2>/dev/null || echo "no probe output"
ls "$FIX/probe/written-by-ai-test.txt" 2>/dev/null && echo "the test wrote into the workspace"

FAIL=0
grep -q "workspace write: .*read-only file system" "$PROBE_OUT" 2>/dev/null && [ ! -e "$FIX/probe/written-by-ai-test.txt" ] && echo "PASS AI1 workspace write fails with EROFS" || { echo "FAIL AI1 workspace write was not blocked with EROFS"; FAIL=1; }
grep -q "internet dial: .*network is unreachable" "$PROBE_OUT" 2>/dev/null && echo "PASS AI2 internet dial fails with ENETUNREACH" || { echo "FAIL AI2 internet dial was not blocked with ENETUNREACH"; FAIL=1; }
grep -q "loopback listen: <nil>" "$PROBE_OUT" 2>/dev/null && echo "PASS AI3 loopback still works" || { echo "FAIL AI3 loopback listen failed"; FAIL=1; }
rm -f "$PROBE_OUT"
exit $FAIL
