#!/bin/bash
# Continuous typing with gopls completion on a real workload, measuring main-thread stalls and whether
# completion keeps answering. MODE=vm (default): sandboxed app, gopls in the Linux VM. MODE=local: the
# same app without the sandbox entitlements, so gopls runs on the host.
# Usage: MODE=vm|local [BIN=path/to/GoLensApp] [CYCLES=8] scripts/smoke/typing-journey.sh
# The workload is a copy of a Go module under ~/Documents (TYPING_DIR, default ~/Documents/golens-typing-lms)
# opened at TYPING_FILE (default internal/features/chat/service.go). The copy is restored after the run.
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
MODE=${MODE:-vm}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=${BIN:-$REPO/.build/release/GoLensApp}
[ -x "$BIN" ] || { echo "missing binary: $BIN"; exit 2; }
WS=${TYPING_DIR:-$HOME/Documents/golens-typing-lms}
FILE=${TYPING_FILE:-internal/features/chat/service.go}
[ -f "$WS/$FILE" ] || { echo "missing workload file: $WS/$FILE"; exit 2; }
CYCLES=${CYCLES:-8}
WARM=${WARM:-25}

if [ "$MODE" = vm ]; then DOMAIN=dev.golens.test.typingstall; else DOMAIN=dev.golens.test.typingstall.local; fi
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
if [ "$MODE" = vm ]; then
  mkdir -p "$CONTAINER_DIR/tmp"
  WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-typing.XXXXXX")" && pwd -P)
else
  WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/golens-typing-local.XXXXXX")" && pwd -P)
fi
OUT=${TYPING_OUT:-$WORK/out}
mkdir -p "$OUT"
APP_PID=
OWNED_PIDS=
SAMPLER_PID=
LOGSTREAM_PID=
cp "$WS/$FILE" "$WORK/original.go"

descendants() { local k; for k in $(pgrep -P "$1" 2>/dev/null); do echo "$k"; descendants "$k"; done; }

cleanup() {
  [ -n "$SAMPLER_PID" ] && kill -TERM "$SAMPLER_PID" 2>/dev/null
  [ -n "$LOGSTREAM_PID" ] && kill -TERM "$LOGSTREAM_PID" 2>/dev/null
  [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null && kill -TERM "$APP_PID" 2>/dev/null
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  sleep 1
  for k in $OWNED_PIDS $APP_PID; do kill -KILL "$k" 2>/dev/null; done
  cp "$WORK/original.go" "$WS/$FILE"
  defaults delete $DOMAIN >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  if [ -z "${TYPING_OUT:-}" ]; then echo "artifacts: (removed with the work dir; set TYPING_OUT to keep them)"; fi
  rm -rf "$WORK/app" "$WORK/driver.dylib" "$WORK/quiet.dylib"
  [ -z "${TYPING_OUT:-}" ] && rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

if [ "$MODE" = vm ]; then
  BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
  if [ -n "${VM_AGENT:-}" ]; then
    cp "$VM_AGENT" "$CONTAINER_DIR/Library/Application Support/GoLens/VMRuntime/golens-vm-agent" || { echo "VM_AGENT copy failed"; exit 2; }
  fi
  if [ -n "${VM_GOPLS:-}" ]; then
    cp "$VM_GOPLS" "$CONTAINER_DIR/Library/Application Support/GoLens/VMRuntime/goroot/bin/gopls" || { echo "VM_GOPLS copy failed"; exit 2; }
  fi
else
  cat > "$WORK/local.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.cs.disable-library-validation</key><true/>
<key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
<key>com.apple.security.get-task-allow</key><true/>
</dict></plist>
PLIST
  ENTITLEMENTS="$WORK/local.entitlements" BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
fi
APP=$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/driver.dylib" "$HERE/driver.m" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/quiet.dylib" "$HERE/quiet-launch.m" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
defaults delete $DOMAIN >/dev/null 2>&1

ESC=$(printf '\342\216\213')
DEL=$(printf '\342\214\253')
BURST='\nlabel := fmt.Sprintf("%s-%s", toolName, err)\nparts := strings.Split(label, "-")\ntotal := len(parts) + len(toolName)\n_ = total\n'
COMPLETE="code:s.getToolD;wait:1.2;panel;code:$ESC$DEL$DEL$DEL$DEL$DEL$DEL$DEL$DEL$DEL$DEL;code:strings.HasPre;wait:1.2;panel;line;code:$ESC$DEL$DEL$DEL$DEL$DEL$DEL$DEL$DEL$DEL$DEL$DEL$DEL$DEL$DEL"
CYCLE="codefast:$BURST;$COMPLETE;"
T="wait:4;fakeactive;mark:ready;wait:$WARM;time:warm;\
caret:func (s *Service) getToolDoneMessage(toolName string, err string) string {;\
code:\\n;keylat:150;hangmon:on;mark:sample-start;"
for i in $(seq 1 "$CYCLES"); do T="${T}time:cycle-$i;$CYCLE"; done
T="${T}hangmon:report;code:\\n;keylat:150;"
if [ "$MODE" = local ]; then
  T="${T}time:paused;pausegopls;hangmon:on;codefast:$BURST;$COMPLETE;hangmon:report;resumegopls;wait:3;\
time:resumed;codefast:$BURST;$COMPLETE;hangmon:report;\
time:killed;killgopls;wait:8;goplscount;codefast:$BURST;$COMPLETE;wait:2;$COMPLETE;hangmon:report;"
fi
T="${T}code:\\n;mark:ime;imecode:toolNa;wait:1.5;panel;code:$ESC$DEL$DEL$DEL$DEL$DEL$DEL;mark:done;quit"

LOG=$WORK/typing-$MODE.log
envs=(DRIVE="$T" DRIVE_OUT="$LOG" DRIVE_SHOTS="$WORK" DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" GOLENS_MEASURE=1 GOLENS_LSP_TRACE=1)
if [ "$MODE" = vm ]; then
  envs+=(GOLENS_EXECUTION_MODE="${GOLENS_EXECUTION_MODE:-vm}")
else
  envs+=(GOLENS_EXECUTION_MODE="${GOLENS_EXECUTION_MODE:-host}")
fi
[ -n "${GOLENS_VM_MEMORY_MB:-}" ] && envs+=(GOLENS_VM_MEMORY_MB="$GOLENS_VM_MEMORY_MB")
log stream --style compact --level debug --predicate "subsystem == \"$DOMAIN\"" > "$OUT/core-$MODE.log" 2>&1 &
LOGSTREAM_PID=$!
sleep 1
echo "GoLens typing journey — mode=$MODE — workload $WS/$FILE — cycles $CYCLES — out $OUT"
STARTED_AT=$(date '+%Y-%m-%d %H:%M:%S')
env "${envs[@]}" "$APP" -GoLensLastWorkspacePath "$WS" -GoLensLastFilePath "$WS/$FILE" -GoLensShowConsole '<true/>' > "$OUT/app-$MODE.log" 2>&1 &
APP_PID=$!

sampled=0
i=0
LIMIT=$((WARM + 60 + CYCLES * 25 + 120))
while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt $((LIMIT * 5)) ]; do
  OWNED_PIDS="$OWNED_PIDS $(descendants "$APP_PID" | tr '\n' ' ')"
  if [ $sampled = 0 ] && grep -q 'DRIVE mark sample-start' "$LOG" 2>/dev/null; then
    sampled=1
    sample "$APP_PID" "${SAMPLE_SECONDS:-30}" -mayDie -file "$OUT/sample-$MODE.txt" >/dev/null 2>&1 &
    SAMPLER_PID=$!
  fi
  sleep 0.2; i=$((i + 1))
done
if kill -0 "$APP_PID" 2>/dev/null; then echo "  (timeout; killing app)" >&2; kill -TERM "$APP_PID"; sleep 1; kill -KILL "$APP_PID" 2>/dev/null; fi
[ -n "$SAMPLER_PID" ] && wait "$SAMPLER_PID" 2>/dev/null; SAMPLER_PID=
kill -TERM "$LOGSTREAM_PID" 2>/dev/null; LOGSTREAM_PID=
cp "$LOG" "$OUT/" 2>/dev/null; LOG=$OUT/typing-$MODE.log

shown=$(grep -c 'DRIVE panel visible' "$LOG" 2>/dev/null)
hidden=$(grep -c 'DRIVE panel hidden' "$LOG" 2>/dev/null)
echo "completion panel: visible=$shown hidden=$hidden"
grep -E 'DRIVE (keylat|hangmon|time|gopls children|mark done)' "$LOG" | sed 's/^DRIVE /  /'
grep -E '\[measure\] completion first-results' "$OUT/app-$MODE.log" | awk '{print $4}' | sort -n | awk '{a[NR]=$1} END {if (NR) printf "  completion first-results ms: n=%d p50=%s p90=%s max=%s\n", NR, a[int(NR*0.5)+1>NR?NR:int(NR*0.5)+1], a[int(NR*0.9)+1>NR?NR:int(NR*0.9)+1], a[NR]}'
grep -cE 'Completion failed' "$OUT/app-$MODE.log" | sed 's/^/  completion failures logged: /'
echo "  layout loop warnings: $("$HERE/layout-loop-check.sh" "$APP_PID" "$STARTED_AT")"
ime=$(sed -n '/DRIVE mark ime$/,$p' "$LOG" | grep -m1 'DRIVE panel ')
if echo "$ime" | grep -q 'panel visible.*toolName'; then echo "  IME completion: PASS (marked text 'toolNa' offers toolName)"; else echo "  IME completion: FAIL (${ime:-no panel check})"; exit 1; fi
