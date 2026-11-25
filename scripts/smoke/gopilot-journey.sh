#!/bin/bash
# Gopilot journey: real app (debug build), real fixture, real provider read from an env file.
# Usage: GOPILOT_DEV_ENV_FILE=/path/to/file.env scripts/smoke/gopilot-journey.sh [path/to/debug/GoLensApp]
# The env file holds GOPILOT_LIVE_BASE_URL, GOPILOT_LIVE_MODEL, GOPILOT_LIVE_KEY. It is only read by a DEBUG build.
set -u
export GOLENS_UNSAVED_RECOVERY=off
export GOLENS_VM_MEMORY_MB=512
pkill -9 -f "Containers/dev.golens.test.gopilot/" 2>/dev/null || true
pkill -9 -f "golens-gopilot" 2>/dev/null || true
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=${1:-$REPO/.build/debug/GoLensApp}
[ -x "$BIN" ] || { echo "missing binary: $BIN (swift build)"; exit 2; }
[ -n "${GOPILOT_DEV_ENV_FILE:-}" ] && [ -r "$GOPILOT_DEV_ENV_FILE" ] || { echo "set GOPILOT_DEV_ENV_FILE to a readable env file"; exit 2; }

DOMAIN=dev.golens.test.gopilot
KEYCHAIN_SERVICE=app.golens.gopilot.provider.default
WORK=$(cd "$(mktemp -d -t golens-gopilot)" && pwd -P)
ART=$(cd "$(mktemp -d -t golens-gopilot-artifacts)" && pwd -P)
mkdir -p "$ART/shots" "$ART/logs"
APP_PID=
OWNED_PIDS=

descendants() { local k; for k in $(pgrep -P "$1" 2>/dev/null); do echo "$k"; descendants "$k"; done; }

cleanup() {
  [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null && kill -TERM "$APP_PID" 2>/dev/null
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  sleep 1
  for k in $OWNED_PIDS $APP_PID; do kill -KILL "$k" 2>/dev/null; done
  defaults delete $DOMAIN >/dev/null 2>&1
  security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  echo "artifacts: $ART"
}
trap cleanup EXIT INT TERM

BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
APP=$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/driver.dylib" "$HERE/driver.m" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/quiet.dylib" "$HERE/quiet-launch.m" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
defaults delete $DOMAIN >/dev/null 2>&1
security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1

FIX=$WORK/orders
cp -R "$REPO/tests/gopilot/fixtures/http-storage" "$FIX"
rm -f "$FIX/ground-truth.json"

if [ "${GOPILOT_WITH_PROFILE:-0}" = 1 ]; then
  cat > "$FIX/bench_test.go" <<'BENCH'
package main

import "testing"

func spinHash(n int) int {
	h := 1469598103
	for i := 0; i < n; i++ {
		h = (h ^ i) * 16777619
	}
	return h
}

func BenchmarkReserve(b *testing.B) {
	inv := NewInventory(map[string]int{"sku-1": 1 << 60})
	sink := 0
	for i := 0; i < b.N; i++ {
		sink += spinHash(2000)
		inv.Reserve("sku-1", 1)
	}
	_ = sink
}
BENCH
  (cd "$FIX" && go test -run '^$' -bench BenchmarkReserve -benchtime 2s -cpuprofile "$WORK/cpu.pprof" >/dev/null 2>&1)
  [ -s "$WORK/cpu.pprof" ] && export GOPILOT_DEV_PROFILE="$WORK/cpu.pprof" || echo "profile generation failed"
fi

LOG=$ART/logs/journey.log
STEPS=${GOPILOT_STEPS:-"wait:10;fakeactive;mark:ready;wait:2;mark:gp-empty;deeplabels;shot:gp-empty-dark;\
axpress:Understand Project;wait:2;mark:gp-consent;sheetshot:gp-consent-dark;sheetpress:Allow;wait:${GOPILOT_ANSWER_WAIT:-90};mark:gp-answer;deeplabels;shot:gp-answer-dark;\
lightmode;wait:0.8;shot:gp-answer-light;quit"}

DRIVE="$STEPS" DRIVE_OUT=$LOG DRIVE_SHOTS=$ART/shots DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
  "$APP" -GoLensLastWorkspacePath "$FIX" -GoLensLastFilePath "$FIX/main.go" -GoLensShowGopilot '<true/>' > "$ART/logs/app.log" 2>&1 &
APP_PID=$!

i=0
while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt $(( (${GOPILOT_ANSWER_WAIT:-90} + 90) * 5 )) ]; do
  OWNED_PIDS="$OWNED_PIDS $(descendants "$APP_PID" | tr '\n' ' ')"
  sleep 0.2
  i=$((i + 1))
done
if kill -0 "$APP_PID" 2>/dev/null; then echo "app did not quit; stopping it"; kill -TERM "$APP_PID"; fi

echo "== driver log (marks and labels)"
grep -E "DRIVE (mark|label|text|shot|error)" "$LOG" | cut -c1-220 | head -120

echo "== consent"
grep -E "DRIVE sheetpress Allow" "$LOG" || echo "no consent prompt"
