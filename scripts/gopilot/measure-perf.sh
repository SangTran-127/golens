#!/bin/bash
# Gopilot performance measurement on the real app (DEBUG build): key-to-paint, idle CPU and RSS.
# Usage: GOPILOT_DEV_ENV_FILE=/path/key.env scripts/gopilot/measure-perf.sh [--keys N] [--idle SECONDS] [--out FILE] [path/to/debug/GoLensApp]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
KEYS=300
IDLE=60
OUT=
BIN=$REPO/.build/debug/GoLensApp
while [ $# -gt 0 ]; do
  case $1 in
    --keys) KEYS=$2; shift 2 ;;
    --idle) IDLE=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    *) BIN=$1; shift ;;
  esac
done
[ -x "$BIN" ] || { echo "missing binary: $BIN"; exit 2; }
[ -n "${GOPILOT_DEV_ENV_FILE:-}" ] && [ -r "$GOPILOT_DEV_ENV_FILE" ] || { echo "set GOPILOT_DEV_ENV_FILE"; exit 2; }
[ -n "$OUT" ] || OUT=$(mktemp -t golens-perf).txt
DOMAIN=dev.golens.test.perf
SERVICE=app.golens.gopilot.provider.default
WORK=$(cd "$(mktemp -d -t golens-perf)" && pwd -P)
APP_PID=
cleanup() {
  [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null && kill -TERM "$APP_PID" 2>/dev/null
  sleep 1
  [ -n "$APP_PID" ] && kill -KILL "$APP_PID" 2>/dev/null
  defaults delete $DOMAIN >/dev/null 2>&1
  security delete-generic-password -s "$SERVICE" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle failed"; exit 2; }
APP=$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/driver.dylib" "$REPO/scripts/smoke/driver.m" 2>/dev/null || { echo "driver failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/quiet.dylib" "$REPO/scripts/smoke/quiet-launch.m" 2>/dev/null || { echo "quiet failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
FIX=$WORK/orders
cp -R "$REPO/tests/gopilot/fixtures/http-storage" "$FIX"
rm -f "$FIX/ground-truth.json"
{
  echo "hardware: $(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB, $(sw_vers -productVersion)"
  echo "fixture: tests/gopilot/fixtures/http-storage; keystrokes per condition: $KEYS; idle window: ${IDLE}s"
} > "$OUT"

sample_idle() { # pid seconds
  local pid=$1 seconds=$2 i=0 total=0 count=0 rss=0
  while [ $i -lt $seconds ] && kill -0 "$pid" 2>/dev/null; do
    read -r cpu mem < <(ps -o %cpu= -o rss= -p "$pid")
    total=$(echo "$total + ${cpu:-0}" | bc -l); count=$((count + 1)); rss=${mem:-0}
    sleep 1; i=$((i + 1))
  done
  [ $count -gt 0 ] && printf "idle cpu mean=%.2f%% of one core over %ds, rss=%d MiB\n" "$(echo "$total / $count" | bc -l)" "$count" "$((rss / 1024))"
}

condition() { # name steps configured(0/1) panel(true/false) fill idleSample(0/1)
  local name=$1 steps=$2 configured=$3 panel=$4 fill=$5 idle=$6
  local log=$WORK/$name.log
  defaults delete $DOMAIN >/dev/null 2>&1
  security delete-generic-password -s "$SERVICE" >/dev/null 2>&1
  env ${configured:+GOPILOT_DEV_ENV_FILE=$GOPILOT_DEV_ENV_FILE} ${fill:+GOPILOT_DEV_FILL=$fill} \
    DRIVE="$steps" DRIVE_OUT=$log DRIVE_SHOTS=$WORK DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
    "$APP" -GoLensLastWorkspacePath "$FIX" -GoLensLastFilePath "$FIX/main.go" -GoLensShowGopilot "<$panel/>" > "$WORK/$name.app.log" 2>&1 &
  APP_PID=$!
  local waited=0
  while ! grep -q "DRIVE mark keys" "$log" 2>/dev/null && kill -0 "$APP_PID" 2>/dev/null && [ $waited -lt 400 ]; do sleep 0.5; waited=$((waited + 1)); done
  {
    echo "== $name"
    grep -m1 "keylat" "$log"
    [ "$idle" = 1 ] && sample_idle "$APP_PID" "$IDLE"
  } >> "$OUT"
  kill -TERM "$APP_PID" 2>/dev/null; sleep 2; kill -KILL "$APP_PID" 2>/dev/null; APP_PID=
}

PROMPT="Explain how an order is created, reading the code with your tools."
condition A-gopilot-off "wait:14;fakeactive;focusclass:GoLensTextView;keylat:$KEYS;mark:keys;wait:600" "" false "" 1
condition B-panel-open-idle "wait:14;fakeactive;focusclass:GoLensTextView;keylat:$KEYS;mark:keys;wait:600" 1 true "" 1
condition C-streaming "wait:14;fakeactive;focusclass:PlatformTextView;fr:$PROMPT;axpress:Send;wait:3;focusclass:GoLensTextView;keylat:$KEYS;mark:keys;wait:600" 1 true "" 0
condition D-transcript-1000 "wait:16;fakeactive;focusclass:GoLensTextView;keylat:$KEYS;mark:keys;wait:600" 1 true 1000 1
cat "$OUT"
