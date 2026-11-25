#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=${BIN:-$REPO/.build/release/GoLensApp}
CORPUS=${CORPUS:-x-tools}
CORPUS_SPEC=$HERE/corpora/$CORPUS.json
RUNS=${RUNS:-3}
DWELL_SECONDS=${DWELL_SECONDS:-600}
IDLE_SECONDS=${IDLE_SECONDS:-60}
BUNDLE_ID=dev.golens.test.perf
LOCK_DIR=/private/tmp/golens-smoke.lock
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

[ -f "$CORPUS_SPEC" ] || { echo "unknown corpus $CORPUS: no $CORPUS_SPEC" >&2; exit 2; }

[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)" >&2; exit 2; }

until mkdir "$LOCK_DIR" 2>/dev/null; do sleep 5; done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/golens-perf.XXXXXX")
touch "$WORK/.metadata_never_index"
OUT=${PERF_OUT:-$WORK/out}
mkdir -p "$OUT"

cleanup() {
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  "$LSREGISTER" -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  rm -rf "$WORK/app" "$WORK/driver.dylib" "$WORK/quiet.dylib"
  if [ -z "${PERF_OUT:-}" ]; then
    echo "artifacts: removed temp dir $WORK (set PERF_OUT to persist logs/JSON)"
  fi
  rm -rf "$WORK"
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

BUNDLE_ID="$BUNDLE_ID" "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || {
  echo "bundle-app.sh failed" >&2
  exit 2
}
APP_EXEC="$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")"

clang -dynamiclib -fobjc-arc -framework AppKit -framework CoreImage -o "$WORK/driver.dylib" "$REPO/scripts/smoke/driver.m" || { echo "driver build failed" >&2; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/quiet.dylib" "$REPO/scripts/smoke/quiet-launch.m" || { echo "quiet-launch build failed" >&2; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true

python3 "$HERE/measure_run.py" \
  "$APP_EXEC" \
  "$WORK/driver.dylib" \
  "$WORK/quiet.dylib" \
  "$CORPUS_SPEC" \
  "$RUNS" \
  "$DWELL_SECONDS" \
  "$IDLE_SECONDS" \
  "$OUT"
